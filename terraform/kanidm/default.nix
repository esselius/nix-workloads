{ lib, config, ... }:
let
  # OIDC identity provider (WebAuthn/passkeys). Pinned on the vpn bridge;
  # reached by name (`idm.int.esselius.dev`, an A record in the network zone).
  inv = import ../../inventory.nix;
  staticIp = inv.ipFor config.local.env "kanidm";
  mem = inv.memory.kanidm;
in
{
  # Kanidm's database is its whole identity store, so keep it on a volume.
  resource.incus_storage_volume.kanidm_data = {
    name = "kanidm-data";
    pool = config.local.storagePool;
    content_type = "filesystem";

    lifecycle.prevent_destroy = true;
  };

  resource.incus_instance.kanidm = {
    name = "kanidm";
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

    depends_on = [ "incus_storage_volume.kanidm_data" ];

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
        # Persistent state: /var/lib/kanidm (db, backups).
        name = "data";
        type = "disk";
        properties = {
          pool = config.local.storagePool;
          source = "kanidm-data";
          path = "/var/lib/kanidm";
        };
      }
    ];

    provisioner = [
      {
        "local-exec".command = ''
          incus file push --uid 0 --gid 0 --mode 600 "$HOME/.ssh/id_ed25519.pub" "''${self.name}/root/.ssh/authorized_keys" --create-dirs
        '';
      }
    ];
  };
}
