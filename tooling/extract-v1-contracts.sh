#!/usr/bin/env bash

set -euo pipefail

destination=${1:?usage: extract-v1-contracts.sh DESTINATION}

if [[ -e "$destination" ]] && [[ -n "$(find "$destination" -mindepth 1 -print -quit)" ]]; then
  printf 'Refusing to overwrite non-empty baseline directory: %s\n' "$destination" >&2
  exit 1
fi

git rev-parse --verify 'refs/tags/v1^{commit}' > /dev/null
mkdir -p "$destination"

action_count=0
while IFS= read -r metadata_path; do
  if [[ ! $metadata_path =~ ^([^/]+)/action\.yaml$ ]]; then
    continue
  fi

  action_name=${BASH_REMATCH[1]}
  mkdir -p "$destination/$action_name"
  git show "v1:$metadata_path" > "$destination/$metadata_path"
  ((action_count += 1))
done < <(git ls-tree --name-only -r v1)

if ((action_count == 0)); then
  printf 'The v1 tag contains no public action.yaml files.\n' >&2
  exit 1
fi

printf 'Extracted %d public v1 action contracts to %s\n' "$action_count" "$destination"
