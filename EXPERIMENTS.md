# Density experiments

Track one change at a time. Annotate `Capacity / Density` and
`Pressure / Cache Risk` in Grafana before and after each step, then compare over
at least 24 h (use 1–2 h only for quick signal checks).

## Status (2026-10-18)

| ID | State | Notes |
|---|---|---|
| E1/E2 | **running** | cache rebalance applied; observation window started 2026-10-18 ~15:35 UTC; do not change anything else until it settles |
| E3 | **running** | monitoring `limits.memory.swap` 256→512 MiB (applied 16:07 UTC); swap events/high/max/fail still 0, swap use 167 MiB, zram RAM 196 MiB |
| E4 | reverted | zram/swappiness change reverted; re-run after E1/E2 |
| E5 | partial | dev-only: 256 MiB hard-limit `oom-test` container stopped on a 512 MiB `/dev/shm` allocation; cgroup OOM path validated, host-level priority ordering not forced |
| E7 | **rejected, reverted** | pilot ran 17:27–18:40 UTC on monitoring/HA/z2m/mosquitto with `use_zero_pages=1` and scan-time advisor. Best: sharing ~2041 pages (~8 MiB) + zero pages ~8067 (~32 MiB) ≈ **40 MiB gross / ~35 MiB net**, while `ksmd` burned ~6.7 % of one core and `cow_ksm` rose to ~15 copies/s. Not worth fleet rollout; KSM stopped (`run=2`) and the host/guest KSM code removed |
| E8 | complete | duperemove dedup on container rootfs `/nix/store`: btrfs used 23.81 GiB → 19.15 GiB (~4.66 GiB); not reversible |
| E6, E9 | structural | deferred |

> 2026-10-19: DNS moved out of the workload fleet. Incus now serves the
> `int.esselius.dev` network zone over AXFR; the host-level Unbound resolver is
> the VPN client resolver, and the `coredns` workload was removed (10 instances).
> The E1/E2 window predates that change; treat its cache conclusions separately.

### Check-in 2026-10-18 16:54 UTC

- All 11 instances running, 0 failed units, host load 0.30, `MemAvailable`
  ~3.95 GiB, zram swap used ~1.19 GiB.
- Refaults: total now **3.8/s**, 2 h average **33.3/s**, 2 h max **125.8/s**;
  the larger early values line up with the E8 dedup scan and periodic work.
- Working set (`active_file`): monitoring 300 MiB is the largest; everything
  else 31–98 MiB. Current usage is well below every limit, e.g. monitoring
  1035/1536, HA 542/1280, zigbee2mqtt 399/1024.
- OOM kills 0; PSI memory full ~0, PSI io full ~0.7 %; NVMe wear 3 %, spare
  100 %, write rate ~0.34 MB/s; btrfs used 19.08 GiB.
- 24 h cgroup counters: `memory.max` events monitoring 657, homepage 220,
  kanidm 114 (cache capping, not OOM); swap cap hits home-assistant 220,
  zigbee2mqtt 39, homepage 7 — these happened during the reverted E4
  swappiness window, so keep swap caps in mind if E4 is retried.
- E3: monitoring swap use ~165 MiB, no `swap_events_*`; neutral so far.
- Next: let E1/E2 close out, then retry E4/E3 in isolation, then E7.

### Check-in 2026-10-18 17:19 UTC

- 11/11 running, 0 failed, load 0.52, `MemAvailable` ~4.15 GiB.
- Refaults: total 4.65/s now, 4 h average 30.3/s, max 143.7/s.
- Refault distribution shifted to the untouched/trimmed set: coredns 1.74/s,
  backup 0.75, homepage 0.74, attic 0.70, kanidm 0.42, step-ca 0.26;
  monitoring, home-assistant, zigbee2mqtt and mosquitto are now **0**.
- E1 looks effective for monitoring (refaults 0 at 986/1536 MiB).
- E2-trimmed instances show small refaults (kanidm 294/320, homepage 283/384,
  node-red 330/384, attic 199/384); watch before concluding.
