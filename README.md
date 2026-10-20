# nix-workloads

Smart-home workloads running as incus instances on the `rpi5-8gb` host of
[`nix-homelab-hosts`](https://github.com/esselius/nix-homelab-hosts).

These workloads are the critical smart-home services that used to run on the
`adama` host in [`cfg`](https://github.com/esselius/cfg) - MQTT, Zigbee, Node-RED,
Home Assistant. They now run in incus instances here, so `adama` can be rebuilt,
replaced, or retired without taking lights, heating, or the broker down.

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
flake.nix                    flake-parts + terranix; registers workloads + guest systems + envs
inventory.nix                envs + services: where each workload is addressed and placed
modules/local.nix            shared knobs (domain, realm, CA, ACME, cache, LAN) - see Environments
terraform/common.nix         shared terranix config: incus provider + remote (from the env)
terraform/envs/<env>.nix     selects an env for a terranix config (homelab | dev)
terraform/<name>/default.nix one workload's infrastructure
guests/<name>/default.nix    one workload's NixOS system
secrets/<name>.yaml          sops-encrypted secrets (see Secrets)
.sops.yaml                   age recipients per secret path
```

## Environments

`inventory.nix` is the single source of truth for **where** a workload runs and
**where** it is addressed. An *env* is a logical environment - one DNS zone and
one address space; within an env, *hosts* are incus servers and *placement* maps
a service to a host:

| Env | Incus host | Zone |
|------|-----------|------|
| `homelab` | `rpi5-8gb` (later `rpi5-4gb`) | `int.esselius.dev` |
| `dev` | a local Colima VM | `dev.int.esselius.dev` |

The zone is **flat**: a service has one name (`mosquitto.<zone>`) whichever host
runs it, and clients never learn the host. Moving a workload between hosts is a
change to `placement` (and its A record), never to the workloads. Guests read the
derived `local.*` knobs (`domain`, `realm`, `dnsAddress`, ...) from
`modules/local.nix`, so nothing hard-codes a domain or a `10.43` address. The
Kanidm identity **realm** is separate from `domain`, so a dev Kanidm serves
`idm.dev.int.esselius.dev` but still owns the restored `int.esselius.dev` users.

The flake builds each guest for both envs: `nixosConfigurations.<name>` is the
homelab, `<name>-dev` the local testbed (same modules, `env = "dev"`); terranix
mirrors this (`<name>` and `<name>-dev`). `nix flake check` evaluates all of them.

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

**Internal DNS (`int.esselius.dev`).** Incus's built-in DNS serves the network
zone for `incusbr-vpn`; the zone and its custom records are managed by
`terraform/dns` from `inventory.nix`. Incus only answers AXFR, so a host-level
Unbound resolver in `nix-homelab-hosts` (`modules/dns.nix`) is the actual
authoritative secondary and the VPN client resolver. It listens on the host's
WireGuard address (`10.6.0.3` on `rpi5-8gb`), serves the AXFR zone from a
persistent zonefile, and recurses to public resolvers for everything else.
`cache`/`monitoring` and the `_mqtt._tcp` SRV record are static Unbound records
because the Incus provider supports only A/AAAA/CNAME/TXT custom entries.

The zone is **internal-only** and deliberately **not** delegated from the public
`esselius.dev` zone: a delegation whose authority is a private address cannot be
followed by a public/forwarding resolver (it answers `REFUSED` /
`No Reachable Authority`). The router is untouched (the stock RT-BE50 cannot do
conditional forwarding) and there are no GoDaddy records for the zone.
Consequences: `int.esselius.dev` resolves only while on the VPN. Unbound keeps
serving the last transferred zone if Incus or CoreDNS is unavailable, and internet
resolution does not depend on either.

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
task onboard -- mosquitto          # 2. trust its host key for sops + seed cache trust
task cache-push -- mosquitto       # 3. push its closure to the Attic cache
task deploy -- mosquitto           # 4. deploy (substitutes from the cache)
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

task onboard -- example            # trust host key for sops + seed cache trust
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

## Dev testbed (macOS)

The `dev` env runs the same workloads in a local incus VM, browsable at
`https://<service>.dev.int.esselius.dev` like the homelab. The whole path is
automated (dev guests decrypt the committed secrets with the Mac's age key - see
below):

```fish
task dev-bootstrap        # dev incus bridge + profiles (once)
task dev-access-up        # map *.dev.int.esselius.dev -> the dev VM
task dev-access-status    # mapping + lookup + ingress reachability
task dev-access-down      # remove the mapping
ENV=dev task up     -- <name>   # create on the dev VM
ENV=dev task deploy -- <name>   # deploy over ProxyJump (no host route)
```

**No host route.** Routing the Mac into the dev subnet breaks its default route -
macOS/vmnet (`bridge100`) interacting with the WireGuard tunnel (apple/container
#1881) - so nothing touches the Mac's routing table. Instead everything hops
through the VM, which the Mac already reaches at `colima status --json .ip_address`:

- an `edge` workload (dev-only) is a TLS **SNI passthrough**: it reads the
  ClientHello's server name and forwards the still-encrypted stream to the guest
  that owns it, so guests keep presenting their own step-ca certs (end-to-end
  TLS, no wildcard);
- the `edge` instance carries a `proxy` device publishing it on the VM's own
  address (`0.0.0.0:443`), which the Mac reaches with no route;
- `dev-access-up` maps the dev names to that address in a managed `/etc/hosts`
  block (no DNS daemon; `dev-access-down` removes it);
- `ENV=dev task deploy` copies the closure and activates over SSH **jumped
  through the VM** (`colima ssh-config`), so the guest subnet is never routed
  from the Mac.

**Trust.** The dev step-ca reuses the *production* intermediate
(`certs/intermediate_ca.crt` plus the key/password in `secrets/step-ca.yaml`), so
dev certs chain to the Esselius root the Mac already trusts - no keychain import
and no browser warning. Trade-off: the dev CA is a clone able to mint
production-trusted certificates; it exists only in the local VM.

**Secrets.** Dev guests are not re-keyed: `modules/sops-env.nix` points sops at
`/etc/nix-workloads/dev-age.key`, and `ENV=dev task deploy` pushes the Mac's own
age identity (derived from `~/.ssh/id_ed25519`) there before activating. So the
committed `secrets/*.yaml` decrypt unchanged; the homelab keeps per-guest host
keys. The Mac's key only ever lives in this ephemeral local VM.

These tasks are macOS-only; on other platforms they warn and no-op.

## Deploy (first boot)

`task up` (the terranix apply) seeds root's SSH key automatically: a
`local-exec` provisioner on the instance runs `incus file push --uid 0 --gid 0
--mode 600` (the base image ships no cloud-init, so this is the only
key-injection path; the flags matter, or the push copies the Mac's source
ownership/mode and trips sshd's `StrictModes`).

`task deploy -- example` looks the instance's address up from incus (`incus list
example -c 4 --format csv`), builds the toplevel **locally on the Mac**
(dispatched to its `aarch64-linux` `nix.linux-builder`, a remote in
`/etc/nix/machines`), then hands it to the instance.

Deploy is **substitution-only**: before switching it runs `nix-store --realise
<toplevel>` on the target, so the target must pull the whole closure from its
substituters (the Attic cache, see below). The guest sets `nix.settings.max-jobs
= 0` (the unprivileged guest has no user namespaces, so Nix cannot sandbox a
build inside it anyway), so it can *only* substitute - a cache miss is a hard
error, never a builder -> target copy. Run `task cache-push -- <name>` first.
`nixos-rebuild switch` then switches, with the copy step transferring nothing.

The exception is the bootstrap roots (`attic`, `step-ca`): `attic` is
the cache itself, and the roots are deployed before it exists, so those may fall
back to a copy on a cache miss. Every other workload refuses to.

The stock `images:nixos/26.05` base image trusts no internal CA and does not know
the cache, so `task onboard` also seeds it (a cert plus a few `/etc/nix/nix.conf`
lines) - that is what lets the **first** deploy substitute rather than copy. A
guest deployed *before* the CA fix (its running system cannot verify the cache)
must be re-onboarded once - `task onboard -- <name>` - before a strict deploy.

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
- **Pull on the target, or fail.** `task deploy` makes the target realise the
  closure from the cache *before* switching, so the closure travels cache ->
  target and the Mac's uplink is out of the path. A path the cache cannot serve
  aborts the deploy - it is never copied from the builder. (The bootstrap roots
  `attic`/`step-ca` are the only exception; see Deploy.)
- **Trust.** The cache is HTTPS with a step-ca cert, so every guest trusts the
  internal CA through `modules/nix-cache.nix`, and `task onboard` seeds the same
  trust into the stock base image so the first switch substitutes too. `deploy`
  and `cache-push` build a CA bundle (the orchestrator's trust store plus
  `certs/root_ca.crt`) and pass it to nix, so the orchestrator's own nix also
  substitutes from the cache instead of rebuilding locally.

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
3. `task check -- <name>`, then `task up -- <name>`, `task onboard -- <name>`,
   `task cache-push -- <name>` and `task deploy -- <name>` (deploy substitutes,
   so the push must succeed first).

## Retired: `adama`

The services that used to run on `adama` - Mosquitto, Node-RED,
Prometheus/Grafana, Authentik, nginx/step-ca, PostgreSQL + Home Assistant, and
Zigbee2MQTT - all run here now; `adama` was retired once the USB coordinator
moved across. Operational notes worth keeping:

- **Recorder backend.** Home Assistant's recorder uses a co-located PostgreSQL
  whose data dir is on the `home-assistant-postgres` volume
  (`/var/lib/postgresql`), so a container recreate keeps the history.
- **Zigbee coordinator.** The `zigbee2mqtt` unit is gated on
  `ConditionPathExists=/dev/ttyACM0` so it never restart-loops if the dongle is
  absent. The `unix-hotplug` device (`1a86:55d4`) presents the SONOFF
  ZBDongle-E as `/dev/ttyACM0`, and the workload is pinned to `rpi5-8gb` because
  the dongle is physical. The frontend at `zigbee2mqtt.int.esselius.dev` is
  gated by oauth2-proxy -> Kanidm.
- **Version pin.** The source ran HA 2026.9.x, newer than this repo's
  nixos-26.05 pin; see below.

### Version pin (band-aid)

The cut-over source ran HA 2026.9.x from nixpkgs-unstable, but this repo pins
nixos-26.05 (HA 2026.5.x) - a downgrade a newer `.storage` may not load. So the
`home-assistant` workload overlays **only the HA package** (and its Python
closure) from a pinned unstable revision (`nixpkgs-ha` in `flake.nix`), leaving
everything else on 26.05. The overlay - rather than setting
`services.home-assistant.package` - is what keeps the module's
`buildHomeAssistantComponent` and our `pkgs/*.nix` custom components on the same
HA/python. Drop the input and `homeAssistantOverlay` (`flake.nix`) once NixOS
26.11 ships HA 2026.9+.

## Monitoring (app metrics + dashboards)

Beyond the node + journal streams every guest ships through
`modules/monitoring-agent.nix`, the two smart-home apps expose their own
metrics, which the `monitoring` workload's Grafana picks up:

- **Home Assistant.** `services.home-assistant.config.prometheus` serves
  `/api/prometheus` (auth off - loopback only) with a `hass` namespace, so
  entities are `hass_*` (`hass_entity_available`, `hass_state_change_total`,
  `hass_sensor_temperature_celsius`, `hass_light_brightness_percent`, ...). The
  guest adds `alloy/home-assistant.alloy`, scraping `127.0.0.1:8123` with
  `job="home-assistant"`, through the shared `prometheus.relabel.host` receiver.
- **Zigbee2MQTT.** Its frontend has no Prometheus endpoint, so the guest runs
  `mqtt-exporter` (`zigbee2mqtt` job): it subscribes to the device-state topics
  (`zigbee2mqtt/+`), their `/availability`, and `bridge/state` as the broker's
  `exporter` user, flattens each payload into gauges (`mqtt_temperature`,
  `mqtt_battery`, `mqtt_linkquality`, `mqtt_zigbee_availability`,
  `mqtt_state{topic="zigbee2mqtt_bridge_state"}`, ...) and serves them on
  `127.0.0.1:9000`, scraped by the guest's Alloy. (It deliberately does not
  subscribe to `zigbee2mqtt/#`: the retained `bridge/devices` / `bridge/health`
  payloads are nested per-device objects that would mint a metric name per
  device and exhaust the exporter's cap.) The broker grants `exporter` read on
  `zigbee2mqtt/#`; its password comes from `secrets/mosquitto.yaml` (every guest
  is a recipient).

Dashboards (`guests/monitoring/dashboards/`, folder "Homelab"):
`homeassistant.json` and `zigbee2mqtt.json`. Alerts (`provision.alerting.rules`):
`home-assistant-down`, `zigbee2mqtt-bridge-offline`, `zigbee2mqtt-exporter-down`
- all routed to ntfy like the rest.

## Backups (restic)

The `backup` workload runs a restic REST server (`services.restic.server`, port
8000 on the private backplane) with per-host repositories on the `backup-data`
volume. Guests opt in through the shared `modules/backup.nix`
(`local.backup.paths`): a daily systemd timer pushes an encrypted snapshot to
`rest:http://backup.int.esselius.dev:8000/<hostname>` and prunes to 7 daily /
5 weekly / 6 monthly. The repo password, the REST credentials, and the server's
htpasswd all come from `secrets/backup.yaml`. Home Assistant additionally
`pg_dump`s the recorder into the snapshot through `local.backup.prepareCommand`.

Backed up: `home-assistant` (`/var/lib/hass` plus the pg_dump), `zigbee2mqtt`,
`monitoring` (Grafana state only - the VictoriaMetrics/Loki history is large and
regenerable), `kanidm`, `step-ca`, `node-red` (`/var/lib/node-red` - flows,
credentials, context and the palette; the npm download cache is excluded). A
guest with no `local.backup.paths` is simply not backed up.

```fish
# inspect / restore as any backed-up guest (the module adds a `restic-system` wrapper)
incus exec home-assistant -- restic-system snapshots
incus exec home-assistant -- restic-system restore latest --target /tmp/restore
```

**Monitoring.** Each backed-up guest also runs `prometheus-restic-exporter` (the
`restic-exporter` job) against its own repo; the Alloy agents scrape it into
VictoriaMetrics. The "Backups" Grafana dashboard shows last-backup age, repo
size, snapshot counts and check status, and two alerts - `Backup stale` (>48h)
and `Backup integrity check failed` - route to ntfy like the rest.

Caveat: this is **local only** - the repositories live on `rpi5-8gb`'s pool, so a
board loss loses the backups too. Add an offsite rclone/B2 copy of the
`backup-data` repo when that matters (see Known risks).

### Restore drill

`task restore-test` proves the backups are actually restorable. For each
backed-up guest it runs `restic check --read-data-subset=5%`, restores the
latest snapshot of the env's repo to a scratch dir, and asserts the expected
state came back (HA's `.storage` plus a dump that `pg_restore --list` accepts,
Kanidm/step-ca state, Grafana's `grafana.db`, Node-RED's `flows.json`, and
Zigbee2MQTT's DB/config - the last skipped when the coordinator is absent, e.g.
in `dev`):

```fish
task restore-test                    # homelab (validates the production backups)
ENV=dev task restore-test            # rehearsal against the dev env's own repos
ENV=dev task restore-test -- kanidm  # one guest
```

It runs `restic-system` inside each guest, so it uses that guest's configured
repo and credentials unchanged, and never writes outside `/var/tmp`. A killed
backup can leave a stale restic lock; the drill clears it (`restic unlock`) and
retries.

### Restore a homelab backup into dev

`ENV=dev task dr-restore -- <name>` rehearses a full recovery in the sandbox
before trusting it in production. It `restic copy`s the guest's **homelab** repo
into the dev backup server, restores the latest snapshot on top of the running
dev guest, restarts the workload (Home Assistant also re-imports the recorder
`pg_dump`), and confirms it loads (`systemctl is-active` + the service endpoint).
The Mac brokers the copy (it reaches the homelab backup over WireGuard and the
dev one over the Colima VM's own address - the dev backup server is published
there via an `incus` `proxy` device, since the Mac cannot route into the dev
subnet).

```fish
ENV=dev task dr-restore -- kanidm
ENV=dev task dr-restore -- home-assistant
ENV=dev task dr-restore -- node-red
ENV=dev task dr-restore-all   # every supported guest
```

Supported: `kanidm`, `home-assistant`, `step-ca`, `monitoring`; `zigbee2mqtt` is
data-only and cannot load without the coordinator.

## Landing page (Homepage)

The `homepage` workload runs gethomepage (`services.homepage-dashboard`) as a
link hub for every workload, served at `https://homepage.int.esselius.dev`
behind oauth2-proxy -> Kanidm (a `homepage` OIDC client in the kanidm workload,
same pattern as the Zigbee2MQTT frontend).

## Known risks

- **Zigbee coordinator**: the dongle is physical, so the instance must run on
  whichever board it is plugged into (`rpi5-8gb`) and never migrates with the
  instance. It can be a **container**: incus passes the host's `cdc_acm` node
  with a `unix-char` device (`source=/dev/serial/by-id/<id>`,
  `path=/dev/ttyACM0`), or follows replugs with a `unix-hotplug` device
  (`vendorid`/`productid`). Both are container-only device types - a VM would
  need the whole `usb` device instead. The workload is therefore pinned to
  `rpi5-8gb` and cannot migrate to the other board.
- **No cluster**: `rpi5-8gb` and `rpi5-4gb` are standalone incus servers. There
  is no failover; `rpi5-8gb` is a single point of failure. The migration removed
  the *host-rebuild* coupling, not the hardware SPOF.
- **Secrets**: broker passwords, the Zigbee2MQTT network key, and Postgres
  credentials must go through sops/age (as in `nix-homelab-hosts`), never as
  literals in these configs.
- **State**: incus storage lives on the host's persistent pool, and the
  `backup` workload snapshots the critical state to restic (see Backups), but
  those repos are on the same board - a full loss of `rpi5-8gb` loses the
  primary state *and* its local backups. An offsite copy is still outstanding.
