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
  # secret are rendered into an EnvironmentFile, never the Nix store. So are the
  # dashboard widget credentials (see services.homepage-dashboard below).
  sops = {
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFile = ../../secrets/kanidm.yaml;
    secrets = {
      homepage_oidc_secret = { };
      homepage_cookie_secret = { };
      # Home Assistant long-lived access token (created in HA: profile ->
      # Security). Homepage-specific, so it lives in its own secrets file.
      homeassistant_token = {
        sopsFile = ../../secrets/homepage.yaml;
      };
      # The Grafana admin password (shared with the monitoring workload) for the
      # Grafana widget's authenticated /api/admin/stats call.
      grafana_admin_password = {
        sopsFile = ../../secrets/monitoring.yaml;
      };
    };
    templates = {
      "oauth2-proxy.env" = {
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
      # `HOMEPAGE_VAR_*` variables are substituted into the config files
      # (`{{HOMEPAGE_VAR_...}}`) at runtime, so widget credentials never land in
      # the world-readable Nix store or config directory.
      "homepage-widgets.env" = {
        restartUnits = [ "homepage-dashboard.service" ];
        content = ''
          HOMEPAGE_VAR_HASS_TOKEN=${config.sops.placeholder.homeassistant_token}
          HOMEPAGE_VAR_GRAFANA_PASSWORD=${config.sops.placeholder.grafana_admin_password}
        '';
      };
    };
  };

  # The landing page: links to every workload, plus a widget wherever the
  # service exposes data. Widget credentials come from the sops EnvironmentFile
  # above (`{{HOMEPAGE_VAR_...}}`).
  services.homepage-dashboard = {
    enable = true;
    allowedHosts = "homepage.${config.local.domain}";
    # The module's default port is 8082; pin 3000 to match the oauth2-proxy
    # upstream below.
    listenPort = 3000;
    environmentFiles = [ config.sops.templates."homepage-widgets.env".path ];
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
              href = "https://home-assistant.${config.local.domain}";
              description = "Smart-home hub";
              widget = {
                type = "homeassistant";
                url = "https://home-assistant.${config.local.domain}";
                # Long-lived access token (sops; see the sops block above).
                key = "{{HOMEPAGE_VAR_HASS_TOKEN}}";
              };
            };
          }
          {
            "Zigbee2MQTT" = {
              href = "https://zigbee2mqtt.${config.local.domain}";
              description = "Zigbee mesh";
              # No native widget: read the guest's mqtt-exporter metrics from the
              # monitoring workload's VictoriaMetrics.
              widget = {
                type = "prometheusmetric";
                url = "http://monitoring.${config.local.domain}:8428";
                refreshInterval = 15000;
                metrics = [
                  {
                    label = "Devices online";
                    query = "count(mqtt_zigbee_availability == 1)";
                  }
                  {
                    label = "Devices";
                    query = "count(mqtt_zigbee_availability)";
                  }
                ];
              };
            };
          }
          {
            "Node-RED" = {
              href = "https://node-red.${config.local.domain}";
              description = "Automations";
              # Node-RED exposes no metrics; show its systemd unit state
              # (1 = active) from the node exporter.
              widget = {
                type = "prometheusmetric";
                url = "http://monitoring.${config.local.domain}:8428";
                metrics = [
                  {
                    label = "Service";
                    query = "node_systemd_unit_state{host=\"node-red\",name=\"node-red.service\",state=\"active\"}";
                  }
                ];
              };
            };
          }
        ];
      }
      {
        Infrastructure = [
          {
            Grafana = {
              href = "https://monitoring.${config.local.domain}";
              description = "Metrics + logs";
              # Grafana > v10.4 uses widget version 2 (the module's admin/stats
              # endpoint, basic auth with the admin password from sops).
              widget = {
                type = "grafana";
                version = 2;
                url = "https://monitoring.${config.local.domain}";
                username = "admin";
                password = "{{HOMEPAGE_VAR_GRAFANA_PASSWORD}}";
              };
            };
          }
          {
            Kanidm = {
              href = "https://idm.${config.local.domain}";
              description = "Identity";
              # No native widget: Kanidm's public /status endpoint returns plain
              # `true`/`false`.
              widget = {
                type = "customapi";
                url = "https://idm.${config.local.domain}/status";
                refreshInterval = 60000;
                mappings = [
                  {
                    label = "Status";
                    format = "text";
                    remap = [
                      {
                        value = true;
                        to = "Online";
                      }
                      {
                        value = false;
                        to = "Offline";
                      }
                    ];
                  }
                ];
              };
            };
          }
          {
            "Attic cache" = {
              href = "https://cache.${config.local.domain}";
              description = "Nix binary cache";
              # atticd exposes no metrics; show its unit state and the cache
              # volume's usage from the node exporter.
              widget = {
                type = "prometheusmetric";
                url = "http://monitoring.${config.local.domain}:8428";
                metrics = [
                  {
                    label = "Cache used";
                    query = "node_filesystem_size_bytes{host=\"attic\",mountpoint=\"/var/lib/atticd\"} - node_filesystem_avail_bytes{host=\"attic\",mountpoint=\"/var/lib/atticd\"}";
                    format.type = "bytes";
                  }
                  {
                    label = "Service";
                    query = "node_systemd_unit_state{host=\"attic\",name=\"atticd.service\",state=\"active\"}";
                    format.type = "number";
                  }
                ];
              };
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
      server = "https://step-ca.${config.local.domain}:8443/acme/internal/directory";
    };
  };

  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    oidcIssuerUrl = "https://idm.${config.local.domain}/oauth2/openid/homepage";
    clientID = "homepage";
    email.domains = [ "*" ];
    redirectURL = "https://homepage.${config.local.domain}/oauth2/callback";
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
    virtualHosts."homepage.${config.local.domain}" = {
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
