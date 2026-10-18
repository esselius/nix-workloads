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
    hostName = "attic";
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

  # The JWT signing secret (base64-encoded PKCS#1 RSA PEM) signs the access
  # tokens. atticd wants it in an EnvironmentFile, so render a sops template
  # rather than the raw secret.
  sops = {
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFile = ../../secrets/attic.yaml;
    secrets.attic_token_rs256_secret_base64 = { };
    templates."atticd.env".content = ''
      ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=${config.sops.placeholder.attic_token_rs256_secret_base64}
    '';
  };

  services.atticd = {
    enable = true;
    environmentFile = config.sops.templates."atticd.env".path;

    settings = {
      # Behind nginx (TLS + the public name); the module sets up a DynamicUser
      # and a StateDirectory at /var/lib/atticd (the persistent volume).
      listen = "127.0.0.1:8080";

      # Both are mandatory in production: they pin the Host header and the
      # endpoint advertised in cache-config responses.
      allowed-hosts = [ "cache.${config.local.domain}" ];
      api-endpoint = "https://cache.${config.local.domain}/";

      # sqlite + local storage both live under StateDirectory (/var/lib/atticd).
      database.url = "sqlite:///var/lib/atticd/server.db?mode=rwc";
      storage = {
        type = "local";
        path = "/var/lib/atticd/storage";
      };

      # Chunked, zstd-compressed storage with global dedup (see the README for
      # sizing). Values match the upstream defaults.
      chunking = {
        nar-size-threshold = 65536;
        min-size = 16384;
        avg-size = 65536;
        max-size = 262144;
      };
      compression.type = "zstd";

      # Bound growth: run GC every 12h and drop objects neither created nor
      # accessed within six months. Without a retention period the cache grows
      # unbounded (see the Attic GC notes in the README).
      garbage-collection = {
        interval = "12 hours";
        default-retention-period = "6 months";
      };
    };
  };

  # The module runs atticd as a DynamicUser with StateDirectory=atticd, which
  # systemd relocates to /var/lib/private/atticd - that collides with the
  # persistent volume mounted at /var/lib/atticd (systemd: "Device or resource
  # busy"). Run it as a fixed system user instead (like the other workloads), so
  # the state dir stays at /var/lib/atticd, on the volume.
  users.users.atticd = {
    isSystemUser = true;
    group = "atticd";
  };
  users.groups.atticd = { };
  systemd.services.atticd.serviceConfig = {
    DynamicUser = lib.mkForce false;
    PrivateUsers = lib.mkForce false;
  };

  # `.dev` is HSTS-preloaded, so the cache must be HTTPS. nginx terminates TLS on
  # :443 (and serves the http-01 challenge on :80), proxying to atticd.
  security.pki.certificateFiles = [ ../../certs/root_ca.crt ];

  security.acme = {
    acceptTerms = true;
    defaults = {
      email = "acme@esselius.dev";
      server = "https://step-ca.${config.local.domain}:8443/acme/internal/directory";
    };
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts."cache.${config.local.domain}" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:8080";
        # NAR uploads are large and streamed; disable nginx's body limit and
        # request/response buffering so pushes and pulls stream end to end.
        extraConfig = ''
          client_max_body_size 0;
          proxy_request_buffering off;
          proxy_buffering off;
        '';
      };
    };
  };

  # nginx (80 for the ACME challenge, 443 for the cache) and SSH - only on the
  # private backplane.
  networking.firewall.interfaces.eth0.allowedTCPPorts = [
    22
    80
    443
  ];

  system.stateVersion = "26.05";
}