- coredns is tight and was not tuned: 304/320 MiB with 1.74 refault/s — a
  candidate for the next cache raise.
- OOM 0; PSI memory full ~0, PSI io full ~0.67 %; NVMe wear 3 %, spare 100 %;
  btrfs 19.09 GiB; 24 h max/swap-cap counters unchanged.

## Non-structural set

These keep the current 11-instance layout and do not replace or merge
components:

- **E1** cache rebalance: give limits to the refaulting instances
- **E2** cache trim: reclaim cold cache from the quiet instances
- **E3** per-instance zram swap cap
- **E4** host zram `memoryPercent` / swappiness
- **E5** OOM-priority validation in `dev`
- **E7** KSM
- **E8** btrfs dedup

Structural, deferred: **E6** (remove/replace per-guest Alloy) and **E9**
(shared read-only Nix store).

E1 and E2 touch disjoint instances and can be treated as one rebalance
experiment. Run E3/E4 only after the cache limits have settled, and E5 only in
`dev`.

## Baseline

- Host: `rpi5-8gb`, 8 GiB RAM, zram 50 % zstd, `psi=1`, KSM off, per-guest
  Alloy present.
- Per-instance hard limits and swap caps live in `inventory.nix` (`memory`).
- Dashboards: `density` and `pressure`; the `pressure` text panel lists the
  negative-effect signals.

### Cache snapshot (5 min rates, post-limit-change)

| Instance | active_file | refault/s | activate/s | current/limit |
|---|---:|---:|---:|---:|
| monitoring | 419 MiB | 2.35 | 1.54 | 1279/1280 |
| zigbee2mqtt | 135 MiB | 3.86 | 3.86 | 760/768 |
| backup | 90 MiB | 3.61 | 1.57 | 317/320 |
| step-ca | 117 MiB | 2.95 | 1.94 | 378/384 |
| mosquitto | 93 MiB | 1.36 | 1.01 | 299/320 |
| home-assistant | 179 MiB | 0.66 | 0.49 | 892/1536 |
| attic | 87 MiB | 0.65 | 0.55 | 388/512 |
| homepage | 125 MiB | 0.48 | 0.45 | 464/512 |
| coredns | 141 MiB | 0.18 | 0.17 | 300/320 |
| kanidm | 110 MiB | 0.04 | 0 | 374/384 |
| node-red | 163 MiB | 0 | 0 | 460/512 |

Read `active_file` as the hot file working set. Sustained
`workingset_refault_file`/`activate_file` means reused content is being evicted
and re-read, so the cache is smaller than the working set.

## Experiments

### E1 — Give cache back to the refaulting instances

- **Hypothesis:** monitoring, zigbee2mqtt, backup, step-ca and mosquitto need
  more cache than their limits allow.
- **Change:** raise limits: monitoring `1280→1536MiB`, zigbee2mqtt
  `768→1024MiB`, backup `320→448MiB`, step-ca `384→512MiB`, mosquitto
  `320→448MiB`.
- **Watch:** `refault/s` → ~0, `activate/s` → ~0, `active_file` stabilizes,
  `pgsteal/s` falls, `current` no longer pinned at `max`.
- **Guardrail:** `oom_kill`, `swap_events_fail`, PSI memory/io, NVMe write rate
  stay flat; host `MemAvailable` stays > ~1 GiB.
- **Rollback:** revert the `memory` table in `inventory.nix`.
- **Follow-up 2026-10-19:** monitoring `1792→2048MiB` and kanidm
  `320→384MiB` after monitoring showed 3.9 refault/s with 432 MiB
  `active_file`, and kanidm 0.76 refault/s with 27 `memory.max` events/h.

### E2 — Reclaim cold cache from the quiet instances

- **Hypothesis:** attic, homepage, node-red, kanidm and home-assistant hold
  large `inactive_file` with zero refaults, so their limits can shrink.
