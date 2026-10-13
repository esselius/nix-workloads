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
  options.local.monitoring.address = lib.mkOption {
    type = lib.types.str;
    default = "monitoring.int.esselius.dev";
    description = ''
      Monitoring workload (VictoriaMetrics + Loki) host, resolved via the
      internal split DNS. Using the name (not the pinned 10.43.0.12) means moving
      the workload only needs the coredns zone updated.
    '';
  };

  config = {
    services.alloy.enable = true;

    # The alloy module reads /etc/alloy/config.alloy (a store path here, so a
    # change restarts the unit rather than hot-reloading - fine for this).
    environment.etc."alloy/config.alloy".text = ''
      // Node metrics, scraped locally and remote-written to VictoriaMetrics.
      // The systemd collector is off by default; enable it for failed-unit
      // alerting.
      prometheus.exporter.unix "node" {
        enable_collectors = ["systemd"]
      }

      prometheus.scrape "node" {
        targets    = prometheus.exporter.unix.node.targets
        forward_to = [prometheus.relabel.host.receiver]
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
  };
}
