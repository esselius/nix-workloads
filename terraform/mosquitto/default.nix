{ lib, config, ... }:
let
  # Stable target for the MQTT clients (z2m/hass/nr/p1ib). See README Networking.
  inv = import ../../inventory.nix;
  staticIp = inv.ipFor config.local.env "mosquitto";
  mem = inv.memory.mosquitto;
in
{
  resource.incus_instance.mosquitto = {
    name = "mosquitto";
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

    # NOTE: security.nesting is intentionally off. The guest patches LXC's
    # distrobuilder generator so systemd credentials (the broker passwords)
    # survive without nesting - see guests/mosquitto/default.nix.

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
    ]
    ++ lib.optionals config.local.lan.enable [
      {
        # Second NIC: macvlan on the LAN, so WiFi/LAN MQTT clients (p1ib, ESP
        # devices) reach the broker without WireGuard. The address is set
        # statically in the guest (guests/mosquitto) - incus does not push a
        # macvlan address.
        name = "eth1";
        type = "nic";
        properties = {
          nictype = "macvlan";
          parent = config.local.lanParent;
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
