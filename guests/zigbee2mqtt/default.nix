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

  # Back up the Zigbee device database + coordinator backup.
  local.backup.paths = [ "/var/lib/zigbee2mqtt" ];

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
      # The mqtt-exporter below authenticates as the broker's shared `exporter`
      # user; its password lives in secrets/mosquitto.yaml, which every guest is
      # already a recipient of (single creation rule in .sops.yaml).
      exporter_password = {
        sopsFile = ../../secrets/mosquitto.yaml;
        key = "mqtt_exporter";
      };
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
      # Read by systemd (as root) before dropping to the exporter's DynamicUser,
      # so the broker password never lands in the process environment of a
      # world-readable unit or in the Nix store. (mqtt-exporter's variable is
      # MQTT_USERNAME - unlike the Go mosquitto-exporter's MQTT_USER.) The
      # restart trigger is needed because the unit points at a stable path, so
      # a credential change alone would not restart the service.
      "mqtt-exporter.env" = {
        restartUnits = [ "mqtt-exporter.service" ];
        content = ''
          MQTT_USERNAME=exporter
          MQTT_PASSWORD=${config.sops.placeholder.exporter_password}
        '';
      };
    };
  };

  # Enabled now that the coordinator has moved here. ConditionPathExists keeps
  # the unit from starting (or restart-looping) if the dongle is ever absent.
  systemd.services.zigbee2mqtt.unitConfig.ConditionPathExists = "/dev/ttyACM0";

  services.zigbee2mqtt = {
    enable = true;
    settings = {
      frontend.port = 8099;
      homeassistant.enabled = true;
      mqtt = {
        server = "mqtt://mosquitto.${config.local.domain}:1883";
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
      server = "https://step-ca.${config.local.domain}:8443/acme/internal/directory";
    };
  };

  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    oidcIssuerUrl = "https://idm.${config.local.domain}/oauth2/openid/oauth2-proxy";
    clientID = "oauth2-proxy";
    email.domains = [ "*" ];
    redirectURL = "https://zigbee2mqtt.${config.local.domain}/oauth2/callback";
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
    virtualHosts."zigbee2mqtt.${config.local.domain}" = {
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

  # Application metrics for the Zigbee dashboard: mqtt-exporter subscribes to
  # the z2m topics on the broker, flattens each device state and `bridge/state`
  # payload into Prometheus gauges, and serves them on loopback. The Alloy agent
  # scrapes that (extra alloy file) and remote-writes to the monitoring workload.
  # The broker's `exporter` account is granted read on `zigbee2mqtt/#` in the
  # mosquitto workload.
  systemd.services.mqtt-exporter = {
    description = "Prometheus exporter for Zigbee2MQTT (via MQTT)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.mqtt-exporter}/bin/mqtt-exporter";
      EnvironmentFile = config.sops.templates."mqtt-exporter.env".path;
      Environment = [
        "MQTT_ADDRESS=mosquitto.${config.local.domain}"
        "MQTT_PORT=1883"
        # Device state (`zigbee2mqtt/<name>`), device availability, and the
        # bridge online state - deliberately NOT `zigbee2mqtt/#`, whose retained
        # `bridge/devices` / `bridge/health` payloads (nested per-device objects)
        # would mint a metric *name* per device and exhaust MAX_METRICS.
        "MQTT_TOPIC=zigbee2mqtt/+,zigbee2mqtt/+/availability,zigbee2mqtt/bridge/state"
        # Collapse Zigbee2MQTT's `<device>/availability` topic into the device's
        # own topic as `mqtt_zigbee_availability` instead of a second topic per
        # device (legacy payloads are already off in the z2m settings above).
        "ZIGBEE2MQTT_AVAILABILITY=True"
        "PROMETHEUS_ADDRESS=127.0.0.1"
        "PROMETHEUS_PORT=9000"
        # Every numeric field of every device becomes a series; cap the count so
        # a misbehaving payload can't take down the exporter.
        "MAX_METRICS=2000"
      ];
      DynamicUser = true;
      Restart = "on-failure";
    };
  };

  environment.etc."alloy/zigbee2mqtt.alloy".text = ''
    prometheus.scrape "zigbee2mqtt" {
      targets    = [{ __address__ = "127.0.0.1:9000" }]
      job_name   = "zigbee2mqtt"
      forward_to = [prometheus.relabel.host.receiver]
    }
  '';

  # nginx (80 for the ACME challenge, 443 for the frontend) and SSH - only on
  # the private backplane.
  networking.firewall.interfaces.eth0.allowedTCPPorts = [
    22
    80
    443
  ];

  system.stateVersion = "26.05";
}
