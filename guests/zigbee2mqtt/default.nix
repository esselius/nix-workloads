{
  modulesPath,
  config,
  pkgs,
  ...
}:
{
  imports = [
    # Same module the upstream NixOS incus image imports - keeps container boot
    # and network wiring intact across `nixos-rebuild switch`.
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  networking = {
    hostName = "zigbee2mqtt";
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

  # Zigbee2MQTT reads the network key and the MQTT password from a rendered
  # YAML (sops template, never the Nix store). The oauth2-proxy secrets are
  # rendered into an EnvironmentFile.
  sops = {
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFile = ../../secrets/zigbee2mqtt.yaml;
    secrets = {
      network_key = { };
      mqtt_password = { };
      oauth2_proxy_client_secret = { };
      oauth2_proxy_cookie_secret = { };
    };
    templates = {
      "z2m.yaml" = {
        owner = "zigbee2mqtt";
        group = "zigbee2mqtt";
        content = ''
          network_key: ${config.sops.placeholder.network_key}
          mqtt_password: ${config.sops.placeholder.mqtt_password}
        '';
      };
      "oauth2-proxy.env" = {
        owner = "oauth2-proxy";
        group = "oauth2-proxy";
        content = ''
          OAUTH2_PROXY_CLIENT_SECRET=${config.sops.placeholder.oauth2_proxy_client_secret}
          OAUTH2_PROXY_COOKIE_SECRET=${config.sops.placeholder.oauth2_proxy_cookie_secret}
        '';
      };
    };
  };

  # Don't start (and restart-loop) until the coordinator is actually present;
  # the unix-hotplug device only appears once the dongle is on this host. A
  # redeploy/restart after plugging it in starts the service.
  systemd.services.zigbee2mqtt.unitConfig.ConditionPathExists = "/dev/ttyACM0";

  services.zigbee2mqtt = {
    enable = true;
    settings = {
      frontend.port = 8099;
      homeassistant.enabled = true;
      mqtt = {
        server = "mqtt://mosquitto.int.esselius.dev:1883";
        user = "z2m";
        password = "!" + config.sops.templates."z2m.yaml".path + " mqtt_password";
      };
      # SONOFF ZBDongle-E (EmberZNet); the unix-hotplug device presents it as
      # /dev/ttyACM0. The network parameters must match the existing network or
      # the paired devices drop off.
      serial.adapter = "ember";
      advanced = {
        pan_id = 56089;
        ext_pan_id = [
          154
          147
          150
          234
          96
          16
          140
          189
        ];
        network_key = "!" + config.sops.templates."z2m.yaml".path + " network_key";
        channel = 11;
        last_seen = "ISO_8601";
        log_level = "warning";
        legacy_availability_payload = false;
      };
      availability = true;
    };
  };

  # `.dev` is HSTS-preloaded, so the frontend must be HTTPS. nginx terminates
  # TLS on :443 (and serves the http-01 challenge on :80); oauth2-proxy (Kanidm)
  # gates the z2m frontend, reverse-proxying to it on loopback.
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
    oidcIssuerUrl = "https://idm.int.esselius.dev/oauth2/openid/oauth2-proxy";
    clientID = "oauth2-proxy";
    email.domains = [ "*" ];
    redirectURL = "https://zigbee2mqtt.int.esselius.dev/oauth2/callback";
    upstream = [ "http://127.0.0.1:8099" ];
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
    virtualHosts."zigbee2mqtt.int.esselius.dev" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        # Everything goes through oauth2-proxy, which serves /oauth2/* itself
        # and reverse-proxies the rest to the z2m frontend. Don't set Host /
        # X-Forwarded-* here - the module already includes the recommended
        # proxy headers, and duplicating them makes Go (oauth2-proxy) reject
        # the request with 400 (two Host headers).
        proxyWebsockets = true;
        proxyPass = "http://127.0.0.1:4180";
      };
    };
  };

  # nginx (80 for the ACME challenge, 443 for the frontend) and SSH - only on
  # the private backplane.
  networking.firewall.interfaces.eth0.allowedTCPPorts = [
    22
    80
    443
  ];

  system.stateVersion = "26.05";
}
