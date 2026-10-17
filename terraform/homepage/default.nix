{ lib, config, ... }:
let
  # Landing page for the homelab. Pinned on the vpn bridge; reached as
  # `homepage.int.esselius.dev` (an A record in the coredns zone), gated by
  # oauth2-proxy -> Kanidm like the other web UIs.
  staticIp = (import ../../inventory.nix).ipFor config.local.site "homepage";
in
{
  resource.incus_instance.homepage = {
    name = "homepage";
    image = "images:nixos/26.05";
    profiles = [
      "default"
      "container"
      "vpn"
    ];
    running = true;

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
