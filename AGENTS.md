# AI Maintenance Notes

Scope: **workloads** running as incus instances on the `nix-homelab-hosts`
cluster (`rpi5-8gb` today, `rpi5-4gb` later). This repo does not configure the
incus daemon or the Pi hosts - that lives in
`github.com/esselius/nix-homelab-hosts`. Here we only declare the instances
(terranix -> OpenTofu) and the NixOS systems that run inside them.

Goal: offload the critical smart-home services currently running on the `adama`
host of `github.com/esselius/cfg` into incus instances, so `adama` can be
rebuilt/replaced without taking lights, heating, or MQTT down.

- Three layers, keep them separate:
  1. **Base image** - the upstream `images:nixos/26.05` incus image.
  2. **Infrastructure** - `terraform/<name>/default.nix`, compiled by terranix
     into `config.tf.json` and applied with OpenTofu. Owns instance existence,
     profiles, resource limits, devices.
  3. **OS** - `guests/<name>/default.nix`, a `nixosConfigurations.<name>` system
     deployed into the running instance with `nixos-rebuild`.
- Prefer small, explicit modules over abstractions. `terraform/common.nix` holds
  the only shared terranix config (the incus provider + remote); every workload
  is a sibling directory under `terraform/`.
- Guest systems import `${modulesPath}/virtualisation/lxc-container.nix` - the
  same module the upstream NixOS incus image uses - so `nixos-rebuild switch`
  keeps the container-specific boot/network wiring intact.
- Run `nix fmt` and `nix flake check` before committing. Both are wired into the
  flake (`formatter`, `checks.eval-all`, `checks.fmt`).
- Never commit plaintext secrets. Smart-home services need broker passwords, the
  Zigbee2MQTT network key, and Postgres credentials; wire those through sops/age
  the same way `nix-homelab-hosts` does, not as literals.
- USB Zigbee coordinator passthrough cannot follow an instance across hosts; a
  Zigbee2MQTT workload must be a VM pinned to the board the dongle is plugged
  into (see README "Known risks").
