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
| E7 | **rejected** | pilot ran 17:27–18:40 UTC on monitoring/HA/z2m/mosquitto with `use_zero_pages=1` and scan-time advisor. Best: sharing ~2041 pages (~8 MiB) + zero pages ~8067 (~32 MiB) ≈ **40 MiB gross / ~35 MiB net**, while `ksmd` burned ~6.7 % of one core during the window and `cow_ksm` rose to ~15 copies/s. Not worth fleet rollout; KSM stopped (`run=2`). Pending code revert |
| E8 | complete | duperemove dedup on container rootfs `/nix/store`: btrfs used 23.81 GiB → 19.15 GiB (~4.66 GiB); not reversible |
| E6, E9 | structural | deferred |

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
