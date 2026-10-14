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
- **Shared knobs.** `modules/local.nix` holds the shared, overridable knobs
  (domain, CA, ACME, cache, LAN) with Pi defaults. Guests must read
  `config.local.*`, never hard-code `int.esselius.dev` / the Esselius CA / the
  Attic URL, so a different environment (e.g. a local incus VM on the Mac) is a
  matter of setting those options rather than forking the configs.
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
- `modules/lxc-credentials.nix` provides the opt-in option
  `local.lxc.allowSystemdCredentials` (default off), which overlays
  `pkgs.distrobuilder.generator` to stop it clearing `LoadCredential=` for
  non-nested containers. Enable it per guest that needs systemd credentials. The
  clearing is an AppArmor-era shim (upstream assumes the credential/sandbox
  mounts fail without nesting); this host runs no AppArmor, so credentials work
  fine here. Note it re-enables `LoadCredential` for *every* service that
  declares it (journald, networkd, resolved, ... - not just mosquitto).
  Caveat: upstream tried exactly this and reverted it (distrobuilder PR #1003,
  2026-06, "broke most of our images" - on AppArmor hosts). Our narrower version
  (drop `LoadCredential=` only, leave `ImportCredential=` cleared) is verified
  healthy here (0 failed units). Keep it minimal; ideally it belongs upstream
  (nixpkgs #260670, distrobuilder #985).
- Container guests set `nix.settings.max-jobs = 0`: they never build, only
  substitute; an in-guest build fails with `local builds are disabled (max-jobs
  = 0)`.
- Builds run on the Mac's `aarch64-linux` `nix.linux-builder`, and results reach
  the fleet through one shared cache: the `attic` workload
  (`cache.int.esselius.dev`). `task cache-push -- <name>` pushes only that
  workload's system closure (never everything the builder compiles), and
  `task deploy` is substitution-only: it runs `nix-store --realise` on the
  target before switching, so a path the cache cannot serve fails the deploy
  instead of being copied from the builder (`attic`/`step-ca`/`coredns` may
  still copy - they bootstrap the cache). See README "Build cache (Attic)".
- The USB Zigbee coordinator is physical, so a Zigbee2MQTT workload is pinned to
  the board the dongle is plugged into (never migrates with the instance). It can
  be a container: pass the host's `cdc_acm` node with a `unix-char` device
  (`source=/dev/serial/by-id/<id>`, `path=/dev/ttyACM0`) or follow replugs with
  `unix-hotplug` (both are container-only device types; a VM needs `usb`). See
  README "Known risks".
