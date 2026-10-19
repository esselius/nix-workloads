{
  config,
  lib,
  ...
}:
let
  cfg = config.local.monitoring;
  hostName = config.networking.hostName;
in
{
  # Shared Grafana Alloy agent: one process per node that ships node metrics to
  # VictoriaMetrics (remote_write) and the systemd journal to Loki. Imported by
  # every guest; the Pi hosts run an equivalent agent from nix-homelab-hosts.
  options.local.monitoring = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Ship node metrics and journal to the monitoring workload.";
    };
    mode = lib.mkOption {
      type = lib.types.enum [
        "alloy"
        "light"
      ];
      default = "alloy";
      description = ''
        `alloy` runs the full per-guest Alloy agent. `light` runs a small
        node_exporter plus systemd-journal-upload instead; the monitoring Alloy
        scrapes the guest centrally.
      '';
    };
    address = lib.mkOption {
      type = lib.types.str;
      default = "monitoring.${config.local.domain}";
      description = ''
        Monitoring workload (VictoriaMetrics + Loki) host, resolved via the
        internal split DNS. Using the name (not the pinned 10.43.0.12) means
        moving the workload only needs the coredns zone updated.
      '';
    };
  };

  config = {
    # Only the homelab ships metrics/logs to the monitoring workload; a dev
    # env is deliberately isolated from external services.
    local.monitoring.enable = lib.mkDefault (config.local.env == "homelab");

    services.alloy.enable = cfg.enable && cfg.mode == "alloy";

    # Bound the Go heap so Alloy does not hold pages it will never use again.
    # GOGC trades CPU for a smaller steady-state RSS. Only define the service
    # overrides when Alloy is enabled; otherwise an empty unit would be created.
    systemd.services.alloy = lib.mkIf (cfg.enable && cfg.mode == "alloy") {
      environment = {
        GOMEMLIMIT = "192MiB";
        GOGC = "100";
      };
    };

    services.alloy.extraFlags = lib.mkIf (cfg.enable && cfg.mode == "alloy") [ "--disable-reporting" ];

    # The alloy module reads /etc/alloy/config.alloy (a store path here, so a
    # change restarts the unit rather than hot-reloading - fine for this).
    environment.etc."alloy/config.alloy".text = ''
      // Node metrics, scraped locally and remote-written to VictoriaMetrics.
      // Only the collectors the dashboards need, so node_exporter does not
      // carry the full default set.
      prometheus.exporter.unix "node" {
        set_collectors = [
          "cpu",
          "diskstats",
          "filesystem",
          "loadavg",
          "meminfo",
          "netdev",
          "pressure",
          "stat",
          "systemd",
          "thermal_zone",
          "vmstat",
        ]
      }

      prometheus.scrape "node" {
        targets         = prometheus.exporter.unix.node.targets
        scrape_interval = "2m"
        forward_to      = [prometheus.relabel.host.receiver]
      }

      // Tag every series with this host so nodes don't collide on `instance`.
      prometheus.relabel "host" {
        forward_to = [prometheus.remote_write.default.receiver]

        rule {
          target_label = "host"
          replacement  = "${hostName}"
        }

        // The node exporter stamps the same job="integrations/unix" on hosts
        // and guests, so a guest's node_* series otherwise look like a physical
        // node. Mark them container-origin; the physical-node dashboards filter
        // these out with node_type!="container".
        rule {
          target_label = "node_type"
          replacement  = "container"
        }
      }

      prometheus.remote_write "default" {
        endpoint {
          url = "http://${cfg.address}:8428/api/v1/write"
        }
      }

      // systemd journal -> Loki.
      loki.source.journal "journal" {
        forward_to = [loki.write.default.receiver]
        labels     = { host = "${hostName}", job = "systemd-journal" }
      }

      loki.write "default" {
        endpoint {
          url = "http://${cfg.address}:3100/loki/api/v1/push"
        }
      }
    '';

    # Light mode: no Alloy in the guest. A small node_exporter exposes node
    # metrics and failed units; systemd-journal-upload ships logs to the
    # monitoring guest, which reads them with Vector.
    services.prometheus.exporters.node = lib.mkIf (cfg.enable && cfg.mode == "light") {
      enable = true;
      listenAddress = "0.0.0.0";
      port = 9100;
      enabledCollectors = [ "systemd" ];
      user = "root";
      group = "root";
    };

    systemd.services.journal-upload = lib.mkIf (cfg.enable && cfg.mode == "light") {
      description = "Upload the system journal to the monitoring guest";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${config.systemd.package}/lib/systemd/systemd-journal-upload --url=http://${cfg.address}:19532 --system --follow --save-state=/var/lib/journal-upload/state";
        StateDirectory = "journal-upload";
        Restart = "on-failure";
        RestartSec = "5s";
        User = "root";
      };
    };

    networking.firewall.interfaces.eth0.allowedTCPPorts = lib.mkIf (cfg.enable && cfg.mode == "light") [
      9100
    ];
  };
}
