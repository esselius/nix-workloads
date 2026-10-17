{
  modulesPath,
  config,
  lib,
  ...
}:
let
  # TLS SNI ingress for the local `dev` env. It is a *passthrough* TCP proxy:
  # it reads the ClientHello's server name and forwards the still-encrypted
  # stream to the right guest, so guests keep presenting their own step-ca
  # certificates (end-to-end TLS, no wildcard). The Mac reaches this guest
  # through a `proxy` device that publishes it on the Colima VM's own address
  # (see terraform/edge), so no route into the dev subnet is needed.
  inv = import ../../inventory.nix;
  env = config.local.env;
  zone = config.local.domain;

  backends = lib.concatStringsSep "\n" (
    lib.flatten (
      lib.mapAttrsToList (
        service: svc:
        lib.optional (svc.https or false) (
          lib.concatMapStringsSep "\n" (name: "      ${name}.${zone} ${inv.ipFor env service}:443;") svc.dns
        )
      ) inv.services
    )
  );
in
{
  imports = [
    # Same module the upstream NixOS incus image imports - keeps container boot
    # and network wiring intact across `nixos-rebuild switch`.
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  networking = {
    hostName = "edge";
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
    max-jobs = 0;
  };

  # `map` is available in the stream context, and the package enables
  # --with-stream_ssl_preread_module. Unknown SNI is sent to the discard port.
  services.nginx = {
    enable = true;
    streamConfig = ''
            map $ssl_preread_server_name $backend {
              default 127.0.0.1:9;
      ${backends}
            }

            server {
              listen 443;
              ssl_preread on;
              proxy_pass $backend;
            }
    '';
  };

  networking.firewall.interfaces.eth0.allowedTCPPorts = [
    22
    443
  ];

  system.stateVersion = "26.05";
}