- **Change:** attic `512→384MiB`, homepage `512→384MiB`, node-red
  `512→384MiB`, kanidm `384→320MiB`, home-assistant `1536→1280MiB`.
- **Watch:** refaults stay ~0; `active_file` still fits; no OOM.
- **Guardrail:** refault > 0 sustained or any OOM means the trim was too far.
- **Rollback:** revert the `memory` table in `inventory.nix`.

### E3 — zram is the swap budget; prove it absorbs a little more

- **Hypothesis:** the host can use more zram before the containers need more
  RAM, without touching the NVMe.
- **Change:** on one instance (start with monitoring) raise `limits.memory.swap`
  from `256MiB` to `512MiB`.
- **Watch:** `swap_events_max/fail`, `zram` ratio and `mem_used`, PSI memory/io.
- **Guardrail:** `node_nvme_data_written_bytes_total` slope must stay flat;
  rising `pswpout` plus flat zram means disk swap, not zram.
- **Rollback:** revert the swap value.

### E4 — zram tuning: memoryPercent and swappiness

- **Hypothesis:** 50 % zram with default swappiness under-uses the compressed
  swap that is already paid for.
- **Change (host repo):** `zramSwap.memoryPercent = 75`; consider
  `vm.swappiness = 100`, `vm.page-cluster = 0`.
- **Watch:** zram ratio, swap used, PSI memory/io, `pswpin/pswpout`, CPU.
- **Guardrail:** zram `mem_used` growth is real RAM cost; PSI latency must not
  rise.
- **Rollback:** revert `modules/zram.nix` / sysctls.

### E5 — OOM policy under real pressure (dev first)

- **Hypothesis:** the chosen `oom_priority` ordering protects the smart-home
  services and sacrifices batch work first.
- **Change:** in the `dev` env, run a memory hog in a disposable guest while a
  critical guest is under `limits.memory` pressure; observe which cgroup is
  killed.
- **Watch:** `node_cgroup_memory_oom_kill_total`, `memory.events`,
  `incus_memory_OOM_kills_total`.
- **Guardrail:** none in dev; never run the hog in the homelab.
- **Rollback:** stop the hog / destroy the dev guest.

### E6 — Replace or tune per-guest Alloy

**Measured baseline** (cgroup `alloy.service`, per guest): RSS 99–219 MiB,
`anon` 56–94 MiB, `file` 87–259 MiB, `current` 148–357 MiB. Fleet `anon`
~0.7 GiB and RSS ~1.4 GiB, plus a ~360 MiB shared closure.

**Option A — tune Alloy (pilot on mosquitto, 2026-10-18)**

- `GOMEMLIMIT=64MiB`, `GOGC=50`, `--disable-reporting`, minimal
  `set_collectors`, node scrape `2m`.
- Result: `anon` 62 → 51 MiB, but `file`/`current` rose because the container
  limit was also raised by E1; RSS stayed high. CPU ~0.5 % of one core.
- Verdict: cheap and harmless, small anon win, not enough on its own.

**Option B prototype — mosquitto, 2026-10-18 20:5x**

- mosquitto: Alloy removed; `prometheus-node-exporter` (with `systemd`) and
  `systemd-journal-upload` added; broker exporter rebound to `0.0.0.0:9234`;
  monitoring Alloy scrapes both targets.
- Measured: Alloy gone (was 122 MiB RSS / 62 MiB anon); node_exporter 24.8 MiB,
  journal-upload 15.9 MiB, mosquitto-exporter 17.7 MiB; guest `anon` 37 MiB.
  Rough saving **~80 MiB RSS / ~48 MiB anon** for this guest; extrapolates to
  roughly **0.9–1.3 GiB RSS** fleet-wide.
- Verified: `up{host="mosquitto"}` for both node and app jobs;
  `node_systemd_unit_state{host="mosquitto",state="failed"}` present (failed
  units retained); broker metrics intact.
