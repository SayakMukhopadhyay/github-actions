#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

mode=${1:-collect}
[[ "$EVENT_NAME" == push ]] || fail "is-file-changed supports push events only"
[[ "$BASE_SHA" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] || fail "push before SHA must be a full object ID"
[[ "$HEAD_SHA" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ && ! "$HEAD_SHA" =~ ^0+$ ]] || fail "push after SHA must be a non-zero full object ID"
if [[ "$mode" == validate ]]; then
  exit 0
fi
[[ "$mode" == collect ]] || fail "collector mode must be validate or collect"

workspace=${GITHUB_WORKSPACE:-$PWD}
workspace=$(realpath -e -- "$workspace")
cd -- "$workspace"

ensure_commit() {
  local sha=$1 label=$2 attempt
  git cat-file -e "$sha^{commit}" 2> /dev/null && return 0
  for attempt in 1 2; do
    if git fetch --no-tags --depth=1 origin "$sha" && git cat-file -e "$sha^{commit}" 2> /dev/null; then
      return 0
    fi
    printf 'Fetch attempt %s failed for %s commit %s\n' "$attempt" "$label" "$sha" >&2
  done
  fail "could not fetch $label commit $sha after 2 attempts; ensure the token can read the repository and the object still exists"
}

head=${HEAD_SHA,,}
base=${BASE_SHA,,}
ensure_commit "$head" head
if [[ "$base" =~ ^0+$ ]]; then
  base=$(git hash-object -t tree /dev/null)
else
  ensure_commit "$base" base
fi

changed_files=$(mktemp "${RUNNER_TEMP:-/tmp}/changed-paths.XXXXXX")
git diff --name-status -z --find-renames --find-copies --find-copies-harder "$base" "$head" > "$changed_files" || fail "Git could not compare $base and $head"
printf 'changed-files=%s\n' "$changed_files" >> "$GITHUB_OUTPUT"
