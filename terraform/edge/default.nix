{ lib, config, ... }:
let
  # Dev-only TLS SNI ingress (see guests/edge). Its `proxy` device publishes the
  # ingress on the incus host's own addresses - the Colima VM's vmnet IP - so
  # the Mac reaches it with no route into the 10.x dev subnet.
  staticIp = (import ../../inventory.nix).ipFor config.local.env "edge";
in
{
  resource.incus_instance.edge = {
    name = "edge";
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
      {
        # host:443 -> ingress:443. `listen` on 0.0.0.0 includes the VM's col0
        # address that the Mac already has a connected route to.
        name = "https";
        type = "proxy";
        properties = {
          "listen" = "tcp:0.0.0.0:443";
          "connect" = "tcp:${staticIp}:443";
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