- Logs: `systemd-journal-remote` created
  `/var/lib/monitoring/journal-remote/remote-10.43.0.11.journal`. **Not yet in
  Loki** — ingestion from the remote journal files into Loki is the open piece.
- Note: `systemd-journal-remote` logged a btrfs CoW warning; set `chattr +C` on
  the journal directory (and add retention) before wider use.

**Rollout — light mode on 9 guests, 2026-10-18 21:1x**

- `local.monitoring.mode = "light"` on attic, backup, coredns, homepage, kanidm,
  mosquitto, node-red, step-ca, zigbee2mqtt. Home Assistant and monitoring
  remain on Alloy (HA metrics need a token over the network; monitoring hosts
  the stack).
- Central monitoring Alloy scrapes are generated from `inventory.metrics`
  (node :9100, app exporters, restic :9753); no file_sd.
- Logs: guest `systemd-journal-upload` → monitoring `systemd-journal-remote`
  (`/var/lib/monitoring/journal-remote`, 7-day cleanup, `chattr +C`) → central
  Vector `journald`/`remote_journal` → Loki. Verified with a fresh `coredns`
  log arriving as `{host="coredns", job="systemd-journal"}`.
- Monitoring `limits.memory` raised 1536 → 1792 MiB for the Vector process.
- Result: 11 Alloy instances → 2; host `AnonPages` 2.11 → **1.63 GiB**;
  `MemAvailable` 3.95 → **4.52 GiB**; container anon total 1.59 GiB.
- Failed units retained everywhere (`node_systemd_unit_state{state="failed"}`
  present on all light guests); node/app/restic scrapes all `up=1`.
- Caveats: Vector `since_now=true` means entries during a Vector restart are
  skipped; journal files cleaned after 7 days; node_exporter runs as root;
  central scrape config is static per deploy.
- **CPU regression fixed:** monitoring Alloy was pinned at ~88% of one core
  with the aggressive `GOMEMLIMIT=64MiB`/`GOGC=50`; raising to
  `GOMEMLIMIT=192MiB`/`GOGC=100` dropped it to ~1% of one core while it runs
  the central scrapes. Also fixed two generated-config commas (`__metrics_path__`
  field and app target) that made reload fail; z2m's mqtt-exporter was rebound
  from `127.0.0.1` to `0.0.0.0:9000`.

**Option B — `node_exporter` + lightweight log shipper (recommended)**

- Per guest: `prometheus-node-exporter` (~20 MiB RSS, or `set_collectors` for
  the same set) plus `systemd-journal-upload` (~5–10 MiB) or `vector` for
  journald.
- Move the per-guest app scrapes (mosquitto, mqtt-exporter, home-assistant,
  restic) into the monitoring guest's Alloy, which can reach them over
  `incusbr-vpn`.
- Expected: ~30–40 MiB/guest instead of 100–220 MiB; fleet saving ~0.7–1.3 GiB
  RSS. Keeps node metrics and failed-unit state; logs need a central
  `systemd-journal-remote` and a small reader for Loki.
- Risk: moderate refactor; porting the scrape configs and validating the log
  path.

**Option C — single `vector` per guest**

- `host_metrics` + `prometheus_scrape` + `journald` sources →
  `prometheus_remote_write` + `loki` sinks.
- One process, ~40–80 MiB RSS typical; avoids two agents.
- Risk: porting Alloy configs to Vector TOML and validating component parity
  (systemd unit state, node metrics).

**Watch:** per-guest `anon`/`file`/`current`, RSS, node/incus metric coverage,
Loki log continuity, failed-unit alerting.

**Rollback:** re-enable `services.alloy` via the guest module.

### E7 — KSM: measure before committing

- **Hypothesis:** KSM can deduplicate anonymous pages across guests, but only if
  pages are marked mergeable.
- **Change (host):** `hardware.ksm.enable = true`; per guest, set
  `MemoryKSM = "yes"` on target services (or a NixOS module that sets it for
  all services).
