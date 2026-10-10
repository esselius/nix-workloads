{ lib, config, ... }:
let
  # Pin the address on the vpn bridge so clients (MQTT, etc.) have a stable
  # target, and a cross-host move keeps the same IP (provided the destination
  # host's bridge is the same subnet). Keep it unique per workload and outside
  # any host-reserved range.
  staticIp = "10.43.0.10";
in
{
  # Skeleton workload. To add a new one, copy this directory:
  #   1. terraform/<name>/default.nix      - this file, rename the resource
  #   2. flake.nix                          - add a terranix.terranixConfigurations.<name>
  #   3. guests/<name>/default.nix          - the NixOS system deployed inside it
  #
  # `default` provides connectivity + storage; `container` adds the host's
  # resource limits; `vpn` overrides `default`'s eth0 to put the instance on the
  # WireGuard-reachable bridge (`incusbr-vpn`, 10.43.0.0/24) instead of the
  # NAT'd `incusbr0`. See nix-homelab-hosts modules/incus/{profiles,network}.nix.
  resource.incus_instance.example = {
    name = "example";
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

    # The stock NixOS image ships no cloud-init and no authorized key, so seed
    # root's key once at create time. `--uid/--gid/--mode` are required: without
    # them `file push` copies the Mac's source ownership (501:20) and mode,
    # which trips sshd's StrictModes. Requires the `incus` CLI on PATH (the
    # devshell and the `tf` wrapper provide it) with the host as default remote.
    # Runs only on create; guests/example/default.nix keeps the key thereafter.
    provisioner = [
      {
        "local-exec".command = ''
          incus file push --uid 0 --gid 0 --mode 600 "$HOME/.ssh/id_ed25519.pub" "''${self.name}/root/.ssh/authorized_keys" --create-dirs
        '';
      }
    ];
  };
}
