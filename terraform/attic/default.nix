{ lib, config, ... }:
let
  # Self-hosted Attic binary cache: the shared substituter the Mac's linux-builder
  # pushes to and every host/guest pulls from. Pinned on the vpn bridge; reached
  # as `cache.int.esselius.dev` (an A record in the coredns zone).
  staticIp = (import ../../inventory.nix).ipFor config.local.site "attic";
in
{
  # Persistent volume for the cache: sqlite DB + chunked NAR storage. Mounted at
  # /var/lib/atticd (the module's StateDirectory).
  resource.incus_storage_volume.attic_data = {
    name = "attic-data";
    pool = config.local.storagePool;
    content_type = "filesystem";

    # The cache is reproducible (rebuild + repush), but losing it means a cold
    # rebuild of everything; guard it so `task down` refuses rather than silently
    # wiping it. Remove this block (or `tofu state rm` the volume) to reclaim it.
    lifecycle.prevent_destroy = true;
  };

  resource.incus_instance.attic = {
    name = "attic";
    image = "images:nixos/26.05";
    profiles = [
      "default"
      "container"
      "vpn"
    ];
    running = true;

    depends_on = [ "incus_storage_volume.attic_data" ];

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
        # Cache state (see the volume resource above). Mounted at /var/lib/atticd;
        # the atticd module uses that as its StateDirectory.
        name = "data";
        type = "disk";
        properties = {
          pool = config.local.storagePool;
          source = "attic-data";
          path = "/var/lib/atticd";
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
