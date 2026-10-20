{
  modulesPath,
  config,
  lib,
  pkgs,
  ...
}:
let
  inv = import ../../inventory.nix;

  centralScrapes = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      svc: m:
      let
        id = lib.replaceStrings [ "-" ] [ "_" ] svc;
        ip = inv.ipFor config.local.env svc;
        rules = ''
          rule {
            target_label = "host"
            replacement  = "${svc}"
          }
          rule {
            target_label = "node_type"
            replacement  = "container"
          }
        '';
      in
      lib.optionalString (m.node or false) ''
        prometheus.scrape "${id}_node" {
          targets    = [{ __address__ = "${ip}:9100" }]
          job_name   = "integrations/unix"
          forward_to = [prometheus.relabel.${id}_node.receiver]
        }

        prometheus.relabel "${id}_node" {
          forward_to = [prometheus.remote_write.default.receiver]
          ${rules}
        }
      ''
      + lib.optionalString (m.restic or false) ''
        prometheus.scrape "${id}_restic" {
          targets    = [{ __address__ = "${ip}:9753" }]
          job_name   = "restic-exporter"
          forward_to = [prometheus.relabel.${id}_restic.receiver]
        }

        prometheus.relabel "${id}_restic" {
          forward_to = [prometheus.remote_write.default.receiver]
          ${rules}
        }
      ''
      + lib.optionalString (m ? app) (
        let
          a = m.app;
        in
        ''
          prometheus.scrape "${id}_app" {
            targets    = [
              {
                __address__      = "${ip}:${toString a.port}",
                __metrics_path__ = "${a.path or "/metrics"}",
              },
            ]
            job_name   = "${a.job}"
            forward_to = [prometheus.relabel.${id}_app.receiver]
          }

          prometheus.relabel "${id}_app" {
            forward_to = [prometheus.remote_write.default.receiver]
            ${rules}
          }
        ''
      )
    ) inv.metrics
  );

  # Receives Grafana's webhook JSON and re-publishes it to ntfy in ntfy's own
  # JSON format, so notifications show a title + message instead of a raw blob.
  relayScript = pkgs.writeText "grafana-ntfy-relay.py" ''
    import json
    import os
    import sys
    import urllib.request
    from http.server import BaseHTTPRequestHandler, HTTPServer

    TOPIC = os.environ["NTFY_TOPIC"]


    def notify(title, message, priority):
        body = json.dumps({
            "topic": TOPIC,
            "title": title,
            "message": message,
            "priority": priority,
        }).encode()
        request = urllib.request.Request(
            "https://ntfy.sh/",
            data=body,
            headers={"Content-Type": "application/json"},
        )
        try:
            urllib.request.urlopen(request, timeout=10)
        except Exception as exc:
            print("ntfy publish failed:", exc, file=sys.stderr, flush=True)


    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                payload = json.loads(raw)
            except ValueError:
                payload = {}
            status = payload.get("status", "firing")
            alerts = payload.get("alerts", [])
            alertname = "alert"
            summaries = []
            for alert in alerts:
                labels = alert.get("labels", {})
                annotations = alert.get("annotations", {})
                alertname = labels.get("alertname", alertname)
                summaries.append(
                    annotations.get("summary") or labels.get("host") or alertname
                )
            icon = "\U0001F6A8" if status == "firing" else "\u2705"
            title = icon + " " + alertname
            message = "\n".join(summaries) or title
            notify(title, message, 4 if status == "firing" else 2)
            self.send_response(200)
            self.end_headers()

        def log_message(self, *args):
            pass


    HTTPServer(("127.0.0.1", 9123), Handler).serve_forever()
  '';
