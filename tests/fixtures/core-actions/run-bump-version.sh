#!/usr/bin/env bash

set -euo pipefail

repository_root=$1
mutation_output=$(mktemp "${RUNNER_TEMP:-/tmp}/mutation-output.XXXXXX")

read_action_output() {
  local key=$1 file=$2 line delimiter value terminator
  while IFS= read -r line; do
    if [[ $line == "$key="* ]]; then
      printf '%s\n' "${line#*=}"
      return 0
    fi
    if [[ $line == "$key<<"* ]]; then
      delimiter=${line#*<<}
      IFS= read -r value || return 1
      IFS= read -r terminator || return 1
      [[ $terminator == "$delimiter" ]] || return 1
      printf '%s\n' "$value"
      return 0
    fi
  done < "$file"
  return 1
}

bash "$repository_root/bump-version/git-transaction.sh" check-clean
env \
  GITHUB_OUTPUT="$mutation_output" \
  "INPUT_INCREMENT=${INPUT_INCREMENT:-patch}" \
  "INPUT_WORKING-DIRECTORY=${INPUT_WORKING_DIRECTORY:-.}" \
  "INPUT_HELM=${INPUT_HELM:-false}" \
  "INPUT_GO=${INPUT_GO:-false}" \
  node "$repository_root/actions/bump-version/dist/index.mjs"

application_version=$(read_action_output application-version "$mutation_output")
chart_version=$(read_action_output chart-version "$mutation_output")
NEW_APPLICATION_VERSION=$application_version \
  NEW_CHART_VERSION=$chart_version \
  bash "$repository_root/bump-version/git-transaction.sh" commit
