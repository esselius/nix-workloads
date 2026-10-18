{ lib, config, ... }:
let
  # Internal-DNS workload. Pinned on the vpn bridge like every other workload.
  # WireGuard clients point their resolver here (`DNS = 10.43.0.14`); the address
  # is also the `ns1` A record inside the zone (guests/coredns). See README.
  staticIp = (import ../../inventory.nix).ipFor config.local.env "coredns";
in
{
  resource.incus_instance.coredns = {
    name = "coredns";
    image = "images:nixos/26.05";
    profiles = [
      "default"
      "container"
      "vpn"
    ];
    running = true;

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
