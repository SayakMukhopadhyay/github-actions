#!/usr/bin/env bash

set -euo pipefail

repository_root=$1
collector_output=$(mktemp "${RUNNER_TEMP:-/tmp}/collector-output.XXXXXX")
matcher_output=${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}

GITHUB_OUTPUT=$collector_output bash "$repository_root/is-file-changed/collect-changed-files.sh"
changed_files=$(sed -n 's/^changed-files=//p' "$collector_output")
[[ -n "$changed_files" ]]

env \
  GITHUB_OUTPUT="$matcher_output" \
  "INPUT_PATTERN=$INPUT_PATTERN" \
  "INPUT_CHANGED-FILES=$changed_files" \
  node "$repository_root/actions/is-file-changed/dist/index.mjs"
