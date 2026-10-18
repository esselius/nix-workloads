{ lib, config, ... }:
let
  # Restic REST server every guest pushes its state backups to. Pinned on the
  # vpn bridge; reached as `backup.int.esselius.dev` (an A record in the coredns
  # zone). Plain HTTP on the WireGuard-private backplane (as with MQTT) - restic
  # encrypts the repo client-side, so the transport only needs the private wire.
  inv = import ../../inventory.nix;
  staticIp = inv.ipFor config.local.env "backup";
  mem = inv.memory.backup;
in
{
  # Custom storage volume for the restic repositories, on the host's persistent
  # pool. Recreated empty on `task down` + `task up`; the instance device above
  # mounts it at /var/lib/restic.
  resource.incus_storage_volume.backup_data = {
    name = "backup-data";
    pool = config.local.storagePool;
    content_type = "filesystem";

    # Guard the backups: `task down` (tofu destroy) refuses rather than silently
    # wiping them. Remove this block (or `tofu state rm` the volume) to reclaim
    # the space.
    lifecycle.prevent_destroy = true;
  };

  resource.incus_instance.backup = {
    name = "backup";
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

    depends_on = [ "incus_storage_volume.backup_data" ];

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
        # Restic repositories (see the volume resource above).
        name = "data";
        type = "disk";
        properties = {
          pool = config.local.storagePool;
          source = "backup-data";
          path = "/var/lib/restic";
        };
      }
    ]
    ++ lib.optionals (config.local.env != "homelab") [
      {
        # Publish the dev backup server on the incus host's own address (the
        # Colima VM) so the Mac can `restic copy` production snapshots into
        # it - the Mac cannot route into the dev subnet. Dev-only: on the
        # homelab the REST server stays on the private backplane.
        name = "rest";
        type = "proxy";
        properties = {
          "listen" = "tcp:0.0.0.0:8000";
          "connect" = "tcp:${staticIp}:8000";
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
