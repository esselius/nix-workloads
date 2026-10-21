#!/usr/bin/env bash
# Post-deploy smoke test for one incus workload.
# Usage: scripts/verify-guest.sh <env> <workload>
set -euo pipefail

env="${1:?usage: $0 <env> <workload>}"
name="${2:?usage: $0 <env> <workload>}"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

remote="$(scripts/remote-for.sh "$env" "$name")"
export INCUS_REMOTE="$remote"

fail=0
run() {
  incus exec "$name" -- "$@"
}

ok() {
  printf '  ok: %s\n' "$1"
}

bad() {
  printf '  FAIL: %s\n' "$1" >&2
  fail=1
}

if ! incus exec "$name" -- true >/dev/null 2>&1; then
  echo "FAIL: cannot exec into $name (remote $remote)" >&2
  exit 1
fi

state="$(incus list "$name" --format csv -c s 2>/dev/null | head -1 || true)"
if [ "$state" = "RUNNING" ]; then
  ok "instance running"
else
  bad "instance state is '${state:-unknown}'"
fi

system="$(run systemctl is-system-running 2>/dev/null || true)"
case "$system" in
  running) ok "systemd is running" ;;
  *) bad "systemd state is '${system:-unknown}', expected running" ;;
esac

failed="$(run systemctl --failed --no-legend --plain 2>/dev/null || true)"
if [ -z "$failed" ]; then
  ok "no failed systemd units"
else
  bad "failed systemd units:"
  printf '%s\n' "$failed" | sed 's/^/       /' >&2
fi

case "$name" in
  attic) unit=atticd.service ;;
  backup) unit=restic-rest-server.service ;;
  home-assistant) unit=home-assistant.service ;;
  homepage) unit=homepage-dashboard.service ;;
  kanidm) unit=kanidm.service ;;
  monitoring) unit=grafana.service ;;
  mosquitto) unit=mosquitto.service ;;
  node-red) unit=node-red.service ;;
  step-ca) unit=step-ca.service ;;
  zigbee2mqtt) unit=zigbee2mqtt.service ;;
  edge|example) unit="" ;;
  *) unit="" ;;
esac

if [ -n "$unit" ]; then
  if run systemctl is-active --quiet "$unit"; then
    ok "$unit active"
  else
    bad "$unit is not active"
  fi
fi

printf '  current: %s\n' "$(run readlink /run/current-system 2>/dev/null || echo unknown)"

if [ "$fail" -ne 0 ]; then
  echo "verify $name: FAILED" >&2
  exit 1
fi
echo "verify $name: OK"
