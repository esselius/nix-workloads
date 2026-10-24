#!/usr/bin/env bash
# Incus-native rollback snapshots for one workload.
#
# Usage:
#   scripts/guest-snapshot.sh <env> <workload> create [label] [--expiry DUR] [--volumes-only]
#   scripts/guest-snapshot.sh <env> <workload> list
#   scripts/guest-snapshot.sh <env> <workload> restore [snapshot] [--force]
#
# The state of a workload is on the custom volumes attached to it
# (home-assistant-data, ...). Instance snapshots and `incus export` do NOT
# include custom volumes, so snapshot those volumes directly. step-ca is the
# one stateful guest without a custom volume (its badger DB lives on the
# rootfs); for it, snapshot the instance itself.
#
# These are rollback points, not backups: they stay on the same storage pool
# and are crash-consistent. The restic jobs remain the off-host, encrypted,
# application-consistent backup. Restoring is destructive; take a fresh
# snapshot first (`task snap -- <name>`) if the current state matters.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/guest-snapshot.sh <env> <workload> create [label] [--expiry DUR] [--volumes-only]
  scripts/guest-snapshot.sh <env> <workload> list
  scripts/guest-snapshot.sh <env> <workload> restore [snapshot] [--force]
EOF
  exit 2
}

[ "$#" -ge 3 ] || usage
env="$1"
name="$2"
action="$3"
shift 3

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"
remote="$(scripts/remote-for.sh "$env" "$name")"
export INCUS_REMOTE="$remote"

for bin in incus jq; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "$bin not found (run this inside the devshell)" >&2
    exit 1
  }
done

