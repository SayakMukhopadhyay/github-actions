#!/usr/bin/env bash

set -euo pipefail

die() {
  printf 'create-release cleanup: %s\n' "$1" >&2
  exit 1
}

session_directory=${SESSION_DIRECTORY:-}
runner_temp=${RUNNER_TEMP:-}

# The collector can fail before it creates a session. In that case there is
# deliberately nothing for this always-running step to remove.
[[ -n "$session_directory" ]] || exit 0
[[ -n "$runner_temp" ]] || die 'RUNNER_TEMP is required when a session exists'
[[ -d "$session_directory" && ! -L "$session_directory" ]] \
  || die 'session directory must be a real directory'

runner_temp=$(realpath -- "$runner_temp")
session_directory=$(realpath -- "$session_directory")
[[ $(dirname -- "$session_directory") == "$runner_temp" ]] \
  || die 'session directory must be directly contained by RUNNER_TEMP'
session_name=$(basename -- "$session_directory")
[[ "$session_name" =~ ^create-release\.[A-Za-z0-9]+$ ]] \
  || die 'session directory does not have the collector-owned name'

rm -rf -- "$session_directory"
