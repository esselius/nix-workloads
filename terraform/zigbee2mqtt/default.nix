{ lib, config, ... }:
let
  # Zigbee2MQTT (migrated off adama). Pinned to rpi5-8gb because the USB
  # coordinator is physical - the instance can never migrate with it. Reached as
  # `zigbee2mqtt.int.esselius.dev` (an A record in the network zone).
  inv = import ../../inventory.nix;
  staticIp = inv.ipFor config.local.env "zigbee2mqtt";
  mem = inv.memory.zigbee2mqtt;
in
{
  # Persistent volume for Zigbee2MQTT state (device database + coordinator
  # backup), mounted at /var/lib/zigbee2mqtt.
  resource.incus_storage_volume.zigbee2mqtt_data = {
    name = "zigbee2mqtt-data";
    pool = config.local.storagePool;
    content_type = "filesystem";

    # Guard the Zigbee state: `task down` (tofu destroy) refuses rather than
    # silently wiping it. Remove this block (or `tofu state rm` the volume) to
    # actually reclaim the space.
    lifecycle.prevent_destroy = true;
  };

  resource.incus_instance.zigbee2mqtt = {
    name = "zigbee2mqtt";
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

    depends_on = [ "incus_storage_volume.zigbee2mqtt_data" ];

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
        # Zigbee2MQTT state (see the volume resource above).
        name = "data";
        type = "disk";
        properties = {
          pool = config.local.storagePool;
          source = "zigbee2mqtt-data";
          path = "/var/lib/zigbee2mqtt";
        };
      }
      {
        # The USB coordinator (SONOFF ZBDongle-E, 1a86:55d4). unix-char passes
        # the host's stable by-id symlink at container start, which survives a
        # host reboot; unix-hotplug only reacts to devices that appear after the
        # container starts, so a reboot left /dev/ttyACM0 missing here.
        name = "coordinator";
        type = "unix-char";
        properties = {
          source = "/dev/serial/by-id/usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_V2_20230807100441-if00";
          path = "/dev/ttyACM0";
          # 0666 so the z2m service (which runs with PrivateUsers) can open it
          # regardless of the host's dialout GID vs the container's.
          mode = "0666";
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