# Print "pool<TAB>volume" for every custom volume attached to the instance.
# The root disk (path /) and host path binds (absolute source) are not custom
# volumes.
list_volumes() {
  incus query "/1.0/instances/$name" |
    jq -r '
      ((.devices // {}) + (.expanded_devices // {}))
      | to_entries[]
      | select(.value.type == "disk")
      | select(.value.path != "/")
      | select(.value.source != null)
      | select((.value.source | startswith("/")) | not)
      | [.value.pool // "default", .value.source]
      | @tsv
    ' | sort -u
}

snapshot_instance() {
  local label="$1"
  local expiry="$2"
  local args=(snapshot create "$name" "$label")
  if [ -n "$expiry" ]; then
    args+=(--expiry "$expiry")
  fi
  incus "${args[@]}"
}

snapshot_volume() {
  local pool="$1"
  local volume="$2"
  local label="$3"
  local expiry="$4"
  local args=(storage volume snapshot create "$pool" "$volume" "$label")
  if [ -n "$expiry" ]; then
    args+=(--expiry "$expiry")
  fi
  incus "${args[@]}"
}

case "$action" in
  create)
    label=""
    expiry=""
    volumes_only=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --expiry)
          [ "$#" -ge 2 ] || usage
          expiry="$2"
          shift 2
          ;;
        --volumes-only)
          volumes_only=1
          shift
          ;;
        -*)
          usage
          ;;
        *)
          [ -z "$label" ] || usage
          label="$1"
          shift
          ;;
      esac
    done
    label="${label:-manual-$(date +%Y%m%d-%H%M%S)}"

    count=0
    while IFS=$'\t' read -r pool volume; do
      [ -n "$pool" ] || continue
      count=$((count + 1))
      echo "==> snapshot $pool/$volume ($label)"
      snapshot_volume "$pool" "$volume" "$label" "$expiry"
    done < <(list_volumes)

    if [ "$count" -eq 0 ]; then
      if [ "$volumes_only" = 1 ]; then
        exit 0
      fi
      echo "==> snapshot instance $name ($label)"
      snapshot_instance "$label" "$expiry"
    fi
    ;;

  list)
    count=0
    while IFS=$'\t' read -r pool volume; do
      [ -n "$pool" ] || continue
      count=$((count + 1))
      echo "== $pool/$volume"
      incus storage volume snapshot list "$pool" "$volume"
    done < <(list_volumes)

    if [ "$count" -eq 0 ]; then
      echo "== instance $name"
      incus snapshot list "$name"
    fi
    ;;

  restore)
    target=""
    force=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --force)
          force=1
          shift
          ;;
        -*)
          usage
          ;;
        *)
          [ -z "$target" ] || usage
          target="$1"
          shift
          ;;
      esac
    done

    # Resolve every target before touching the guest, so a typo or a missing
    # snapshot cannot leave only some volumes restored.
    targets="$(mktemp "${TMPDIR:-/tmp}/guest-snapshot.XXXXXX")"
    stale="$(mktemp "${TMPDIR:-/tmp}/guest-snapshot.XXXXXX")"
    trap 'rm -f "$targets" "$stale"' EXIT

    instance_target=""
    count=0
    while IFS=$'\t' read -r pool volume; do
      [ -n "$pool" ] || continue
      count=$((count + 1))

      json="$(incus storage volume snapshot list "$pool" "$volume" --format json)"
      if [ -n "$target" ]; then
        chosen="$target"
      else
        chosen="$(printf '%s\n' "$json" | jq -r '
          sort_by(.created_at) | last
          | if . == null then "" else (.name | split("/") | last) end
        ')"
        [ -n "$chosen" ] || {
          echo "no snapshots on $pool/$volume (use 'task snap -- $name')" >&2
          exit 1
        }
      fi

      created="$(printf '%s\n' "$json" | jq -r --arg n "$volume/$chosen" '
        .[] | select(.name == $n) | .created_at
      ')"
      [ -n "$created" ] || {
        echo "snapshot '$chosen' not found on $pool/$volume" >&2
        exit 1
      }

      printf '%s\t%s\t%s\n' "$pool" "$volume" "$chosen" >> "$targets"
      printf '%s\n' "$json" | jq -r --arg t "$created" '
        .[] | select(.created_at > $t) | .name | split("/") | last
      ' | while IFS= read -r newer; do
        printf '%s\t%s\t%s\n' "$pool" "$volume" "$newer" >> "$stale"
      done
    done < <(list_volumes)

    if [ "$count" -eq 0 ]; then
      json="$(incus snapshot list "$name" --format json)"
      if [ -n "$target" ]; then
        chosen="$target"
      else
        chosen="$(printf '%s\n' "$json" | jq -r '
          sort_by(.created_at) | last | .name // empty
        ')"
        [ -n "$chosen" ] || {
          echo "no instance snapshots on $name (use 'task snap -- $name')" >&2
          exit 1
        }
      fi

      created="$(printf '%s\n' "$json" | jq -r --arg n "$chosen" '
        .[] | select(.name == $n) | .created_at
      ')"
      [ -n "$created" ] || {
        echo "snapshot '$chosen' not found on instance $name" >&2
        exit 1
      }

      instance_target="$chosen"
      printf '%s\n' "$json" | jq -r --arg t "$created" '
        .[] | select(.created_at > $t) | .name
      ' | while IFS= read -r newer; do
        printf 'instance\t%s\t%s\n' "$name" "$newer" >> "$stale"
      done
    fi

    if [ -s "$stale" ] && [ "$force" = 0 ]; then
      {
        echo "refusing to restore '$target': newer snapshots would be deleted"
        echo "restore the latest snapshot, or re-run with --force:"
        sed 's/^/  /' "$stale"
      } >&2
      exit 1
    fi

    echo "restore is destructive; run 'task snap -- $name' first to keep the current state"
    state="$(incus list "$name" -c s --format csv | head -1 | tr -d '"')"
    was_running=0
    if [ "$state" = "RUNNING" ]; then
      was_running=1
      echo "==> stop $name for restore"
      incus stop "$name" --timeout 120
    fi

    while IFS=$'\t' read -r pool volume newer; do
      [ -n "$pool" ] || continue
      if [ "$pool" = "instance" ]; then
        echo "==> delete newer instance snapshot $name/$newer"
        incus snapshot delete "$name" "$newer"
      else
        echo "==> delete newer snapshot $pool/$volume/$newer"
        incus storage volume snapshot delete "$pool" "$volume" "$newer"
      fi
    done < "$stale"

    if [ -n "$instance_target" ]; then
      echo "==> restore instance $name <- $instance_target"
      incus snapshot restore "$name" "$instance_target"
    else
      while IFS=$'\t' read -r pool volume chosen; do
        [ -n "$pool" ] || continue
        echo "==> restore $pool/$volume <- $chosen"
        incus storage volume snapshot restore "$pool" "$volume" "$chosen"
      done < "$targets"
    fi

    if [ "$was_running" = 1 ]; then
      echo "==> start $name"
      incus start "$name"
    else
      echo "==> $name was stopped; leaving it stopped"
    fi
    ;;

  *)
    usage
    ;;
esac
