# Density experiments

Track one change at a time. Annotate `Capacity / Density` and
`Pressure / Cache Risk` in Grafana before and after each step, then compare over
at least 24 h (use 1–2 h only for quick signal checks).

## Status (2026-10-18)

| ID | State | Notes |
|---|---|---|
| E1/E2 | **running** | cache rebalance applied; observation window started 2026-10-18 15:xx UTC; do not change anything else until it settles |
| E3 | reverted | swap-cap change overlapped E1/E2; re-run after the window |
| E4 | reverted | zram/swappiness change overlapped E1/E2; re-run after the window |
| E5 | pending | dev-only; run once E1/E2 has a result |
| E7 | pending | KSM; host + guest service config, deploy after E1/E2 |
| E8 | complete | duperemove dedup on container rootfs `/nix/store`: btrfs used 23.81 GiB → 19.15 GiB (~4.66 GiB); not reversible |
| E6, E9 | structural | deferred |

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

### E6 — Remove per-guest Alloy (largest single win)

- **Hypothesis:** per-guest Alloy costs ~0.8 GiB anon + ~1.5 GiB file cache
  across the fleet and is duplicated work.
- **Change:** drop per-guest Alloy; use the host's Incus metrics for
  CPU/mem/disk/network and add a lightweight journal shipper only where logs
  are needed.
- **Watch:** container anon total and file cache fall; host anon falls; refaults
  do not rise; per-instance anon floors drop (especially the small guests).
- **Guardrail:** keep critical logs/metrics coverage; document what is lost.
- **Rollback:** re-enable `services.alloy` via the guest module.

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

### E9 — Shared Nix store (longer-term)

- **Hypothesis:** a shared read-only store (with per-guest overlay) shares page
  cache and removes duplicate file cache across guests.
- **Change:** design only; start with a boot/GC/activation prototype in `dev`.
- **Watch:** `node_cgroup_memory_file_bytes`, shared inode page cache, refaults.
- **Guardrail:** never share a writable store; GC and `/nix/var/nix` must stay
  per guest.
- **Rollback:** prototype only until proven.

## Protocol

1. Annotate both dashboards with the experiment ID and the change.
2. Apply one change (`task up -- <name>` for terraform, host repo deploy for
   host-side).
3. Wait for the settling window; read `refault/s`, `active_file`,
   `pgsteal/s`, PSI, NVMe writes and OOM.
4. Record the result; keep or revert.
5. Keep `density` and `pressure` on a 24 h+ window for before/after.
