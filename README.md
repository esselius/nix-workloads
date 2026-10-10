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

Don't mix networks: `vpn` overrides `default`'s `eth0`, so an instance is on
`incusbr-vpn` *or* `incusbr0`, never both. Keep interdependent services on the
same bridge.

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
3. **A remote builder for `aarch64-linux`** if deploying from the Mac without
   `--build-host` (Determinate Nix's Linux builder).

## Usage

```fish
nix develop            # opentofu, terranix, incus client, tf wrapper

# Layer 2 - create/update the instance:
tf example plan
tf example apply       # or: nix run .#example
tf example destroy     # or: nix run .#example.destroy

# Layer 3 - deploy the OS (see "Deploy" below):
nixos-rebuild switch --flake .#example --target-host root@<instance-ip>
```

`tf <name> <action>` builds `terraform/<name>/default.nix` into
`config.tf.json` and runs OpenTofu in `terraform/<name>/`.

## Deploy (first boot)

`tf apply` seeds root's SSH key automatically: a `local-exec` provisioner on the
instance runs `incus file push --uid 0 --gid 0 --mode 600` (the base image ships
no cloud-init, so this is the only key-injection path; the flags matter, or the
push copies the Mac's source ownership/mode and trips sshd's `StrictModes`).

The instance is on the WireGuard-reachable bridge (`10.43.0.x`). Build on the
host with `--build-host admin@rpi5-8gb`: the unprivileged guest has no user
namespaces, so Nix cannot sandbox a build inside it, and the Mac's
`aarch64-linux` builder isn't used for this. Then:

```fish
set ip (incus list example -c 4 --format csv)   # the 10.43.0.x address
set -x NIX_SSHOPTS "-o StrictHostKeyChecking=accept-new"

# on the VPN:
nixos-rebuild switch --flake .#example \
  --target-host root@$ip --build-host admin@rpi5-8gb

# off the VPN, also jump through the host to reach the guest:
set -x NIX_SSHOPTS "-o StrictHostKeyChecking=accept-new -o ProxyJump=admin@rpi5-8gb"
nixos-rebuild switch --flake .#example \
  --target-host root@$ip --build-host admin@rpi5-8gb
```

The provisioner runs only on create; after the first switch the key is declared
in `guests/example/default.nix`, so later rebuilds only need the last command.

## Adding a workload

1. `cp -r terraform/example terraform/<name>` and rename the resource.
2. Register it in `flake.nix` under `terranix.terranixConfigurations` (and add
   it to the `workloads` list used by the `tf` wrapper).
3. `cp -r guests/example guests/<name>`, set `networking.hostName`, and add the
   system to `flake.nixosConfigurations`.
4. `nix flake check`, then `tf <name> apply` and deploy as above.

## Migration plan (from `adama`)

Ordered by the critical path (lights/heating/MQTT first):

| `adama` service | Type | Notes |
|-----------------|------|-------|
| Mosquitto (MQTT) | container | broker everything else depends on |
| Node-RED | container | automation flows |
| PostgreSQL | container | Home Assistant recorder backend |
| Home Assistant | VM | isolation; recorder -> Postgres |
| Zigbee2MQTT | **VM** | needs the USB coordinator; see Known risks |
| Prometheus / Grafana | container | monitoring, not critical path |
| Authentik / nginx / step-ca | container | web auth + TLS front door |

## Known risks

- **Zigbee coordinator**: USB passthrough is per-host and never migrates with
  an instance, so Zigbee2MQTT must run on the board the dongle is plugged into
  (`rpi5-8gb`) and be a VM with a `unix-char` device for
  `/dev/serial/by-id/<id>`. Until that device is attached, Zigbee2MQTT stays on
  `adama`.
- **No cluster**: `rpi5-8gb` and `rpi5-4gb` are standalone incus servers. There
  is no failover; `rpi5-8gb` is a single point of failure exactly like `adama`
  was. This migration removes the *host-rebuild* coupling, not the hardware SPOF.
- **Secrets**: broker passwords, the Zigbee2MQTT network key, and Postgres
  credentials must go through sops/age (as in `nix-homelab-hosts`), never as
  literals in these configs.
- **State**: incus storage lives on the host's persistent pool, but Home
  Assistant/Postgres/Zigbee2MQTT state still needs its own backup path; a
  rebuild of `rpi5-8gb` does not preserve it.
