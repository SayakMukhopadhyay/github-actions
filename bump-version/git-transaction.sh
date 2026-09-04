#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

mode=${1:?transaction mode is required}
if [[ "$mode" == check-clean ]]; then
  workspace=${GITHUB_WORKSPACE:-$PWD}
  workspace=$(realpath -e -- "$workspace")
  cd -- "$workspace"
  [[ -z "$(git status --porcelain)" ]] || fail "checkout is not clean before version mutation"
  exit 0
fi
[[ "$mode" == commit ]] || fail "transaction mode must be check-clean or commit"

helm=${INPUT_HELM:-false}
go=${INPUT_GO:-false}
if [[ "$helm" != true && "$go" != true ]]; then
  printf 'No version target was selected; nothing to do\n'
  exit 0
fi

workspace=${GITHUB_WORKSPACE:-$PWD}
workspace=$(realpath -e -- "$workspace")
project=$(realpath -e -- "$workspace/${INPUT_WORKING_DIRECTORY:-.}") || fail "working-directory does not exist"
[[ "$project" == "$workspace" || "$project" == "$workspace/"* ]] || fail "working-directory escapes the checkout"
cd -- "$workspace"

declare -a expected=()
if [[ "$go" == true ]]; then
  [[ "$NEW_APPLICATION_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "mutation did not produce a canonical application version"
  expected+=("$(realpath --relative-to="$workspace" "$project/VERSION")")
fi
if [[ "$helm" == true ]]; then
  [[ "$NEW_CHART_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "mutation did not produce a canonical chart version"
  expected+=("$(realpath --relative-to="$workspace" "$project/charts/VERSION")")
  expected+=("$(realpath --relative-to="$workspace" "$project/charts/Chart.yaml")")
fi

for path in "${expected[@]}"; do
  git diff --quiet -- "$path" && fail "expected version file was not changed: $path"
done

[[ -z "$(git ls-files --others --exclude-standard)" ]] || fail "unexpected untracked files appeared during version mutation"
git add -- "${expected[@]}"
git diff --quiet || fail "unexpected unstaged changes appeared during version mutation"

mapfile -d '' -t staged < <(git diff --cached --name-only -z)
[[ ${#staged[@]} -eq ${#expected[@]} ]] || fail "version mutation staged unexpected files"
declare -A expected_paths=()
for path in "${expected[@]}"; do
  expected_paths["$path"]=1
done
for path in "${staged[@]}"; do
  [[ -n "${expected_paths[$path]:-}" ]] || fail "version mutation staged an unexpected file: $path"
done

if [[ "$helm" == true && "$go" == true ]]; then
  message="feat: bump chart version to $NEW_CHART_VERSION and app version to $NEW_APPLICATION_VERSION"
elif [[ "$helm" == true ]]; then
  message="feat: bump chart version to $NEW_CHART_VERSION"
else
  message="feat: bump app version to $NEW_APPLICATION_VERSION"
fi

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git -c commit.gpgsign=false commit -m "$message"

ref=${TARGET_REF:?current branch is required}
git check-ref-format --branch "$ref" > /dev/null || fail "current branch is not a valid branch name"
git push origin "HEAD:refs/heads/$ref"
