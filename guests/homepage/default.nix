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

  networking = {
    hostName = "homepage";
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

  # The oauth2-proxy OIDC client secret (the Kanidm `homepage` client) and cookie
  # secret are rendered into an EnvironmentFile, never the Nix store.
  sops = {
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFile = ../../secrets/kanidm.yaml;
    secrets = {
      homepage_oidc_secret = { };
      homepage_cookie_secret = { };
    };
    templates."oauth2-proxy.env" = {
      owner = "oauth2-proxy";
      group = "oauth2-proxy";
      # The unit points at a stable path, so a credential change alone would not
      # restart the service; trigger it explicitly.
      restartUnits = [ "oauth2-proxy.service" ];
      content = ''
        OAUTH2_PROXY_CLIENT_SECRET=${config.sops.placeholder.homepage_oidc_secret}
        OAUTH2_PROXY_COOKIE_SECRET=${config.sops.placeholder.homepage_cookie_secret}
      '';
    };
  };

  # The landing page: links to every workload. No widgets, so there is nothing
  # to fetch server-side and no per-service API keys to store.
  services.homepage-dashboard = {
    enable = true;
    allowedHosts = "homepage.int.esselius.dev";
    # The module's default port is 8082; pin 3000 to match the oauth2-proxy
    # upstream below.
    listenPort = 3000;
    settings = {
      title = "Homelab";
      theme = "dark";
      color = "slate";
      headerStyle = "boxed";
    };
    services = [
      {
        "Smart home" = [
          {
            "Home Assistant" = {
              href = "https://home-assistant.int.esselius.dev";
              description = "Smart-home hub";
            };
          }
          {
            "Zigbee2MQTT" = {
              href = "https://zigbee2mqtt.int.esselius.dev";
              description = "Zigbee mesh";
            };
          }
          {
            "Node-RED" = {
              href = "https://node-red.int.esselius.dev";
              description = "Automations";
            };
          }
        ];
      }
      {
        Infrastructure = [
          {
            Grafana = {
              href = "https://monitoring.int.esselius.dev";
              description = "Metrics + logs";
            };
          }
          {
            Kanidm = {
              href = "https://idm.int.esselius.dev";
              description = "Identity";
            };
          }
          {
            "Attic cache" = {
              href = "https://cache.int.esselius.dev";
              description = "Nix binary cache";
            };
          }
        ];
      }
    ];
  };

  # `.dev` is HSTS-preloaded, so the UI must be HTTPS. nginx terminates TLS on
  # :443 (and serves the http-01 challenge on :80); oauth2-proxy (Kanidm) gates
  # the dashboard, reverse-proxying to it on loopback.
  security.pki.certificateFiles = [ ../../certs/root_ca.crt ];

  security.acme = {
    acceptTerms = true;
    defaults = {
      email = "acme@esselius.dev";
      server = "https://step-ca.int.esselius.dev:8443/acme/internal/directory";
    };
  };

  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    oidcIssuerUrl = "https://idm.int.esselius.dev/oauth2/openid/homepage";
    clientID = "homepage";
    email.domains = [ "*" ];
    redirectURL = "https://homepage.int.esselius.dev/oauth2/callback";
    upstream = [ "http://127.0.0.1:3000" ];
    reverseProxy = true;
    setXauthrequest = true;
    # Kanidm enforces PKCE; send an S256 challenge.
    extraConfig.code-challenge-method = "S256";
    # Client + cookie secrets are supplied via the sops EnvironmentFile.
    keyFile = config.sops.templates."oauth2-proxy.env".path;
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts."homepage.int.esselius.dev" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:4180";
        proxyWebsockets = true;
      };
    };
  };

  # nginx (80 for the ACME challenge, 443 for the UI) and SSH - only on the
  # private backplane.
  networking.firewall.interfaces.eth0.allowedTCPPorts = [
    22
    80
    443
  ];

  system.stateVersion = "26.05";
}
