{
  modulesPath,
  config,
  lib,
  ...
}:
{
  imports = [
    # Same module the upstream NixOS incus image imports - keeps container boot
    # and network wiring intact across `nixos-rebuild switch`.
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  local.monitoring.mode = "light";

  networking = {
    hostName = "backup";
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

  # The restic REST server's basic-auth htpasswd (bcrypt) line, rendered from
  # sops at /run/secrets and read by the `restic` service user.
  sops = {
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFile = ../../secrets/backup.yaml;
    secrets.restic_htpasswd = {
      owner = "restic";
      group = "restic";
      mode = "0400";
    };
  };

  # Restic REST server. Clients push per-host repositories under the single
  # authenticated `restic` user; the repo itself is encrypted client-side, so
  # the server never sees plaintext.
  services.restic.server = {
    enable = true;
    listenAddress = "8000";
    dataDir = "/var/lib/restic";
    htpasswd-file = config.sops.secrets.restic_htpasswd.path;
  };

  # The module's sandbox needs (user/network) namespaces an unprivileged incus
  # container lacks - the same reason the monitoring guest drops PrivateUsers for
  # VictoriaMetrics. Keep the rest of the hardening, drop these two.
  systemd.services.restic-rest-server.serviceConfig = {
    PrivateUsers = lib.mkForce false;
    PrivateNetwork = lib.mkForce false;
  };

  # REST API on the private backplane (eth0, incusbr-vpn), plus SSH. Plain HTTP
  # is fine here: restic encrypts the repo and only the WireGuard wire carries it.
  networking.firewall.interfaces.eth0.allowedTCPPorts = [
    22
    8000
  ];

  system.stateVersion = "26.05";
}
