#!/usr/bin/env bash

set -euo pipefail

readonly MAX_TAGS=256
readonly MAX_TAG_NAME_LENGTH=255

die() {
  printf 'release-tags: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" > /dev/null 2>&1 || die "required command not found: $1"
}

write_match_output() {
  printf 'tags-match=%s\n' "$1" >> "$GITHUB_OUTPUT"
}

write_exists_output() {
  printf 'tags-exist=%s\n' "$1" >> "$GITHUB_OUTPUT"
}

git_remote() (
  local config_count=${GIT_CONFIG_COUNT:-0}
  export GIT_CONFIG_COUNT=$((config_count + 2))
  export "GIT_CONFIG_KEY_${config_count}=credential.helper"
  export "GIT_CONFIG_VALUE_${config_count}="
  export "GIT_CONFIG_KEY_$((config_count + 1))=http.extraheader"
  export "GIT_CONFIG_VALUE_$((config_count + 1))=$authorization_header"
  export GIT_TERMINAL_PROMPT=0
  git "$@"
)

read_remote_tags() {
  local object ref tag tag_ref remote_output
  remote_direct=()
  remote_peeled=()
  remote_output=$(git_remote ls-remote origin "${remote_patterns[@]}") \
    || die 'could not read release tags from origin'

  while IFS=$'\t' read -r object ref; do
    [[ -n "$ref" ]] || continue
    [[ "$object" =~ ^[0-9a-fA-F]{40,64}$ ]] \
      || die 'origin returned an invalid tag object ID'
    if [[ "$ref" == *'^{}' ]]; then
      tag_ref=${ref::-3}
      tag=${tag_ref#refs/tags/}
      [[ -n "${requested_tags[$tag]:-}" ]] \
        || die 'origin returned an unexpected peeled tag ref'
      [[ -z "${remote_peeled[$tag]:-}" ]] \
        || die "origin returned duplicate peeled refs for tag: $tag"
      remote_peeled["$tag"]=${object,,}
    else
      tag=${ref#refs/tags/}
      [[ "$tag" != "$ref" && -n "${requested_tags[$tag]:-}" ]] \
        || die 'origin returned an unexpected tag ref'
      [[ -z "${remote_direct[$tag]:-}" ]] \
        || die "origin returned duplicate refs for tag: $tag"
      remote_direct["$tag"]=${object,,}
    fi
  done <<< "$remote_output"

  for tag in "${tags[@]}"; do
    [[ -z "${remote_peeled[$tag]:-}" || -n "${remote_direct[$tag]:-}" ]] \
      || die "origin returned a peeled tag without its direct ref: $tag"
  done
}

classify_remote_tags() {
  local tag resolved
  missing_tags=()
  conflicting_tags=()
  for tag in "${tags[@]}"; do
    resolved=''
    if [[ -n "${remote_peeled[$tag]:-}" ]]; then
      resolved=${remote_peeled[$tag]}
    elif [[ -n "${remote_direct[$tag]:-}" ]]; then
      resolved=${remote_direct[$tag]}
    fi

    if [[ -z "$resolved" ]]; then
      missing_tags+=("$tag")
    elif [[ "$resolved" != "$target_commit" ]]; then
      conflicting_tags+=("$tag")
    fi
  done
}

mode=${INPUT_MODE:-verify}
tags_input=${INPUT_TAGS:-}
token=${INPUT_TOKEN:-}
unset INPUT_TOKEN
target_sha=${TARGET_SHA:-}

[[ "$mode" == exists || "$mode" == verify || "$mode" == ensure ]] \
  || die 'mode must be exists, verify, or ensure'
[[ -n "$tags_input" ]] || die 'tags is required'
[[ -n "$token" ]] || die 'token is required'
[[ "$token" != *$'\n'* && "$token" != *$'\r'* ]] \
  || die 'token contains an invalid line break'
[[ -n "$target_sha" ]] || die 'github.sha is required'
[[ -n "${GITHUB_OUTPUT:-}" ]] || die 'GITHUB_OUTPUT is required'

require_command base64
require_command git
require_command tr

workspace=${GITHUB_WORKSPACE:-$PWD}
workspace=$(realpath -e -- "$workspace") || die 'GITHUB_WORKSPACE does not exist'
cd -- "$workspace"
git rev-parse --is-inside-work-tree > /dev/null 2>&1 \
  || die 'GITHUB_WORKSPACE is not a Git worktree'
target_commit=$(git rev-parse --verify "${target_sha}^{commit}" 2> /dev/null) \
  || die 'github.sha does not resolve to a local commit'
target_commit=${target_commit,,}
[[ "$(git rev-parse HEAD)" == "$target_commit" ]] \
  || die 'checkout HEAD does not match github.sha'

declare -a tags=()
declare -A requested_tags=()
while IFS= read -r tag || [[ -n "$tag" ]]; do
  tag=${tag%$'\r'}
  [[ -n "$tag" ]] || die 'tags contains an empty line'
  ((${#tag} <= MAX_TAG_NAME_LENGTH)) \
    || die "tag name exceeds the supported length: $tag"
  git check-ref-format "refs/tags/$tag" > /dev/null 2>&1 \
    || die "invalid Git tag name: $tag"
  [[ -z "${requested_tags[$tag]:-}" ]] || die "duplicate tag: $tag"
  requested_tags["$tag"]=1
  tags+=("$tag")
  ((${#tags[@]} <= MAX_TAGS)) || die "tags exceeds the limit of $MAX_TAGS"
done < <(printf '%s' "$tags_input")
((${#tags[@]} > 0)) || die 'tags is required'

authorization=$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\r\n')
unset token
authorization_header="AUTHORIZATION: basic $authorization"
unset authorization

declare -a remote_patterns=()
for tag in "${tags[@]}"; do
  remote_patterns+=("refs/tags/$tag" "refs/tags/$tag^{}")
done
declare -A remote_direct=()
declare -A remote_peeled=()
declare -a missing_tags=()
declare -a conflicting_tags=()

read_remote_tags
classify_remote_tags

if [[ "$mode" == exists ]]; then
  if ((${#missing_tags[@]} == 0)); then
    write_exists_output true
    printf 'Every requested tag exists.\n'
  else
    write_exists_output false
    printf 'Missing tags: %s\n' "${missing_tags[*]}"
  fi
  exit 0
fi

if [[ "$mode" == verify ]]; then
  if ((${#missing_tags[@]} == 0 && ${#conflicting_tags[@]} == 0)); then
    write_match_output true
    printf 'Every requested tag resolves to %s.\n' "$target_commit"
  else
    write_match_output false
    ((${#missing_tags[@]} == 0)) \
      || printf 'Missing tags: %s\n' "${missing_tags[*]}"
    ((${#conflicting_tags[@]} == 0)) \
      || printf 'Tags resolving elsewhere: %s\n' "${conflicting_tags[*]}"
  fi
  exit 0
fi

((${#conflicting_tags[@]} == 0)) \
  || die "refusing to overwrite tags resolving to another object: ${conflicting_tags[*]}"

if ((${#missing_tags[@]} == 0)); then
  write_match_output true
  printf 'Every requested tag already resolves to %s; nothing to create.\n' "$target_commit"
  exit 0
fi

declare -a refspecs=()
for tag in "${missing_tags[@]}"; do
  refspecs+=("$target_commit:refs/tags/$tag")
done

set +e
push_output=$(git_remote push --atomic --no-force origin "${refspecs[@]}" 2>&1)
push_status=$?
set -e
[[ -z "$push_output" ]] || printf '%s\n' "$push_output"

# Re-read every tag even when push reports failure. A retry or concurrent run may
# have created the complete same-target set between preflight and publication.
read_remote_tags
classify_remote_tags
if ((${#missing_tags[@]} == 0 && ${#conflicting_tags[@]} == 0)); then
  write_match_output true
  if ((push_status == 0)); then
    printf 'Every requested tag now resolves to %s.\n' "$target_commit"
  else
    printf 'A concurrent run created every requested tag at %s.\n' "$target_commit"
  fi
  exit 0
fi

if ((push_status != 0)); then
  die 'atomic tag push was rejected and the requested tags do not all resolve to github.sha'
fi
die 'origin did not retain the requested tag set after a successful atomic push'
