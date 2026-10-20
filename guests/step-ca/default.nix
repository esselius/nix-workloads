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

  # services.step-ca hands the intermediate-key password to step-ca through a
  # systemd credential (LoadCredential); keep it working without nesting (see
  # modules/lxc-credentials.nix for why and the caveat).
  local.lxc.allowSystemdCredentials = true;

  local.monitoring.mode = "light";

  networking = {
    hostName = "step-ca";
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

  # Back up the CA database + provisioners (the intermediate key itself is also
  # in sops).
  local.backup.paths = [ "/var/lib/step-ca" ];

  # The Esselius intermediate CA is reused, not regenerated: its cert is public
  # (certs/, committed) and its password-encrypted key + the password come from
  # sops, so this CA and adama's share one trust chain (both issued under the
  # Esselius Root CA, which hosts already trust).
  environment.etc."step-ca/root_ca.crt".source = ../../certs/root_ca.crt;
  environment.etc."step-ca/intermediate_ca.crt".source = ../../certs/intermediate_ca.crt;

  sops = {
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFile = ../../secrets/step-ca.yaml;
    secrets = {
      # Password for the encrypted intermediate key; read by systemd as root
      # (LoadCredential), so it can stay root-owned.
      intermediate_ca_password = { };
      # The password-encrypted intermediate key. step-ca reads this path
      # directly as its service user, so it must be readable by `step-ca`.
      intermediate_ca_key = {
        owner = "step-ca";
        mode = "0400";
      };
    };
  };

  services.step-ca = {
    enable = true;
    address = "0.0.0.0";
    port = 8443;

    intermediatePasswordFile = config.sops.secrets.intermediate_ca_password.path;

    settings = {
      root = "/etc/step-ca/root_ca.crt";
      crt = "/etc/step-ca/intermediate_ca.crt";
      key = config.sops.secrets.intermediate_ca_key.path;

      # SAN on step-ca's own TLS cert; must match the network zone record.
      dnsNames = [ "step-ca.${config.local.domain}" ];

      db = {
        type = "badgerv2";
        dataSource = "/var/lib/step-ca/db";
      };

      # A single ACME provisioner for the internal CA. The name is the path
      # segment in the directory URL:
      #   https://step-ca.<env zone>:8443/acme/internal/directory
      authority.provisioners = [
        {
          type = "ACME";
          name = "internal";
          # Long-lived certs: a silently failed renewal shouldn't become an
          # outage within a day (step-ca's default is 24h). The complement is
          # alerting on cert expiry - see the monitoring workload.
          claims = {
            defaultTLSCertDuration = "2160h"; # 90 days
            maxTLSCertDuration = "2160h";
          };
        }
      ];
    };
  };

  # The module hardcodes DynamicUser = true, but a dynamic UID can't own the
  # sops secret holding the intermediate key (it doesn't exist at activation).
  # Use the module's static `step-ca` user instead.
  systemd.services.step-ca.serviceConfig.DynamicUser = lib.mkForce false;

  # ACME endpoint (8443) only on the private backplane, plus SSH.
  networking.firewall.interfaces.eth0.allowedTCPPorts = [
    22
    8443
  ];

  system.stateVersion = "26.05";
}