in
{
  imports = [
    # Same module the upstream NixOS incus image imports - keeps container boot
    # and network wiring intact across `nixos-rebuild switch`.
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  networking = {
    hostName = "monitoring";
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

  # Back up Grafana's state (users, API keys, annotations). VictoriaMetrics/Loki
  # history is regenerable and large, so it is deliberately left out.
  local.backup.paths = [ "/var/lib/monitoring/grafana" ];

  # Grafana reads both via its file provider (`$__file{}` in the settings below),
  # so they stay out of the world-readable Nix store. Read by the grafana user.
  sops = {
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFile = ../../secrets/monitoring.yaml;
    secrets = {
      grafana_admin_password = {
        owner = "grafana";
        mode = "0400";
      };
      grafana_secret_key = {
        owner = "grafana";
        mode = "0400";
      };
      # ntfy.sh alert topic. Its name is the shared secret (free tier has no
      # reserved topics), so it stays out of the store.
      ntfy_topic = {
        owner = "grafana";
        mode = "0400";
      };
      # OIDC client secret for the Kanidm "grafana" client (lives in
      # secrets/kanidm.yaml; Grafana reads it via $__file{}).
      grafana_oidc_secret = {
        sopsFile = ../../secrets/kanidm.yaml;
        owner = "grafana";
        mode = "0400";
      };
    };
    # Grafana's provisioning interpolates $NTFY_TOPIC from its environment, so
    # render the topic into an EnvironmentFile for the service (below).
    templates."grafana-ntfy.env".content = "NTFY_TOPIC=${config.sops.placeholder.ntfy_topic}";
  };

  # Metrics TSDB. PromQL-compatible, but far lighter than Prometheus on a Pi.
  # Agents push here via remote_write (`/api/v1/write`); it does not scrape.
  services.victoriametrics = {
    enable = true;
    listenAddress = ":8428";
    retentionPeriod = "90d";
    stateDir = "monitoring/victoriametrics";
  };

  # The module runs VictoriaMetrics with DynamicUser, which relocates
  # StateDirectory data to /var/lib/private (symlinked back) - bypassing the
  # /var/lib/monitoring volume. Run it as a static user so the data really lands
  # on the volume. Also drop PrivateUsers: it needs (nested) user namespaces the
  # unprivileged container lacks, so the unit would otherwise fail to start.
  users.users.victoriametrics = {
    isSystemUser = true;
    group = "victoriametrics";
  };
  users.groups.victoriametrics = { };
  systemd.services.victoriametrics.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "victoriametrics";
    Group = "victoriametrics";
    PrivateUsers = lib.mkForce false;
  };

  # Log store. Single binary, filesystem chunks, 30-day retention.
  services.loki = {
    enable = true;
    dataDir = "/var/lib/monitoring/loki";
    configuration = {
      auth_enabled = false;
      server = {
        http_listen_port = 3100;
        grpc_listen_port = 9096;
      };
      common = {
        path_prefix = "/var/lib/monitoring/loki";
        storage.filesystem = {
          chunks_directory = "/var/lib/monitoring/loki/chunks";
          rules_directory = "/var/lib/monitoring/loki/rules";
        };
        replication_factor = 1;
        ring = {
          instance_addr = "127.0.0.1";
          kvstore.store = "inmemory";
        };
      };
      schema_config.configs = [
        {
          from = "2020-10-24";
          store = "tsdb";
          object_store = "filesystem";
          schema = "v13";
          index = {
            prefix = "index_";
            period = "24h";
          };
        }
      ];
      limits_config.retention_period = "30d";
      compactor = {
        working_directory = "/var/lib/monitoring/loki/compactor";
        retention_enabled = true;
        delete_request_store = "filesystem";
      };
    };
  };

  # Dashboards + (later) alerting. Admin password and secret key come from sops
  # via Grafana's file provider; datasources are provisioned so they exist on
  # first boot. OIDC (Kanidm) replaces the admin login in a later phase.
  services.grafana = {
    enable = true;
    dataDir = "/var/lib/monitoring/grafana";
    settings = {
      server = {
        # Grafana listens on loopback only; nginx terminates TLS and proxies.
        http_addr = "127.0.0.1";
        http_port = 3000;
        domain = "monitoring.${config.local.domain}";
        root_url = "https://monitoring.${config.local.domain}/";
      };
      security = {
        admin_user = "admin";
        admin_password = "$__file{${config.sops.secrets.grafana_admin_password.path}}";
        secret_key = "$__file{${config.sops.secrets.grafana_secret_key.path}}";
        # Accept the browser's Origin (Grafana otherwise compares it to the
        # proxied request host and rejects queries with "origin not allowed").
        csrf_trusted_origins = "https://monitoring.${config.local.domain}";
      };
      # Login via Kanidm (OIDC/passkeys). Roles come from the `grafana_role`
      # claim that Kanidm builds from group membership. The admin password above
      # stays as a localhost break-glass.
      "auth.generic_oauth" = {
        enabled = true;
        name = "Kanidm";
        client_id = "grafana";
        client_secret = "$__file{${config.sops.secrets.grafana_oidc_secret.path}}";
        scopes = "openid profile email groups";
        auth_url = "https://idm.${config.local.domain}/ui/oauth2";
        token_url = "https://idm.${config.local.domain}/oauth2/token";
        api_url = "https://idm.${config.local.domain}/oauth2/openid/grafana/userinfo";
        use_pkce = true;
        use_refresh_token = true;
        allow_sign_up = true;
        login_attribute_path = "preferred_username";
        groups_attribute_path = "groups";
        role_attribute_path = "contains(grafana_role[*], 'GrafanaAdmin') && 'GrafanaAdmin' || 'Viewer'";
        allow_assign_grafana_admin = true;
      };
    };
    provision.datasources.settings = {
      apiVersion = 1;
      datasources = [
        {
          name = "VictoriaMetrics";
          uid = "victoriametrics";
          type = "prometheus";
          access = "proxy";
          url = "http://127.0.0.1:8428";
          isDefault = true;
        }
        {
          name = "Loki";
          uid = "loki";
          type = "loki";
          access = "proxy";
          url = "http://127.0.0.1:3100";
        }
      ];
      # Grafana won't adopt a new UID for an existing datasource, so drop any
      # pre-existing ones (matched by name) and let the entries above recreate
      # them with the fixed UIDs the alert rules reference.
      deleteDatasources = [
        {
          name = "VictoriaMetrics";
          orgId = 1;
        }
        {
          name = "Loki";
          orgId = 1;
        }
      ];
    };

    # Dashboards (JSON files under ./dashboards), loaded on startup.
    provision.dashboards.settings = {
      apiVersion = 1;
      providers = [
        {
          name = "default";
          orgId = 1;
          folder = "Homelab";
          type = "file";
          disableDeletion = false;
          options.path = ./dashboards;
        }
      ];
    };

    # Alerts -> ntfy.sh. `$NTFY_TOPIC` is interpolated by Grafana's provisioning
    # from the service environment (sops -> EnvironmentFile, set below), so the
    # topic never lands in the store. ntfy receives Grafana's webhook JSON body.
    provision.alerting.contactPoints.settings = {
      apiVersion = 1;
      contactPoints = [
        {
          orgId = 1;
          name = "ntfy";
          receivers = [
            {
              uid = "ntfy";
              type = "webhook";
              settings = {
                # Grafana's webhook always sends JSON; the local relay reformats
                # it into ntfy's native format (see grafana-ntfy-relay below).
                url = "http://127.0.0.1:9123/";
                httpMethod = "POST";
              };
            }
          ];
        }
      ];
    };

    provision.alerting.policies.settings = {
      apiVersion = 1;
      policies = [
        {
          orgId = 1;
          receiver = "ntfy";
          group_by = [ "alertname" ];
          group_wait = "30s";
          group_interval = "5m";
          repeat_interval = "4h";
        }
      ];
    };

    provision.alerting.rules.settings = {
      apiVersion = 1;
      groups = [
        {
          orgId = 1;
          name = "homelab";
          folder = "Alerts";
          interval = "1m";
          rules = [
            {
              uid = "node-down";
              title = "Node down";
              condition = "C";
              data = [
                {
                  refId = "A";
                  relativeTimeRange = {
                    from = 300;
                    to = 0;
                  };
                  datasourceUid = "victoriametrics";
                  model = {
                    datasource = {
                      type = "prometheus";
                      uid = "victoriametrics";
                    };
                    editorMode = "code";
                    # Scope to the node exporter scrape so the blackbox probe's
                    # own `up` (host=null) doesn't trip this.
                    expr = "up{job=\"integrations/unix\"}";
                    instant = true;
                    range = false;
                    refId = "A";
                  };
                }
                {
                  refId = "C";
                  datasourceUid = "__expr__";
                  model = {
                    conditions = [
                      {
                        evaluator = {
                          type = "lt";
                          params = [ 1 ];
                        };
                        operator.type = "and";
                        query.params = [ "A" ];
                        reducer.type = "last";
                        type = "query";
                      }
                    ];
                    datasource = {
                      type = "__expr__";
                      uid = "__expr__";
                    };
                    expression = "A";
                    refId = "C";
                    type = "threshold";
                  };
                }
              ];
              # Agents push; a node that stops reporting pushes nothing, so treat
              # NoData as down too (otherwise a dead node looks like "no alert").
              noDataState = "Alerting";
              execErrState = "Alerting";
              "for" = "5m";
              labels.severity = "critical";
              annotations.summary = "{{ $labels.host }} stopped reporting";
            }
            {
              uid = "disk-space";
              title = "Disk space low";
              condition = "C";
              data = [
                {
                  refId = "A";
                  relativeTimeRange = {
                    from = 600;
                    to = 0;
                  };
                  datasourceUid = "victoriametrics";
                  model = {
                    datasource = {
                      type = "prometheus";
                      uid = "victoriametrics";
                    };
                    editorMode = "code";
                    expr = ''node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs|autofs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs|autofs"}'';
                    instant = true;
                    range = false;
                    refId = "A";
                  };
                }
                {
                  refId = "C";
                  datasourceUid = "__expr__";
                  model = {
                    conditions = [
                      {
                        evaluator = {
                          type = "lt";
                          params = [ 0.15 ];
                        };
                        operator.type = "and";
                        query.params = [ "A" ];
                        reducer.type = "last";
                        type = "query";
                      }
                    ];
                    datasource = {
                      type = "__expr__";
                      uid = "__expr__";
                    };
                    expression = "A";
                    refId = "C";
                    type = "threshold";
                  };
                }
              ];
              noDataState = "OK";
              execErrState = "Alerting";
              "for" = "15m";
              labels.severity = "warning";
              annotations.summary = "{{ $labels.host }} {{ $labels.mountpoint }} under 15% free";
            }
            {
              uid = "cert-expiry";
              title = "Certificate expiring soon";
              condition = "C";
              data = [
                {
                  refId = "A";
                  relativeTimeRange = {
                    from = 300;
                    to = 0;
                  };
                  datasourceUid = "victoriametrics";
                  model = {
                    datasource = {
                      type = "prometheus";
                      uid = "victoriametrics";
                    };
                    editorMode = "code";
                    # Seconds until the probed cert expires (blackbox probe).
                    expr = "probe_ssl_earliest_cert_expiry - time()";
                    instant = true;
                    range = false;
                    refId = "A";
                  };
                }
                {
                  refId = "C";
                  datasourceUid = "__expr__";
                  model = {
                    conditions = [
                      {
                        # 1209600s = 14 days.
                        evaluator = {
                          type = "lt";
                          params = [ 1209600 ];
                        };
                        operator.type = "and";
                        query.params = [ "A" ];
                        reducer.type = "last";
                        type = "query";
                      }
                    ];
                    datasource = {
                      type = "__expr__";
                      uid = "__expr__";
                    };
                    expression = "A";
                    refId = "C";
                    type = "threshold";
                  };
                }
              ];
              noDataState = "OK";
              execErrState = "Alerting";
              "for" = "15m";
              labels.severity = "warning";
              annotations.summary = "{{ $labels.instance }} cert expires in under 14 days";
            }
            {
              uid = "systemd-failed";
              title = "Systemd unit failed";
              condition = "C";
              data = [
                {
                  refId = "A";
                  relativeTimeRange = {
                    from = 300;
                    to = 0;
                  };
                  datasourceUid = "victoriametrics";
                  model = {
                    datasource = {
                      type = "prometheus";
                      uid = "victoriametrics";
                    };
                    editorMode = "code";
                    expr = "node_systemd_unit_state{state=\"failed\"} == 1";
                    instant = true;
                    range = false;
                    refId = "A";
                  };
                }
                {
                  refId = "C";
                  datasourceUid = "__expr__";
                  model = {
                    conditions = [
                      {
                        evaluator = {
                          type = "gt";
                          params = [ 0 ];
                        };
                        operator.type = "and";
                        query.params = [ "A" ];
                        reducer.type = "last";
                        type = "query";
                      }
                    ];
                    datasource = {
                      type = "__expr__";
                      uid = "__expr__";
                    };
                    expression = "A";
                    refId = "C";
                    type = "threshold";
                  };
                }
              ];
              noDataState = "OK";
              execErrState = "Alerting";
              "for" = "5m";
              labels.severity = "warning";
              annotations.summary = "{{ $labels.name }} failed on {{ $labels.host }}";
            }
            {
              uid = "home-assistant-down";
              title = "Home Assistant down";
              condition = "C";
              data = [
                {
                  refId = "A";
                  relativeTimeRange = {
                    from = 300;
                    to = 0;
                  };
                  datasourceUid = "victoriametrics";
                  model = {
                    datasource = {
                      type = "prometheus";
                      uid = "victoriametrics";
                    };
                    editorMode = "code";
                    expr = "up{job=\"home-assistant\"}";
                    instant = true;
                    range = false;
                    refId = "A";
                  };
                }
                {
                  refId = "C";
                  datasourceUid = "__expr__";
                  model = {
                    conditions = [
                      {
                        evaluator = {
                          type = "lt";
                          params = [ 1 ];
                        };
                        operator.type = "and";
                        query.params = [ "A" ];
                        reducer.type = "last";
                        type = "query";
                      }
                    ];
                    datasource = {
                      type = "__expr__";
                      uid = "__expr__";
                    };
                    expression = "A";
                    refId = "C";
                    type = "threshold";
                  };
                }
              ];
              noDataState = "OK";
              execErrState = "Alerting";
              "for" = "5m";
              labels.severity = "critical";
              annotations.summary = "Home Assistant metrics scrape failed (service down or /api/prometheus unreadable)";
            }
            {
              uid = "zigbee2mqtt-bridge-offline";
              title = "Zigbee2MQTT bridge offline";
              condition = "C";
              data = [
                {
                  refId = "A";
                  relativeTimeRange = {
                    from = 300;
                    to = 0;
                  };
                  datasourceUid = "victoriametrics";
                  model = {
                    datasource = {
                      type = "prometheus";
                      uid = "victoriametrics";
                    };
                    editorMode = "code";
                    expr = "mqtt_state{topic=\"zigbee2mqtt_bridge_state\"}";
                    instant = true;
                    range = false;
                    refId = "A";
                  };
                }
                {
                  refId = "C";
                  datasourceUid = "__expr__";
                  model = {
                    conditions = [
                      {
                        evaluator = {
                          type = "lt";
                          params = [ 1 ];
                        };
                        operator.type = "and";
                        query.params = [ "A" ];
                        reducer.type = "last";
                        type = "query";
                      }
                    ];
                    datasource = {
                      type = "__expr__";
                      uid = "__expr__";
                    };
                    expression = "A";
                    refId = "C";
                    type = "threshold";
                  };
                }
              ];
              # No series means the broker/exporter is already covered by its
              # own rule; don't double-alert here.
              noDataState = "OK";
              execErrState = "Alerting";
              "for" = "5m";
              labels.severity = "critical";
              annotations.summary = "Zigbee2MQTT reports the bridge offline";
            }
            {
              uid = "zigbee2mqtt-exporter-down";
              title = "Zigbee2MQTT exporter down";
              condition = "C";
              data = [
                {
                  refId = "A";
                  relativeTimeRange = {
                    from = 300;
                    to = 0;
                  };
                  datasourceUid = "victoriametrics";
                  model = {
                    datasource = {
                      type = "prometheus";
                      uid = "victoriametrics";
                    };
                    editorMode = "code";
                    expr = "up{job=\"zigbee2mqtt\"}";
                    instant = true;
                    range = false;
                    refId = "A";
                  };
                }
                {
                  refId = "C";
                  datasourceUid = "__expr__";
                  model = {
                    conditions = [
                      {
                        evaluator = {
                          type = "lt";
                          params = [ 1 ];
                        };
                        operator.type = "and";
                        query.params = [ "A" ];
                        reducer.type = "last";
                        type = "query";
                      }
                    ];
                    datasource = {
                      type = "__expr__";
                      uid = "__expr__";
                    };
                    expression = "A";
                    refId = "C";
                    type = "threshold";
                  };
                }
              ];
              noDataState = "OK";
              execErrState = "Alerting";
              "for" = "5m";
              labels.severity = "warning";
              annotations.summary = "Zigbee2MQTT metrics exporter is unreachable";
            }
            {
              uid = "restic-backup-stale";
              title = "Backup stale";
              condition = "C";
              data = [
                {
                  refId = "A";
                  relativeTimeRange = {
                    from = 300;
                    to = 0;
                  };
                  datasourceUid = "victoriametrics";
                  model = {
                    datasource = {
                      type = "prometheus";
                      uid = "victoriametrics";
                    };
                    editorMode = "code";
                    # Seconds since the newest snapshot for this host (48h limit).
                    expr = "time() - max by (host) (restic_backup_timestamp)";
                    instant = true;
                    range = false;
                    refId = "A";
                  };
                }
                {
                  refId = "C";
                  datasourceUid = "__expr__";
                  model = {
                    conditions = [
                      {
                        evaluator = {
                          type = "gt";
                          params = [ 172800 ];
                        };
                        operator.type = "and";
                        query.params = [ "A" ];
                        reducer.type = "last";
                        type = "query";
                      }
                    ];
                    datasource = {
                      type = "__expr__";
                      uid = "__expr__";
                    };
                    expression = "A";
                    refId = "C";
                    type = "threshold";
                  };
                }
              ];
              noDataState = "OK";
              execErrState = "Alerting";
              "for" = "15m";
              labels.severity = "critical";
              annotations.summary = "{{ $labels.host }} has no backup newer than 48h";
            }
            {
              uid = "restic-check-failed";
              title = "Backup integrity check failed";
              condition = "C";
              data = [
                {
                  refId = "A";
                  relativeTimeRange = {
                    from = 300;
                    to = 0;
                  };
                  datasourceUid = "victoriametrics";
                  model = {
                    datasource = {
                      type = "prometheus";
                      uid = "victoriametrics";
                    };
                    editorMode = "code";
                    expr = "restic_check_success";
                    instant = true;
                    range = false;
                    refId = "A";
                  };
                }
                {
                  refId = "C";
                  datasourceUid = "__expr__";
                  model = {
                    conditions = [
                      {
                        evaluator = {
                          type = "lt";
                          params = [ 1 ];
                        };
                        operator.type = "and";
                        query.params = [ "A" ];
                        reducer.type = "last";
                        type = "query";
                      }
                    ];
                    datasource = {
                      type = "__expr__";
                      uid = "__expr__";
                    };
                    expression = "A";
                    refId = "C";
                    type = "threshold";
                  };
                }
              ];
              noDataState = "OK";
              execErrState = "Alerting";
              "for" = "15m";
              labels.severity = "critical";
              annotations.summary = "{{ $labels.host }} restic repository check failed";
            }
          ];
        }
      ];
    };
  };

  # The relay reads the ntfy topic (secret) from this env file. Only the homelab
  # runs it: it is the one component that talks to an external service
  # (ntfy.sh), and `dev` must stay isolated.
  systemd.services.grafana-ntfy-relay = lib.mkIf (config.local.env == "homelab") {
    description = "Reformat Grafana alert webhooks into ntfy notifications";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${relayScript}";
      EnvironmentFile = config.sops.templates."grafana-ntfy.env".path;
      DynamicUser = true;
      Restart = "on-failure";
    };
  };

  # Blackbox probes for TLS certificate expiry, so a silently-failed renewal is
  # caught long before a 90-day cert runs out. The agent's main config already
  # defines prometheus.remote_write.default; this extra file just adds the
  # exporter + scrape (Alloy loads every /etc/alloy/*.alloy file).
  environment.etc."alloy/blackbox.alloy".text = ''
    prometheus.exporter.blackbox "certs" {
      config = "{ modules: { http_2xx: { prober: http, timeout: 5s } } }"

      // Only service certs we issue - not step-ca's own server cert, which is
      // deliberately short-lived (24h) and auto-rotated, so its expiry is never
      // actionable and would always trip the rule.
      target {
        name    = "monitoring"
        address = "https://monitoring.${config.local.domain}"
        module  = "http_2xx"
      }
    }

    prometheus.scrape "blackbox" {
      targets    = prometheus.exporter.blackbox.certs.targets
      forward_to = [prometheus.remote_write.default.receiver]
    }
  '';

  # Scrape the monitoring stack's own /metrics, so a pipeline problem (ingestion,
  # storage, query latency) is visible rather than just "alerts stopped".
  environment.etc."alloy/self.alloy".text = ''
    prometheus.scrape "victoriametrics" {
      targets    = [{ __address__ = "127.0.0.1:8428" }]
      forward_to = [prometheus.remote_write.default.receiver]
    }
    prometheus.scrape "loki" {
      targets    = [{ __address__ = "127.0.0.1:3100" }]
      forward_to = [prometheus.remote_write.default.receiver]
    }
    prometheus.scrape "grafana" {
      targets    = [{ __address__ = "127.0.0.1:3000" }]
      forward_to = [prometheus.remote_write.default.receiver]
    }
  '';

  environment.etc."alloy/centralized.alloy".text = centralScrapes;

  # Loki is the durable log store; the local journal only needs to buffer
  # between Alloy reads. The remote journal spool below is also tmpfs: it is a
  # hand-off to Vector, not an archive, and keeping both on NVMe only caused
  # journald rewrite amplification.
  services.journald = {
    storage = "volatile";
    extraConfig = "RuntimeMaxUse=64M";
  };

  systemd.tmpfiles.rules = [
    "d /run/journal-remote 0755 root root -"
    "d /var/lib/monitoring/vector 0755 root root -"
  ];

  systemd.services.journal-remote = {
    description = "Accept journal uploads from guests";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-tmpfiles-setup.service" ];
    serviceConfig = {
      ExecStart = "${config.systemd.package}/lib/systemd/systemd-journal-remote --listen-http=0.0.0.0:19532 --output=/run/journal-remote/remote.journal --split-mode=none --compress=yes";
      UMask = "0022";
      Restart = "on-failure";
      RestartSec = "5s";
      User = "root";
    };
  };

  systemd.services.journal-remote-cleanup = {
    description = "Delete uploaded journals older than 24 hours (tmpfs spool)";
    startAt = "hourly";
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.findutils}/bin/find /run/journal-remote -type f -name '*.journal*' -mmin +1440 -delete
    '';
  };

  # Read the uploaded journal files and push them to Loki. Running as root
  # avoids DynamicUser/StateDirectory ownership problems on the shared volume.
  services.vector = {
    enable = true;
    settings = {
      data_dir = "/var/lib/monitoring/vector";
      sources.remote_journal = {
        type = "journald";
        journal_directory = "/run/journal-remote";
        current_boot_only = false;
        since_now = true;
      };
      transforms.journal = {
        type = "remap";
        inputs = [ "remote_journal" ];
        source = ''
          if exists(."_HOSTNAME") {
            .host = ."_HOSTNAME"
          }
          .job = "systemd-journal"
        '';
      };
      sinks.loki = {
        type = "loki";
        inputs = [ "journal" ];
        endpoint = "http://127.0.0.1:3100";
        encoding.codec = "json";
        labels = {
          host = "{{ host }}";
          job = "{{ job }}";
        };
      };
    };
  };

  systemd.services.vector.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = lib.mkForce "root";
    Group = lib.mkForce "root";
  };

  # `.dev` is HSTS-preloaded, so the Grafana web UI must be HTTPS. Grafana has no
  # ACME challenge server, so nginx terminates TLS on :443 (and serves the
  # http-01 challenge on :80), proxying to Grafana on loopback. Certs come from
  # the internal step-ca and chain to the Esselius Root CA - trusted on the Mac,
  # and by this guest via certificateFiles below.
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
    # Forward Host + X-Forwarded-* so Grafana knows its external origin; without
    # this it sees Host `127.0.0.1:3000` and rejects the browser's Origin
    # ("origin not allowed" on datasource queries).
    recommendedProxySettings = true;
    virtualHosts."monitoring.${config.local.domain}" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:3000";
        proxyWebsockets = true;
      };
    };
  };

  # nginx (80 for the ACME challenge, 443 for the UI), VictoriaMetrics (8428)
  # and Loki (3100) for the Alloy agents, plus SSH - all only on the private
  # backplane.
  networking.firewall.interfaces.eth0.allowedTCPPorts = [
    22
    80
    443
    3100
    8428
    19532
  ];

  system.stateVersion = "26.05";
}
