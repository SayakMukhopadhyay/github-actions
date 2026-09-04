#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

workspace=$(realpath -e -- "${GITHUB_WORKSPACE:-$PWD}")
checkout=$(realpath -e -- "$workspace/${INPUT_CHECKOUT_PATH:-.gitops-charts}") || fail "target checkout does not exist"
[[ "$checkout" == "$workspace/"* ]] || fail "target checkout escapes the workspace"
[[ -z "$(git -C "$checkout" status --porcelain)" ]] || fail "target repository checkout is not clean"

command -v yq > /dev/null || fail "yq v4 is required"
[[ $(yq --version) =~ version[[:space:]]+v?4\. ]] || fail "yq v4 is required"

environment=${INPUT_ENVIRONMENT:?environment is required}
chart_name=${INPUT_CHART_NAME:?chart-name is required}
dependency=${INPUT_DEPENDENCY:?dependency is required}
target_version=${INPUT_CHART_VERSION:?chart-version is required}
[[ "$target_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$ ]] || fail "chart-version must be an exact semantic version"
[[ "$dependency" != */* && "$dependency" != *$'\n'* ]] || fail "dependency must be a chart name"

wrapper_relative=${INPUT_WRAPPER_CHART_PATH:-}
[[ -n "$wrapper_relative" ]] || wrapper_relative="$chart_name/envs/$environment"
wrapper=$(realpath -e -- "$checkout/$wrapper_relative") || fail "wrapper chart does not exist: $wrapper_relative"
[[ "$wrapper" == "$checkout/"* ]] || fail "wrapper-chart-path escapes the target checkout"
chart_file="$wrapper/Chart.yaml"
lock_file="$wrapper/Chart.lock"

dependency_count=$(DEPENDENCY="$dependency" yq -er '[.dependencies[] | select(.name == strenv(DEPENDENCY))] | length' "$chart_file") || fail "could not inspect dependencies in $chart_file"
[[ "$dependency_count" == 1 ]] || fail "$chart_file must contain exactly one dependency named '$dependency'; found $dependency_count"
current_version=$(DEPENDENCY="$dependency" yq -er '.dependencies[] | select(.name == strenv(DEPENDENCY)) | .version' "$chart_file")
target_archive="$wrapper/charts/$dependency-$target_version.tgz"

if [[ "$current_version" == "$target_version" ]]; then
  [[ -f "$lock_file" ]] || fail "Chart.yaml already requests $target_version, but Chart.lock is missing"
  locked_version=$(DEPENDENCY="$dependency" yq -er '.dependencies[] | select(.name == strenv(DEPENDENCY)) | .version' "$lock_file") || fail "Chart.lock does not contain dependency '$dependency'"
  [[ "$locked_version" == "$target_version" ]] || fail "Chart.yaml requests $target_version, but Chart.lock records $locked_version"
  [[ -f "$target_archive" ]] || fail "Chart.yaml requests $target_version, but vendored archive is missing: $target_archive"
  printf 'Dependency %s is already consistently pinned to %s\n' "$dependency" "$target_version"
  exit 0
fi

DEPENDENCY="$dependency" TARGET_VERSION="$target_version" yq -i '(.dependencies[] | select(.name == strenv(DEPENDENCY))).version = strenv(TARGET_VERSION)' "$chart_file"
helm dependency update "$wrapper"
helm lint "$wrapper"

[[ $(DEPENDENCY="$dependency" yq -er '.dependencies[] | select(.name == strenv(DEPENDENCY)) | .version' "$chart_file") == "$target_version" ]] || fail "Chart.yaml does not contain the requested dependency version"
[[ -f "$lock_file" ]] || fail "helm dependency update did not produce Chart.lock"
locked_version=$(DEPENDENCY="$dependency" yq -er '.dependencies[] | select(.name == strenv(DEPENDENCY)) | .version' "$lock_file") || fail "Chart.lock does not contain dependency '$dependency'"
[[ "$locked_version" == "$target_version" ]] || fail "Chart.lock does not contain the requested dependency version"
[[ -f "$target_archive" ]] || fail "helm dependency update did not produce $target_archive"

chart_relative=${chart_file#"$checkout/"}
lock_relative=${lock_file#"$checkout/"}
archives_relative=${wrapper#"$checkout/"}/charts
mapfile -d '' -t changed_paths < <(git -C "$checkout" diff --name-only -z)
mapfile -d '' -t untracked_paths < <(git -C "$checkout" ls-files --others --exclude-standard -z)
changed_paths+=("${untracked_paths[@]}")
for path in "${changed_paths[@]}"; do
  case "$path" in
    "$chart_relative" | "$lock_relative" | "$archives_relative/$dependency-"*.tgz) ;;
    *) fail "helm dependency update changed unexpected path: $path" ;;
  esac
done

for path in "${changed_paths[@]}"; do
  if [[ -e "$checkout/$path" ]]; then
    git -C "$checkout" add -- "$path"
  else
    git -C "$checkout" add -u -- "$path"
  fi
done

message="feat: update umbrella chart for $chart_name in $environment environment for chart version $target_version"
git -C "$checkout" config user.name 'github-actions[bot]'
git -C "$checkout" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git -C "$checkout" -c commit.gpgsign=false commit -m "$message"
git -C "$checkout" push origin "HEAD:refs/heads/${INPUT_TARGET_REF:-main}"
