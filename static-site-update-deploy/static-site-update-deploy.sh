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
image_version=${INPUT_IMAGE_VERSION:?image-version is required}
target_ref=${INPUT_TARGET_REF:-main}
tag_pattern='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
[[ "$image_version" =~ $tag_pattern ]] || fail "image-version must be a valid container image tag"
git check-ref-format --branch "$target_ref" > /dev/null || fail "target-ref must be a valid branch name"

for value in "$environment" "$chart_name"; do
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || fail "environment and chart-name must not contain line breaks"
done

wrapper_relative=${INPUT_WRAPPER_CHART_PATH:-}
[[ -n "$wrapper_relative" ]] || wrapper_relative="$chart_name/envs/$environment"
wrapper=$(realpath -e -- "$checkout/$wrapper_relative") || fail "wrapper chart does not exist: $wrapper_relative"
[[ "$wrapper" == "$checkout/"* ]] || fail "wrapper-chart-path escapes the target checkout"
chart_file=$(realpath -e -- "$wrapper/Chart.yaml") || fail "wrapper Chart.yaml does not exist: $wrapper_relative/Chart.yaml"
values_file=$(realpath -e -- "$wrapper/values.yaml") || fail "wrapper values.yaml does not exist: $wrapper_relative/values.yaml"
[[ "$chart_file" == "$checkout/"* && "$values_file" == "$checkout/"* ]] || fail "wrapper files escape the target checkout"

dependency_count=$(yq -er '[.dependencies[]? | select(.name == "static-sites")] | length' "$chart_file") || fail "could not inspect dependencies in $chart_file"
[[ "$dependency_count" == 1 ]] || fail "$chart_file must contain exactly one dependency named 'static-sites'; found $dependency_count"
dependency_alias=$(yq -er '.dependencies[] | select(.name == "static-sites") | .alias' "$chart_file") || fail "the static-sites dependency must define alias 'staticSites'"
[[ "$dependency_alias" == staticSites ]] || fail "the static-sites dependency must define alias 'staticSites'; found '$dependency_alias'"

yq -e '(.staticSites.image.tag | tag) == "!!str"' "$values_file" > /dev/null || fail "$values_file must contain a string at staticSites.image.tag"
current_version=$(yq -er '.staticSites.image.tag' "$values_file")
if [[ "$current_version" == "$image_version" ]]; then
  printf 'Static site %s is already pinned to image version %s in %s\n' "$chart_name" "$image_version" "$environment"
  exit 0
fi

IMAGE_VERSION="$image_version" yq -i '.staticSites.image.tag = strenv(IMAGE_VERSION)' "$values_file"
helm lint "$wrapper"

[[ $(yq -er '.staticSites.image.tag' "$values_file") == "$image_version" ]] || fail "values.yaml does not contain the requested image version"

values_relative=${values_file#"$checkout/"}
mapfile -d '' -t changed_paths < <(git -C "$checkout" diff --name-only -z)
mapfile -d '' -t untracked_paths < <(git -C "$checkout" ls-files --others --exclude-standard -z)
changed_paths+=("${untracked_paths[@]}")
[[ ${#changed_paths[@]} -gt 0 ]] || fail "updating staticSites.image.tag did not change the target repository"
for path in "${changed_paths[@]}"; do
  [[ "$path" == "$values_relative" ]] || fail "static-site update changed unexpected path: $path"
done

git -C "$checkout" add -- "$values_relative"
message="feat: update static site $chart_name in $environment environment to image version $image_version"
git -C "$checkout" config user.name 'github-actions[bot]'
git -C "$checkout" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git -C "$checkout" -c commit.gpgsign=false commit -m "$message"
git -C "$checkout" push origin "HEAD:refs/heads/$target_ref"
