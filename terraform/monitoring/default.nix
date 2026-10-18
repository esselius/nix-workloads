{ lib, config, ... }:
let
  # Metrics + logs + dashboards. Pinned on the vpn bridge; Alloy agents on the
  # hosts and guests push here, and Grafana is reached by name
  # (`monitoring.int.esselius.dev`, an A record in the coredns zone).
  inv = import ../../inventory.nix;
  staticIp = inv.ipFor config.local.env "monitoring";
  mem = inv.memory.monitoring;
in
{
  # Custom storage volume for the monitoring stack's state, on the host's
  # persistent pool. Recreated empty on `task down` + `task up`; the instance
  # device above mounts it at /var/lib/monitoring.
  resource.incus_storage_volume.monitoring_data = {
    name = "monitoring-data";
    pool = config.local.storagePool;
    content_type = "filesystem";

    # Guard the metrics/logs history: `task down` (tofu destroy) refuses rather
    # than silently wiping it. Remove this block (or `tofu state rm` the volume)
    # to actually reclaim the space.
    lifecycle.prevent_destroy = true;
  };

  resource.incus_instance.monitoring = {
    name = "monitoring";
    image = "images:nixos/26.05";
    profiles = [
      "default"
      "container"
      "vpn"
    ];
    running = true;

    config = {
      "limits.memory" = mem.limit;
      "limits.memory.swap" = mem.swap;
      "limits.memory.oom_priority" = mem.oomPriority;
    };

    # Persistent data volume, mounted before the guest starts, so VictoriaMetrics
    # / Loki / Grafana state survives `task down` / `task up`. The guest writes
    # subdirectories of /var/lib/monitoring (see guests/monitoring).
    depends_on = [ "incus_storage_volume.monitoring_data" ];

    # Instance-level eth0 override. incus validates the instance device on its
    # own (it does not inherit the profile's `network`), so the full NIC has to
    # be restated here, pinned to the same bridge as the `vpn` profile.
    device = [
      {
        name = "eth0";
        type = "nic";
        properties = {
          "network" = config.local.vpnBridge;
          "ipv4.address" = staticIp;
        };
      }
      {
        # Persistent data volume (see the resource below). Mounted at
        # /var/lib/monitoring; the guest's services store their data beneath it.
        name = "data";
        type = "disk";
        properties = {
          pool = config.local.storagePool;
          source = "monitoring-data";
          path = "/var/lib/monitoring";
        };
      }
    ];

    # Seed root's SSH key on create (see terraform/example/default.nix for why
    # `incus file push` needs the uid/gid/mode flags). Runs only on create.
    provisioner = [
      {
        "local-exec".command = ''
          incus file push --uid 0 --gid 0 --mode 600 "$HOME/.ssh/id_ed25519.pub" "''${self.name}/root/.ssh/authorized_keys" --create-dirs
        '';
      }
    ];
  };
}
