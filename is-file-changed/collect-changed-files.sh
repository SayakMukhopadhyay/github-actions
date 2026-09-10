#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

mode=${1:-collect}

is_full_oid() {
  [[ "$1" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]
}

validate_explicit_ref() {
  local value=$1 label=$2
  if is_full_oid "$value"; then
    [[ ! "$value" =~ ^0+$ ]] || fail "$label-ref must not be a zero object ID"
    return 0
  fi
  git check-ref-format --branch "$value" > /dev/null 2>&1 || fail "$label-ref must be a full commit object ID or valid Git ref"
}

base_ref=${BASE_REF:-}
head_ref=${HEAD_REF:-}
if [[ -n "$base_ref" || -n "$head_ref" ]]; then
  [[ -n "$base_ref" && -n "$head_ref" ]] || fail "base-ref and head-ref must be provided together"
  validate_explicit_ref "$base_ref" base
  validate_explicit_ref "$head_ref" head
else
  [[ "${EVENT_NAME:-}" == push ]] || fail "is-file-changed requires a push event when base-ref and head-ref are omitted"
  [[ "${BASE_SHA:-}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] || fail "push before SHA must be a full object ID"
  [[ "${HEAD_SHA:-}" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ && ! "$HEAD_SHA" =~ ^0+$ ]] || fail "push after SHA must be a non-zero full object ID"
  base_ref=$BASE_SHA
  head_ref=$HEAD_SHA
fi
if [[ "$mode" == validate ]]; then
  exit 0
fi
[[ "$mode" == collect ]] || fail "collector mode must be validate or collect"

workspace=${GITHUB_WORKSPACE:-$PWD}
workspace=$(realpath -e -- "$workspace")
cd -- "$workspace"

resolve_commit() {
  local requested=$1 label=$2 attempt resolved
  if resolved=$(git rev-parse --verify --quiet "$requested^{commit}") && is_full_oid "$resolved"; then
    printf '%s\n' "${resolved,,}"
    return 0
  fi
  for attempt in 1 2; do
    if git fetch --no-tags --depth=1 origin "$requested" \
      && resolved=$(git rev-parse --verify --quiet 'FETCH_HEAD^{commit}') \
      && is_full_oid "$resolved"; then
      printf '%s\n' "${resolved,,}"
      return 0
    fi
    printf 'Fetch attempt %s failed for %s ref %s\n' "$attempt" "$label" "$requested" >&2
  done
  fail "could not resolve or fetch $label ref $requested as a commit after 2 attempts; ensure the token can read the repository and the object exists"
}

head=$(resolve_commit "$head_ref" head)
if [[ "$base_ref" =~ ^0+$ ]]; then
  base=$(git hash-object -t tree /dev/null)
else
  base=$(resolve_commit "$base_ref" base)
fi

changed_files=$(mktemp "${RUNNER_TEMP:-/tmp}/changed-paths.XXXXXX")
git diff --name-status -z --find-renames --find-copies --find-copies-harder "$base" "$head" > "$changed_files" || fail "Git could not compare $base and $head"
printf 'changed-files=%s\n' "$changed_files" >> "$GITHUB_OUTPUT"
