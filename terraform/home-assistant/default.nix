{ lib, config, ... }:
let
  # Home Assistant (migrated off adama). Recorder backed by the postgres
  # workload. Pinned on the vpn bridge; reached as
  # `home-assistant.int.esselius.dev` (an A record in the coredns zone).
  staticIp = "10.43.0.19";
in
{
  # Persistent volume for the whole HA config dir (configuration.yaml, .storage,
  # custom_components, ...), mounted at /var/lib/hass.
  resource.incus_storage_volume.home_assistant_data = {
    name = "home-assistant-data";
    pool = config.local.storagePool;
    content_type = "filesystem";

    # Guard the config/state: `task down` (tofu destroy) refuses rather than
    # silently wiping it. Remove this block (or `tofu state rm` the volume) to
    # actually reclaim the space.
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

    depends_on = [ "incus_storage_volume.home_assistant_data" ];

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
        # HA config/state (see the volume resource above).
        name = "data";
        type = "disk";
        properties = {
          pool = config.local.storagePool;
          source = "home-assistant-data";
          path = "/var/lib/hass";
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
