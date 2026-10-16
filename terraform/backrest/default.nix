{ lib, config, ... }:
let
  # Backrest: a web UI for the restic repositories. Pinned on the vpn bridge;
  # reached as `backrest.int.esselius.dev` (an A record in the coredns zone),
  # gated by oauth2-proxy -> Kanidm like the other web UIs.
  staticIp = "10.43.0.22";
in
{
  # Backrest's config (admin account + repo definitions) and its operation log
  # live here, so they survive a container recreate.
  resource.incus_storage_volume.backrest_data = {
    name = "backrest-data";
    pool = config.local.storagePool;
    content_type = "filesystem";

    lifecycle.prevent_destroy = true;
  };

  resource.incus_instance.backrest = {
    name = "backrest";
    image = "images:nixos/26.05";
    profiles = [
      "default"
      "container"
      "vpn"
    ];
    running = true;

    depends_on = [ "incus_storage_volume.backrest_data" ];

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
        name = "data";
        type = "disk";
        properties = {
          pool = config.local.storagePool;
          source = "backrest-data";
          path = "/var/lib/backrest";
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
