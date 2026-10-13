# nix-workloads

Smart-home workloads running as incus instances on the `rpi5-8gb` host of
[`nix-homelab-hosts`](https://github.com/esselius/nix-homelab-hosts).

The goal is to move the critical smart-home services off the `adama` host in
[`cfg`](https://github.com/esselius/cfg) - MQTT, Zigbee, Node-RED, Home
Assistant - so `adama` can be rebuilt or replaced without taking lights,
heating, or the broker down.

## Three layers

| Layer | Where | Tool | Owns |
|-------|-------|------|------|
| 1. Base image | `images:nixos/26.05` | incus image server | the throwaway bootstrap OS |
| 2. Infrastructure | `terraform/<name>/default.nix` | terranix -> OpenTofu | instance existence, profiles, limits, devices |
| 3. OS | `guests/<name>/default.nix` | `nixos-rebuild` | packages, services, generations |

Layer 2 never touches what runs *inside* the instance; layer 3 never touches
instance existence. That split is what lets a workload be upgraded in place
(unlike golden images, which can only be replaced).

## Layout

```
flake.nix                    flake-parts + terranix; registers workloads + guest systems
terraform/common.nix         the only shared terranix config: incus provider + remote
terraform/<name>/default.nix one workload's infrastructure
guests/<name>/default.nix    one workload's NixOS system
secrets/<name>.yaml          sops-encrypted secrets (see Secrets)
.sops.yaml                   age recipients per secret path
```

`terraform/common.nix` points the `lxc/incus` provider at the `rpi5-8gb` remote
(`https://rpi5-8gb.x.esselius.dev:8443`) and reuses the Mac's client certificate
from `~/.config/incus`. Add `rpi5-4gb` there when the second board is wanted.

## Networking

Instances attach to the host's WireGuard-reachable bridge via the `vpn` profile
(`incusbr-vpn`, `10.43.0.0/24`, no NAT), so they get a real `10.43.0.x` address
instead of a NAT'd `10.42.0.x` one. The host joins the router's WireGuard server
as a split-tunnel node (`10.6.0.3`), the router routes `10.43.0.0/24` to it, and
the host forwards `wg0 <-> incusbr-vpn` - so a VPN-connected Mac reaches an
instance directly by its `10.43.0.x` address.

- On the VPN: target instances by their own address.
- Off the VPN: reach them through the host with ProxyJump (the host sits on the
  bridge at `10.43.0.1`).

Each workload pins a **static** `10.43.0.x` (the instance-level `eth0` device in
`terraform/<name>/default.nix`), so clients have a stable target and a cross-host
move keeps the same IP (same-subnet bridge). No DNS or discovery service is
involved. The bridge name is shared via the `local.vpnBridge` option in
`terraform/common.nix`.

Don't mix networks: `vpn` overrides `default`'s `eth0`, so an instance is on
`incusbr-vpn` *or* `incusbr0`, never both. Keep interdependent services on the
same bridge.

**LAN clients.** WiFi/LAN devices that cannot do WireGuard (the `p1ib` power
meter, ESP devices, phones) reach a workload through an optional **second NIC**:
`eth1`, a macvlan on the host's wired uplink (`local.lanParent`, `end0`), with a
static LAN address outside the router's DHCP pool (`192.168.50.2-100`). The
instance then has two NICs - `eth0` on `incusbr-vpn` (private backplane) and
`eth1` on the LAN - and the guest firewall keeps them separate:

- SSH is **only** on `eth0`. Set `services.openssh.openFirewall = false` (else
  the sshd module adds a *global* port-22 allow) and open 22 per-interface.
- The service port (e.g. 1883) is the only thing open on `eth1`.
- `task deploy` always targets the `eth0` address (`incus config device get
  <name> eth0 ipv4.address`), never the LAN NIC.

Caveats: the host cannot reach a macvlan address (use `eth0`), and the guest
must not install a second default route - give `eth1` no gateway so only the
connected LAN route is added.

**Internal DNS (`int.esselius.dev`).** A `coredns` workload (`10.43.0.14`) is
authoritative for `int.esselius.dev` - a zone generated in
`guests/coredns/default.nix` that gives every workload an `A` record and
non-HTTP services an `SRV` record (`_mqtt._tcp`, ...). It binds `:53` with
`systemd-resolved` disabled in the guest (its stub would otherwise occupy the
port).

The zone is **internal-only** and deliberately **not** delegated from the public
`esselius.dev` zone: a delegation whose authority is a private address cannot be
followed by a public/forwarding resolver (it answers `REFUSED` /
`No Reachable Authority`). Instead the hosts use **split DNS** - a
systemd-resolved routing domain `~int.esselius.dev` -> `10.43.0.14`, registered
on the `incusbr-vpn` bridge link via `local.incus.network.vpn.dns`/`dnsDomains`
in `nix-homelab-hosts`. Only that suffix goes to `coredns`; every other lookup
stays direct. The router is untouched (the stock RT-BE50 cannot do conditional
forwarding) and there are no GoDaddy records for the zone. Consequences:
`int.esselius.dev` resolves only while on the VPN.

**Credentials shim.** LXC's distrobuilder generator writes
`service.d/zzz-lxc-service.conf`, clearing `LoadCredential=`/`ImportCredential=`
for **non-nested** containers - an AppArmor-era shim (upstream assumes the
credential/sandbox mounts are denied without nesting). This host runs no AppArmor
and the mount works, so `modules/lxc-credentials.nix` provides an opt-in option,
`local.lxc.allowSystemdCredentials` (default off), that patches the generator to
drop just the `LoadCredential` line (keeping its other fixes). Enable it per
guest that needs systemd credentials (e.g. `services.mosquitto`'s
`passwordFile`) so they work **without** `security.nesting`. It ideally belongs
upstream (nixpkgs #260670, distrobuilder #985).

## Mosquitto (first real workload)

The broker is the dependency root for the smart-home stack. It runs on both
NICs: `10.43.0.11` (internal instances + VPN admin) and `192.168.50.150` (WiFi/
LAN devices like `p1ib`). Users (`z2m`, `hass`, `nr`, `p1ib`) and their
passwords come from `secrets/mosquitto.yaml`.

Passwords are handed to the broker through the module's native systemd
credentials (`passwordFile` → `LoadCredential`), so nothing lands in the Nix
store. The guest overlays the distrobuilder generator so those credentials
survive without `security.nesting` (see Networking).

## Secrets

Secrets live in `secrets/*.yaml`, sops-encrypted to the age recipients in
`.sops.yaml` (the Mac's SSH key for editing; each guest's SSH host key for
runtime). The devshell exports `SOPS_AGE_KEY_CMD` so sops derives an age
identity from `~/.ssh/id_ed25519` (sops does not read that key directly):

```fish
nix develop
sops secrets/mosquitto.yaml      # edit in place
```

A guest decrypts with its **own SSH host key**, which only exists after first
boot - so onboarding a guest is two-phase:

```fish
task up -- mosquitto               # 1. create the instance (layer 2)
task onboard -- mosquitto          # 2. trust its host key for sops + rekey
task deploy -- mosquitto           # 3. deploy (sops-nix can now decrypt)
```

`task onboard` reads the guest's host key over the network (`ssh-keyscan -t
ed25519 <ip> | ssh-to-age`; the base image's sshd is already up), appends it to
`.sops.yaml`, and runs `sops updatekeys secrets/<name>.yaml`.

Until step 2, `task deploy` fails: sops-nix on the guest cannot decrypt a file
the guest is not a recipient of. Never commit plaintext secrets.

## Prerequisites

1. **DNS**: `rpi5-8gb.x.esselius.dev` resolves to the host (the cert's SAN).
2. **Trust the Mac's client cert** on the host. The host only trusts the
   browser UI cert today, so the OpenTofu client would be rejected. Copy it into
   the host repo and redeploy:

   ```fish
   cp ~/.config/incus/client.crt \
     ../nix-homelab-hosts/certs/incus-client-mac.crt
   ```

   Then in `nix-homelab-hosts/hosts/rpi5-8gb.nix`:

   ```nix
   local.incus.tls.clientCertificates."incus-client-mac" =
     ./../certs/incus-client-mac.crt;
   ```

   and `nixos-rebuild switch` the host. (A one-time join token via the
   provider's `token` field also works, but is not repeatable.)
3. **An `aarch64-linux` builder on the Mac** - `task deploy` builds the guest
   system locally and copies it to the instance. This repo assumes the nix-darwin
   `nix.linux-builder` (a remote in `/etc/nix/machines`), so no host is used as a
   build host.

## Usage

```fish
nix develop

task plan   -- example             # plan the instance
task up     -- example             # create/update it (tf apply)
task down   -- example             # destroy it

task onboard -- example            # trust the guest's host key for sops + rekey
task cache-push -- example         # push the guest's closure to the Attic cache
task deploy -- example             # nixos-rebuild the guest onto it (see Deploy)
task deploy-all                    # deploy every workload in dependency order
task provision-all                 # up -> onboard -> cache-push -> deploy, all workloads
task fmt                           # nix fmt
task check                         # nix flake check (every workload)
task check -- mosquitto            # evaluate one workload only (fast inner loop)
```

`task <task> -- <args>` forwards args to the wrapped command. `up`/`down`/`plan`
wrap `tf <name> <action>` (which builds `terraform/<name>/default.nix` into
`config.tf.json` and runs OpenTofu there); `deploy` wraps `nixos-rebuild`. The
raw terranix apps (`nix run .#example`, `.#example.destroy`) still work too.

## Deploy (first boot)

`task up` (the terranix apply) seeds root's SSH key automatically: a
`local-exec` provisioner on the instance runs `incus file push --uid 0 --gid 0
--mode 600` (the base image ships no cloud-init, so this is the only
key-injection path; the flags matter, or the push copies the Mac's source
ownership/mode and trips sshd's `StrictModes`).

`task deploy -- example` looks the instance's address up from incus (`incus list
example -c 4 --format csv`) and runs `nixos-rebuild switch --flake .#example
--target-host root@<ip> --use-substitutes`, with `NIX_SSHOPTS` set to accept the
guest's host key. The system is built **locally on the Mac**, dispatched to its
`aarch64-linux` `nix.linux-builder` (a remote in `/etc/nix/machines`), and handed
to the instance: `--use-substitutes` lets the guest pull the closure from its
substituters (the Attic cache, see below) instead of receiving it over SSH. The
guest itself never builds (the unprivileged guest has no user namespaces, so Nix
cannot sandbox a build inside it anyway); it sets `nix.settings.max-jobs = 0`, so
a build attempted inside a container fails outright (`local builds are disabled
(max-jobs = 0)`).

Off the VPN, add a ProxyJump for the guest. Do it in `~/.ssh/config` rather than
in `NIX_SSHOPTS`:

```
Host 10.43.0.*
  User root
  ProxyJump admin@rpi5-8gb
```

The provisioner runs only on create; after the first switch the key is declared
in `guests/example/default.nix`, so later rebuilds only need
`task deploy -- <name>`.

## Build cache (Attic)

The one place a build result can live so it is not rebuilt everywhere: the
`attic` workload (`cache.int.esselius.dev`), a self-hosted Attic binary cache on
a persistent volume. The Mac's `nix.linux-builder` is the only builder; the cache
is how its results reach the hosts and guests.

```
builder ──build──▶ task cache-push ──▶ cache ──substitute──▶ target
   Mac ── orchestrates ──┘
```

- **Push only what you deploy.** `task cache-push -- <name>` pushes that
  workload's *system closure* (`attic push` walks references and skips paths
  already on `cache.nixos.org`). The builder's intermediates stay on the builder,
  so the cache holds distribution artifacts - not everything ever compiled.
- **Pull on the target.** `task deploy` passes `--use-substitutes`, so the target
  substitutes the closure from the cache instead of receiving it over SSH; the
  Mac's uplink is out of the path.

### One-time bootstrap

Attic's cache signing key is generated when the cache is *created*, so the
clients' `trusted-public-keys` can only be filled in afterwards:

1. `task up -- attic`, `task onboard -- attic` (adds the guest's host key to
   `.sops.yaml` and rekeys `secrets/attic.yaml`), then `task deploy -- attic`.
2. Mint an access token on the server. `atticd-atticadm` is the module's
   `atticadm` wrapper (run it in the guest); `--create-cache` is what lets the
   token create `homelab`, `--pull`/`--push` grant access to it:
   ```fish
   incus exec attic -- atticd-atticadm make-token \
     --sub peter --validity '10 years' \
     --pull homelab --push homelab --create-cache homelab
   ```
3. Register the server on the Mac, create the cache, and read its public key:
   ```fish
   nix develop
   attic login homelab https://cache.int.esselius.dev/ <token-from-step-2>
   attic cache create homelab
   attic cache info homelab    # -> Public Key: homelab:<base64>
   ```
   A token is a secret: don't paste it into the repo - it lives in the Mac's
   `~/.config/attic/config.toml`.
4. Paste that key into the three `cachePublicKey` slots - the workloads
   `modules/nix-cache.nix`, the hosts `modules/nix-cache.nix`, and the Mac's
   `determinateNix` settings in nix-config. Until then the substituter is listed
   but untrusted, so nix simply falls back to copying.

> If step 2 fails with a permission error on `/var/lib/atticd`, the module's
> `atticd-atticadm` wrapper runs with `DynamicUser=yes` (a different uid than the
> fixed `atticd` user owning the DB). See "DynamicUser and the volume" below.

### DynamicUser and the volume

`services.atticd` runs atticd as a `DynamicUser` with `StateDirectory = "atticd"`,
and systemd relocates a dynamic user's state dir to `/var/lib/private/atticd`.
That collides with the persistent volume mounted at `/var/lib/atticd`:

```
Failed to set up special execution directory in /var/lib: Device or resource busy
status=238/STATE_DIRECTORY
```

The guest therefore runs atticd as a fixed user (`DynamicUser = false` +
`users.users.atticd`) so the state dir stays at `/var/lib/atticd`, on the volume.
Trade-off: the module's `atticd-atticadm` wrapper still launches its transient
unit with `DynamicUser=yes`, i.e. a different uid than the one owning
`/var/lib/atticd/server.db` (`UMask 0077`) - minting a token can hit a permission
error. If it does, switch approaches: keep the module's `DynamicUser` and mount
the volume at `/var/lib/private/atticd` (pointing `database.url` and
`storage.path` there), so the wrapper and the daemon share one uid.

### Sizing + GC

Fleet system closures total ~19 GiB unpacked (host 3.7 GiB; guests 1.4-3.0 GiB
each); chunked, zstd-compressed and deduplicated across the shared base, the
cache holds ~10-15 GiB, so a 32 GiB volume is comfortable (`attic-data`, on the
host's `/persist`). GC runs every 12h and drops objects neither created nor
accessed within six months (`garbage-collection.default-retention-period`) -
without a retention period the cache grows unbounded. Frequently-substituted
paths stay hot.

## Adding a workload

1. `cp -r terraform/example terraform/<name>`, rename the resource, and set a
   unique `staticIp` (`10.43.0.x`).
2. `cp -r guests/example guests/<name>`, set `networking.hostName`, and, if the
   guest needs a deviation from the common shape (no sops, extra `specialArgs`),
   add it to `guestMeta` in `flake.nix`. Otherwise nothing to register: both
   `nixosConfigurations` and `terranixConfigurations` are derived from the
   `guests/` directory.
3. `task check -- <name>`, then `task up -- <name>` and
   `task deploy -- <name>`.

## Migration plan (from `adama`)

Ordered by the critical path (lights/heating/MQTT first):

| `adama` service | Type | Notes |
|-----------------|------|-------|
| Mosquitto (MQTT) | container | broker everything else depends on |
| Node-RED | container | automation flows |
| PostgreSQL | container | Home Assistant recorder backend |
| Home Assistant | container | recorder -> a co-located PostgreSQL |
| Zigbee2MQTT | container | needs the USB coordinator; see Known risks |
| Prometheus / Grafana | container | monitoring, not critical path |
| Authentik / nginx / step-ca | container | web auth + TLS front door |

## Pending cutover: Zigbee2MQTT

The `zigbee2mqtt` workload is scaffolded and deployed, but its unit is
**disabled** (`wantedBy = [ ]`) and gated on `ConditionPathExists=/dev/ttyACM0`
until the USB coordinator is physically moved from `adama` to `rpi5-8gb`.
Remaining steps:

1. Move the SONOFF ZBDongle-E from `adama` to `rpi5-8gb`; the `unix-hotplug`
   device (`1a86:55d4`) surfaces it as `/dev/ttyACM0`.
2. `systemctl start zigbee2mqtt` to start it (it's disabled at boot for now -
   remove the `wantedBy` override in `guests/zigbee2mqtt` to re-enable).
3. Copy z2m state from `adama` (`/var/lib/zigbee2mqtt`: `database.db` + the
   coordinator backup) into the `zigbee2mqtt-data` volume so device names and
   pairings survive (the network key is already in sops).
4. Verify devices report on `zigbee2mqtt.int.esselius.dev`, then stop `adama`'s
   zigbee2mqtt and remove its vhost, DNS entry and secret.

Note: the Kanidm `oauth2-proxy` client now points at
`zigbee2mqtt.int.esselius.dev`, so `adama`'s z2m *frontend login* is broken
until the cutover - the daemon keeps running and automations are unaffected.

## Pending cutover: Home Assistant

The `home-assistant` workload is scaffolded and deployed but **disabled** (the
module's target is dropped from `multi-user.target`), so it can't clash with
`adama`'s HA. Remaining steps:

1. Copy `adama`'s HA config dir (`/var/lib/hass`: `configuration.yaml`,
   `.storage`, `custom_components`, ...) into the `home-assistant-data` volume.
2. Re-enable HA (remove the `systemd.targets.home-assistant.wantedBy` override
   in `guests/home-assistant`) and redeploy /
   `systemctl start home-assistant.target`.
3. Verify the UI at `home-assistant.int.esselius.dev` and that the recorder
   writes to the local PostgreSQL, then stop `adama`'s HA and remove its vhost
   and DNS entry.

Notes:

- The recorder DB starts empty; importing `adama`'s Postgres history is optional
  (`pg_dump`/`pg_restore` into the guest).
- This repo pins nixpkgs 26.05 (Home Assistant 2026.5.x), whereas `cfg` ran HA
  from nixpkgs-unstable (2026.9.x) - check the config after cutover.

## Known risks

- **Zigbee coordinator**: the dongle is physical, so the instance must run on
  whichever board it is plugged into (`rpi5-8gb`) and never migrates with the
  instance. It can be a **container**: incus passes the host's `cdc_acm` node
  with a `unix-char` device (`source=/dev/serial/by-id/<id>`,
  `path=/dev/ttyACM0`), or follows replugs with a `unix-hotplug` device
  (`vendorid`/`productid`). Both are container-only device types - a VM would
  need the whole `usb` device instead. Until the dongle moves, Zigbee2MQTT stays
  on `adama`.
- **No cluster**: `rpi5-8gb` and `rpi5-4gb` are standalone incus servers. There
  is no failover; `rpi5-8gb` is a single point of failure exactly like `adama`
  was. This migration removes the *host-rebuild* coupling, not the hardware SPOF.
- **Secrets**: broker passwords, the Zigbee2MQTT network key, and Postgres
  credentials must go through sops/age (as in `nix-homelab-hosts`), never as
  literals in these configs.
- **State**: incus storage lives on the host's persistent pool, but Home
  Assistant/Postgres/Zigbee2MQTT state still needs its own backup path; a
  rebuild of `rpi5-8gb` does not preserve it.
