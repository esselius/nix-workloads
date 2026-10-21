# AI Maintenance Notes

Scope: **workloads** running as incus instances on the `nix-homelab-hosts`
cluster (`rpi5-8gb` and `rpi5-4gb`; `inventory.nix` placement decides which
host runs each workload). This repo does not configure the
incus daemon or the Pi hosts - that lives in
`github.com/esselius/nix-homelab-hosts`. Here we only declare the instances
(terranix -> OpenTofu) and the NixOS systems that run inside them.

These workloads are the critical smart-home services (lights, heating, MQTT)
that formerly ran on the `adama` host of `github.com/esselius/cfg`, now incus
instances here. `adama` has been retired; this repo is their source of truth, so
a rebuild or replacement of `rpi5-8gb` must not take lights, heating, or MQTT
down.

- Three layers, keep them separate:
  1. **Base image** - the upstream `images:nixos/26.05` incus image.
  2. **Infrastructure** - `terraform/<name>/default.nix`, compiled by terranix
     into `config.tf.json` and applied with OpenTofu. Owns instance existence,
     profiles, resource limits, devices.
  3. **OS** - `guests/<name>/default.nix`, a `nixosConfigurations.<name>` system
     deployed into the running instance with `nixos-rebuild`.
- **Environments + inventory.** `inventory.nix` is the single source of truth for
  *where* each workload runs and is addressed: an *env* is one DNS zone + address
  space (`homelab` = the Pi pair, `dev` = a local incus VM), hosts are incus
  servers, and `placement` maps a service to a host. The zone is **flat** - a
  service has one name (`mosquitto.<zone>`) whichever host runs it - so moving a
  workload is a `placement` change, never a workload change. Never hard-code a
  domain or a `10.43` address in a guest or a `terraform/<name>`: read
  `config.local.*` (`domain`, `realm`, `dnsAddress`, ...) from
  `modules/local.nix` / the env's host, and add new services to
  `inventory.nix`. The flake builds each guest for
  both envs (`<name>` and `<name>-dev`; same for terranix). Resolve a workload's
  incus remote through `inventory.hostFor` (`scripts/remote-for.sh`), never
  through the env's `defaultHost`.
- **DNS is infrastructure, not a guest.** `terraform/dns` owns the Incus network
  zone from `inventory.nix`; it has no `nixosConfiguration`. Apply it with
  `ENV=<env> task up -- dns`; `deploy-all`/`provision-all` do this before the
  guest loop. `checks.dns-zone` fails evaluation on duplicate canonical/alias
  names, and `task check -- dns` evaluates the terranix config.
- **Dev testbed is macOS-only, route-free, and reuses the production CA.**
  Never route the Mac into the dev subnet: macOS/vmnet `bridge100` plus the
  WireGuard tunnel breaks the host's default route (apple/container #1881). The
  `dev` `edge` workload SNI-passes TLS through to the guests and is published on
  the VM's own address via a `proxy` device; `task dev-access-up/-down/-status`
  (Darwin-only) map `*.dev.int.esselius.dev` to that address in a managed
  `/etc/hosts` block; `ENV=dev task deploy` jumps SSH through the VM. The dev
  step-ca reuses the *production* intermediate (`certs/intermediate_ca.crt` +
  `secrets/step-ca.yaml`), so dev certs chain to the already-trusted Esselius
  root; the trade-off is a local CA clone that can mint production-trusted certs.
- Prefer small, explicit modules over abstractions. `terraform/common.nix` holds
  the only shared terranix config (the incus provider + remote); every workload
  is a sibling directory under `terraform/`.
- Guest systems import `${modulesPath}/virtualisation/lxc-container.nix` - the
  same module the upstream NixOS incus image uses - so `nixos-rebuild switch`
  keeps the container-specific boot/network wiring intact.
- Run `nix fmt` and `nix flake check` before committing. Both are wired into the
  flake (`formatter`, `checks.eval-all`, `checks.fmt`, `checks.dns-zone`).
  `nix flake check` evaluates the `dns`/`dns-dev` terranix configs too; it does
  not apply them.
- Keep the Grafana dashboards in `guests/monitoring/dashboards/` per-host
  filterable - the fleet spans two incus servers. Each dashboard that reads
  host-labelled metrics defines a `host` query variable sourced from the metric's
  own host label (`up{node_type="host"}` for host-level metrics, the exporter's
  metric for app dashboards) with `includeAll` + `allValue: ".*"`, and applies it
  as `host=~"$host"` in every query; legends include `{{host}}`. Add dependent
  variables (`instance`, `type`, `device`, ...) the same way rather than
  hard-coding a host.
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
- `modules/minimal.nix` (imported by every guest) trims the parts of a stock
  NixOS system that only exist to build/install NixOS locally or to prettify an
  interactive shell: the flake registry pin + NIX_PATH (keeps the ~197 MiB
  nixpkgs source out of the closure), the bundled installer channel (another
  ~197 MiB copy of nixpkgs), `system.disableInstallerTools` (drops
  nixos-rebuild-ng and its Python), the `documentation.*` trees, and the
  `environment.defaultPackages` convenience set. Worth ~0.2-0.4 GiB per guest
  (fleet total ~3 GiB), which the Attic + Cachix caches hold. If a guest ever
  genuinely needs one of these, override it in that guest, not by reverting this
  module. The still-largest shared item is `grafana-alloy` (~360 MiB, the
  monitoring agent); shrinking it means replacing Alloy with node-exporter +
  a log shipper, a separate decision.
- Builds run on the Mac's `aarch64-linux` `nix.linux-builder`, and results reach
  the fleet through two caches: the `attic` workload
  (`cache.int.esselius.dev`) and the external `esselius` Cachix fallback.
  `task cache-push -- <name>` pushes only that workload's system closure (never
  everything the builder compiles) to both; if one is unavailable the other
  still counts as success. `task deploy` is substitution-only after the first
  boot: it runs `nix-store --realise` on the target before switching, so a path
  neither cache can serve fails the deploy instead of being copied from the
  builder. The first deploy (`COPY=1`) and `attic`/`step-ca` may copy because
  they bootstrap the cache. See README "Build cache (Attic + Cachix)".
- The USB Zigbee coordinator is physical, so a Zigbee2MQTT workload is pinned to
  the board the dongle is plugged into (never migrates with the instance). It can
  be a container: pass the host's `cdc_acm` node with a `unix-char` device
  (`source=/dev/serial/by-id/<id>`, `path=/dev/ttyACM0`) or follow replugs with
  `unix-hotplug` (both are container-only device types; a VM needs `usb`). See
  README "Known risks".
