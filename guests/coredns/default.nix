{
  modulesPath,
  lib,
  pkgs,
  config,
  ...
}:
let
  # Internal-only zone, deliberately NOT delegated from the public esselius.dev
  # zone: a delegation whose authority is a private address cannot be followed
  # by a public/forwarding resolver - it returns REFUSED / "No Reachable
  # Authority". Instead, WireGuard clients set their resolver to this guest, so
  # CoreDNS answers the env zone authoritatively. See README > Networking.
  inv = import ../../inventory.nix;
  env = config.local.env;
  domain = config.local.domain;
  ns = "ns1.${domain}";

  # Records come from inventory.nix, not a hand-maintained map: every service's
  # alias names resolve to its address in this env, so clients never learn
  # which host runs a dependency. Moving a service is a `placement` change.
  aRecords = lib.concatStringsSep "\n" (
    lib.flatten (
      lib.mapAttrsToList (
        service: svc: map (name: "${name} IN A ${inv.ipFor env service}") svc.dns
      ) inv.services
    )
  );

  # Non-HTTP service discovery (RFC 2782). Clients that honour SRV can find the
  # broker by name and port; clients that don't (Paho, libpq) still use the A
  # record above plus an explicit port.
  services = {
    mqtt = {
      port = 1883;
      target = "mosquitto";
    };
  };

  srvRecords = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: s: "_${name}._tcp IN SRV 0 0 ${toString s.port} ${s.target}.${domain}."
    ) services
  );

  # A Nix store path keeps this declarative: changing a record changes the path,
  # which changes the Corefile, which restarts coredns. DynamicUser can read it
  # because store paths are world-readable.
  zone = pkgs.writeText "db.${domain}" ''
    $ORIGIN ${domain}.
    $TTL 300
    @ IN SOA ${ns}. hostmaster.${domain}. (
        2026101101 ; serial
        3600       ; refresh
        1800       ; retry
        604800     ; expire
        300 )      ; minimum
    @ IN NS ${ns}.
    ${aRecords}
    ${srvRecords}
  '';
in
{
  imports = [
    # Same module the upstream NixOS incus image imports - keeps container boot
    # and network wiring intact across `nixos-rebuild switch`.
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  local.monitoring.mode = "light";

  networking = {
    hostName = "coredns";
    # The incus image configures eth0 with systemd-networkd, not dhcpcd.
    dhcpcd.enable = false;
    useDHCP = false;
    useHostResolvConf = false;
  };

  systemd.network = {
    enable = true;
    networks."50-eth0" = {
      matchConfig.Name = "eth0";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = true;
      };
      linkConfig.RequiredForOnline = "routable";
    };
  };

  # lxc-container.nix enables sshd via mkDefault, but state it explicitly so a
  # deploy can never lock us out. openFirewall adds a global port-22 allow, so
  # keep it off and open ports per-interface below.
  services.openssh = {
    enable = true;
    openFirewall = false;
    settings.PermitRootLogin = "prohibit-password";
  };
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIoqhLqzuQJEyn/M4WmBkpPlMou2zIXoJUikAcFgvx4C peteresselius@Fox.lan"
  ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # The guest must never build - builds run on the Mac's linux-builder. With
    # max-jobs = 0 nix only substitutes, so any attempt to build inside the
    # container fails.
    max-jobs = 0;
  };

  # `systemd.network.enable` pulls in systemd-resolved as a default
  # (nixpkgs `networkd.nix`), and its stub owns 127.0.0.53:53 - which collides
  # with CoreDNS binding 0.0.0.0:53 (`bind: address already in use`). This guest
  # *is* the resolver, so disable resolved and point the container at CoreDNS.
  services.resolved.enable = false;
  networking.nameservers = [ "127.0.0.1" ];

  # Authoritative for the env zone. The homelab also forwards everything else
  # upstream (so it doubles as a resolver for WireGuard clients); `dev` does not
  # - it must not reach external services.
  services.coredns = {
    enable = true;
    config = ''
      ${domain}:53 {
        file ${zone}
        errors
        log
      }
    ''
    + lib.optionalString (env == "homelab") ''
      .:53 {
        forward . 1.1.1.1 9.9.9.9
        cache 30
        errors
        log
      }
    '';
  };

  # DNS only on the private backplane (eth0, incusbr-vpn), plus SSH. Nothing on
  # any other NIC.
  networking.firewall.interfaces.eth0.allowedTCPPorts = [
    22
    53
  ];
  networking.firewall.interfaces.eth0.allowedUDPPorts = [ 53 ];

  system.stateVersion = "26.05";
}
