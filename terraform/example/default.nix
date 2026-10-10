{ lib, ... }:
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