- **Watch:** `node_ksmd_pages_shared/sharing`, `general_profit_bytes`,
  `cow_ksm`, CPU, PSI.
- **Guardrail:** keep only if `general_profit_bytes` is positive and
  `cow_ksm`/latency stay low.
- **Rollback:** `hardware.ksm.enable = false` and remove `MemoryKSM`.

### E8 — btrfs dedup: disk only, not density

- **Hypothesis:** identical Nix-store content across container rootfs can be
  deduplicated.
- **Change:** dry-run `duperemove` over the container subvolumes; if the gain is
  > 2 GiB, add a periodic job (or `bees` with one worker and a load target).
  Exclude DB volumes.
- **Watch:** `node_btrfs_used_bytes` by block group, `node_filesystem_avail_bytes`,
  IO latency, CPU, NVMe writes.
- **Guardrail:** storage is not the constraint, so abort if it costs IO/CPU
  without materially shrinking the pool.
- **Rollback:** remove the timer/service.

### E9 — Shared Nix store (design + reliability)

- **Hypothesis:** a shared read-only store (with per-guest overlay) shares page
  cache and removes duplicate file cache across guests.
- **Watch:** `node_cgroup_memory_file_bytes`, shared inode page cache, refaults.

**How it could work**

1. One authority owns the shared store (the host's persistent `/nix/store` on
   the `@nix` subvolume). Guest closures are pushed there from Attic by the
   host; the host's own store is the single writer.
2. Each guest gets an overlay at `/nix/store`:
   `lowerdir=<shared store>[:<rootfs store>]`, `upperdir=<guest-local>`,
   `workdir=<guest-local>`. Reads of shared paths hit the same inodes, so the
   host page cache is shared; writes go to the guest's upper layer.
3. The overlay must exist before systemd reads its units. In an Incus container
   that means a boot-time mount that also keeps the rootfs `/nix/store` visible,
   i.e. a lower layer for the running generation.
4. `/nix/var/nix` (DB, profiles, GC roots) stays per guest. Writable-store
   sharing is rejected: concurrent `db.sqlite`, GC and registration are not
   safe between independent systems.

**Reliability assessment**

- Overlay mechanics work: tested in a `dev` guest (unprivileged), including
  read, hardlink across the lower/upper boundary, symlink, rename and delete.
- Unresolved and load-bearing:
  - **Boot ordering**: the running generation's store paths must be in a lower
    layer before systemd starts, otherwise the container cannot exec its init.
    Needs a bind-mount + overlay setup in the LXC config or a very early mount,
    which Incus does not expose as a normal device.
  - **Nix DB/references**: a guest's `db.sqlite` does not know the shared
    paths, so `nix-store -q --references`, `--verify`, activation and GC
    behave differently. Seeding/syncing a read-only DB is not a supported
    pattern.
  - **GC**: guest auto-GC on a shared lower either whiteouts shared paths in
    its upper or fails; the shared store needs central GC roots and the guests
    must not GC it.
  - **Deploy flow**: every new closure must land in the shared store before the
    guest switches, so `task deploy` gains a host-side `nix copy` step and the
    build/cache flow gets more moving parts.
  - The gain is page cache/disk, not the anon pressure that is the real
    constraint here.
- **Verdict:** not reliable enough to trust for the critical smart-home
  services. The safe variants are consolidation (one system, shared inodes,
  shared page cache, normal Nix semantics) and E8 dedup (disk only). Prototype
  in `dev` at most; do not put it under the homelab.
- **Rollback:** prototype only until proven.

## Protocol

1. Annotate both dashboards with the experiment ID and the change.
2. Apply one change (`task up -- <name>` for terraform, host repo deploy for
   host-side).
3. Wait for the settling window; read `refault/s`, `active_file`,
   `pgsteal/s`, PSI, NVMe writes and OOM.
4. Record the result; keep or revert.
5. Keep `density` and `pressure` on a 24 h+ window for before/after.
