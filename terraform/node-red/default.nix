{ lib, config, ... }:
let
  # Node-RED (the smart-home automations, migrated off adama). Pinned on the vpn
  # bridge; reached as `node-red.int.esselius.dev` (an A record in the network
  # zone).
  inv = import ../../inventory.nix;
  staticIp = inv.ipFor config.local.env "node-red";
  mem = inv.memory.node-red;
in
{
  # Persistent volume for Node-RED's state: flows, credentials, palette and
  # context. Mounted at /var/lib/node-red (the module's StateDirectory).
  resource.incus_storage_volume.node_red_data = {
    name = "node-red-data";
    pool = config.local.storagePool;
    content_type = "filesystem";

    # Guard the flows/credentials: `task down` (tofu destroy) refuses rather than
    # silently wiping them. Remove this block (or `tofu state rm` the volume) to
    # actually reclaim the space.
    lifecycle.prevent_destroy = true;
  };

  resource.incus_instance.node_red = {
    name = "node-red";
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

    depends_on = [ "incus_storage_volume.node_red_data" ];

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
        # Node-RED state (see the volume resource above). Mounted at
        # /var/lib/node-red; the module uses that as its StateDirectory.
        name = "data";
        type = "disk";
        properties = {
          pool = config.local.storagePool;
          source = "node-red-data";
          path = "/var/lib/node-red";
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
