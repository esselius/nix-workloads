#!/usr/bin/env bash
# Print the incus remote for a workload, honouring inventory.nix placement.
# Usage: scripts/remote-for.sh <env> <workload>
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <env> <workload>" >&2
  exit 2
fi

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

# shellcheck disable=SC2016 # ${env}/${name} are Nix variables, not shell.
remote="$(
  REMOTE_ENV="$1" REMOTE_NAME="$2" nix eval --raw --impure --expr '
    let
      i = import ./inventory.nix;
      env = builtins.getEnv "REMOTE_ENV";
      name = builtins.getEnv "REMOTE_NAME";
    in
    i.envs.${env}.hosts.${i.hostFor env name}.remote
  '
)"
printf '%s\n' "$remote"
