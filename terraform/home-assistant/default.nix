{ lib, config, ... }:
let
  # Home Assistant (migrated off adama). Recorder backed by a co-located
  # PostgreSQL (see guests/home-assistant). Pinned on the vpn bridge; reached as
  # `home-assistant.int.esselius.dev` (an A record in the network zone).
  inv = import ../../inventory.nix;
  staticIp = inv.ipFor config.local.env "home-assistant";
  mem = inv.memory.home-assistant;
in
{
  # Persistent volume for the whole HA config dir (configuration.yaml, .storage,
  # custom_components, ...), mounted at /var/lib/hass.
  resource.incus_storage_volume.home_assistant_data = {
    name = "home-assistant-data";
    pool = config.local.storagePool;
    content_type = "filesystem";

    config = config.local.snapshotPolicies.daily;

    # Guard the config/state: `task down` (tofu destroy) refuses rather than
    # silently wiping it. Remove this block (or `tofu state rm` the volume) to
    # actually reclaim the space.
    lifecycle.prevent_destroy = true;
  };

  # The recorder DB gets its own volume (mounted at /var/lib/postgresql, i.e.
  # systemd's `StateDirectory=postgresql`; the default dataDir is a versioned
  # subdir of it). Without this the DB would live on the container rootfs and a
  # recreate would silently drop the recorder history.
  resource.incus_storage_volume.home_assistant_postgres = {
    name = "home-assistant-postgres";
    pool = config.local.storagePool;
    content_type = "filesystem";

    # Crash-consistent only: use the restic `pg_dump` (local.backup.prepareCommand)
    # for a true database restore. The snapshot's value is a matching rollback
    # point for the config volume.
    config = config.local.snapshotPolicies.daily;

    lifecycle.prevent_destroy = true;
  };

  resource.incus_instance.home_assistant = {
    name = "home-assistant";
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

    depends_on = [
      "incus_storage_volume.home_assistant_data"
      "incus_storage_volume.home_assistant_postgres"
    ];

    device = [
      {
        name = "eth0";
        type = "nic";
        properties = {
          "network" = config.local.vpnBridge;
          "ipv4.address" = staticIp;
        };
      }
    ]
    ++ lib.optionals config.local.lan.enable [
      {
        # Second NIC: macvlan on the LAN, for discovery of cast/homekit/
        # zeroconf devices. The address is set statically in the guest
        # (guests/home-assistant) - incus does not push a macvlan address.
        name = "eth1";
        type = "nic";
        properties = {
          nictype = "macvlan";
          parent = config.local.lanParent;
        };
      }
    ]
    ++ [
      {
        # HA config/state (see the volume resource above).
        name = "data";
        type = "disk";
        properties = {
          pool = config.local.storagePool;
          source = "home-assistant-data";
          path = "/var/lib/hass";
        };
      }
      {
        # Recorder DB (see the volume resource above).
        name = "postgres";
        type = "disk";
        properties = {
          pool = config.local.storagePool;
          source = "home-assistant-postgres";
          path = "/var/lib/postgresql";
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
