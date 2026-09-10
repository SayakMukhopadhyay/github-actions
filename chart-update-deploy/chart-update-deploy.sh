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
requested_dependency=${INPUT_DEPENDENCY:-$chart_name}
target_version=${INPUT_CHART_VERSION:-}
target_image_tag=${INPUT_IMAGE_TAG:-}
target_ref=${INPUT_TARGET_REF:-main}

[[ -n "$target_version" || -n "$target_image_tag" ]] || fail "at least one of chart-version or image-tag is required"
if [[ -n "$target_version" ]]; then
  [[ "$target_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$ ]] || fail "chart-version must be an exact semantic version"
fi
if [[ -n "$target_image_tag" ]]; then
  tag_pattern='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
  [[ "$target_image_tag" =~ $tag_pattern ]] || fail "image-tag must be a valid container image tag"
fi
[[ -n "$requested_dependency" && "$requested_dependency" != */* && "$requested_dependency" != *$'\n'* && "$requested_dependency" != *$'\r'* ]] || fail "dependency must be a chart name or alias"
git check-ref-format --branch "$target_ref" > /dev/null || fail "target-ref must be a valid branch name"

for value in "$environment" "$chart_name"; do
  [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || fail "environment and chart-name must be non-empty single-line values"
done

wrapper_relative=${INPUT_WRAPPER_CHART_PATH:-}
[[ -n "$wrapper_relative" ]] || wrapper_relative="$chart_name/envs/$environment"
wrapper=$(realpath -e -- "$checkout/$wrapper_relative") || fail "wrapper chart does not exist: $wrapper_relative"
[[ "$wrapper" == "$checkout/"* ]] || fail "wrapper-chart-path escapes the target checkout"
git -C "$checkout" config user.name 'github-actions[bot]'
git -C "$checkout" config user.email '41898282+github-actions[bot]@users.noreply.github.com'

emit_commit_sha() {
  local sha=$1
  [[ -n "${GITHUB_OUTPUT:-}" ]] || fail "GITHUB_OUTPUT is required"
  printf 'commit-sha=%s\n' "$sha" >> "$GITHUB_OUTPUT"
}

resolve_and_mutate() {
  chart_file=$(realpath -e -- "$wrapper/Chart.yaml") || fail "wrapper Chart.yaml does not exist: $wrapper_relative/Chart.yaml"
  [[ "$chart_file" == "$checkout/"* ]] || fail "wrapper Chart.yaml escapes the target checkout"
  lock_file="$wrapper/Chart.lock"

  dependency_count=$(REQUESTED_DEPENDENCY="$requested_dependency" yq -er '[.dependencies[]? | select(.name == strenv(REQUESTED_DEPENDENCY) or .alias == strenv(REQUESTED_DEPENDENCY))] | length' "$chart_file") || fail "could not inspect dependencies in $chart_file"
  [[ "$dependency_count" == 1 ]] || fail "$chart_file must contain exactly one dependency matching '$requested_dependency'; found $dependency_count"
  dependency_name=$(REQUESTED_DEPENDENCY="$requested_dependency" yq -er '.dependencies[] | select(.name == strenv(REQUESTED_DEPENDENCY) or .alias == strenv(REQUESTED_DEPENDENCY)) | .name' "$chart_file") || fail "selected dependency must have a name"
  dependency_alias=$(REQUESTED_DEPENDENCY="$requested_dependency" yq -er '.dependencies[] | select(.name == strenv(REQUESTED_DEPENDENCY) or .alias == strenv(REQUESTED_DEPENDENCY)) | .alias // ""' "$chart_file") || fail "could not inspect the selected dependency alias"
  [[ -n "$dependency_name" && "$dependency_name" != */* && "$dependency_name" != *$'\n'* && "$dependency_name" != *$'\r'* ]] || fail "selected dependency name is invalid"
  [[ "$dependency_alias" != */* && "$dependency_alias" != *$'\n'* && "$dependency_alias" != *$'\r'* ]] || fail "selected dependency alias is invalid"
  values_root=${dependency_alias:-$dependency_name}

  chart_relative=${chart_file#"$checkout/"}
  lock_relative=${lock_file#"$checkout/"}
  archives_relative=${wrapper#"$checkout/"}/charts
  values_relative=''
  protected_paths=("$chart_relative")

  if [[ -n "$target_version" ]]; then
    current_version=$(REQUESTED_DEPENDENCY="$requested_dependency" yq -er '.dependencies[] | select(.name == strenv(REQUESTED_DEPENDENCY) or .alias == strenv(REQUESTED_DEPENDENCY)) | .version' "$chart_file") || fail "selected dependency must have a version"
    target_archive="$wrapper/charts/$dependency_name-$target_version.tgz"
    protected_paths+=("$lock_relative")

    if [[ "$current_version" == "$target_version" ]]; then
      [[ -f "$lock_file" ]] || fail "Chart.yaml already requests $target_version, but Chart.lock is missing"
      locked_version=$(DEPENDENCY_NAME="$dependency_name" yq -er '.dependencies[] | select(.name == strenv(DEPENDENCY_NAME)) | .version' "$lock_file") || fail "Chart.lock does not contain dependency '$dependency_name'"
      [[ "$locked_version" == "$target_version" ]] || fail "Chart.yaml requests $target_version, but Chart.lock records $locked_version"
      [[ -f "$target_archive" ]] || fail "Chart.yaml requests $target_version, but vendored archive is missing: $target_archive"
      printf 'Dependency %s is already consistently pinned to %s\n' "$requested_dependency" "$target_version"
    else
      REQUESTED_DEPENDENCY="$requested_dependency" TARGET_VERSION="$target_version" yq -i '(.dependencies[] | select(.name == strenv(REQUESTED_DEPENDENCY) or .alias == strenv(REQUESTED_DEPENDENCY))).version = strenv(TARGET_VERSION)' "$chart_file"
      helm dependency update "$wrapper"

      [[ $(REQUESTED_DEPENDENCY="$requested_dependency" yq -er '.dependencies[] | select(.name == strenv(REQUESTED_DEPENDENCY) or .alias == strenv(REQUESTED_DEPENDENCY)) | .version' "$chart_file") == "$target_version" ]] || fail "Chart.yaml does not contain the requested dependency version"
      [[ -f "$lock_file" ]] || fail "helm dependency update did not produce Chart.lock"
      locked_version=$(DEPENDENCY_NAME="$dependency_name" yq -er '.dependencies[] | select(.name == strenv(DEPENDENCY_NAME)) | .version' "$lock_file") || fail "Chart.lock does not contain dependency '$dependency_name'"
      [[ "$locked_version" == "$target_version" ]] || fail "Chart.lock does not contain the requested dependency version"
      [[ -f "$target_archive" ]] || fail "helm dependency update did not produce $target_archive"
    fi
  fi

  if [[ -n "$target_image_tag" ]]; then
    values_file=$(realpath -e -- "$wrapper/values.yaml") || fail "wrapper values.yaml does not exist: $wrapper_relative/values.yaml"
    [[ "$values_file" == "$checkout/"* ]] || fail "wrapper values.yaml escapes the target checkout"
    values_relative=${values_file#"$checkout/"}
    protected_paths+=("$values_relative")
    VALUES_ROOT="$values_root" yq -e '(.[strenv(VALUES_ROOT)].image.tag | tag) == "!!str"' "$values_file" > /dev/null || fail "$values_file must contain a string at $values_root.image.tag"
    current_image_tag=$(VALUES_ROOT="$values_root" yq -er '.[strenv(VALUES_ROOT)].image.tag' "$values_file")
    if [[ "$current_image_tag" == "$target_image_tag" ]]; then
      printf 'Dependency %s is already pinned to image tag %s\n' "$requested_dependency" "$target_image_tag"
    else
      VALUES_ROOT="$values_root" TARGET_IMAGE_TAG="$target_image_tag" yq -i '.[strenv(VALUES_ROOT)].image.tag = strenv(TARGET_IMAGE_TAG)' "$values_file"
      [[ $(VALUES_ROOT="$values_root" yq -er '.[strenv(VALUES_ROOT)].image.tag' "$values_file") == "$target_image_tag" ]] || fail "values.yaml does not contain the requested image tag"
    fi
  fi

  helm lint "$wrapper"

  mapfile -d '' -t changed_paths < <(git -C "$checkout" diff --name-only -z)
  mapfile -d '' -t untracked_paths < <(git -C "$checkout" ls-files --others --exclude-standard -z)
  changed_paths+=("${untracked_paths[@]}")
  for path in "${changed_paths[@]}"; do
    allowed=false
    [[ "$path" == "$chart_relative" && -n "$target_version" ]] && allowed=true
    [[ "$path" == "$lock_relative" && -n "$target_version" ]] && allowed=true
    [[ -n "$values_relative" && "$path" == "$values_relative" ]] && allowed=true
    [[ -n "$target_version" && "$path" == "$archives_relative/$dependency_name-"*.tgz ]] && allowed=true
    [[ "$allowed" == true ]] || fail "wrapper update changed unexpected path: $path"
  done
}

commit_mutation() {
  local path
  for path in "${changed_paths[@]}"; do
    if [[ -e "$checkout/$path" ]]; then
      git -C "$checkout" add -- "$path"
    else
      git -C "$checkout" add -u -- "$path"
    fi
  done

  if [[ -n "$target_version" && -n "$target_image_tag" ]]; then
    message="feat: update umbrella chart for $chart_name in $environment environment for chart version $target_version and image tag $target_image_tag"
  elif [[ -n "$target_version" ]]; then
    message="feat: update umbrella chart for $chart_name in $environment environment for chart version $target_version"
  else
    message="feat: update umbrella chart for $chart_name in $environment environment for image tag $target_image_tag"
  fi
  git -C "$checkout" -c commit.gpgsign=false commit -m "$message"
}

remote_change_is_protected() {
  local changed=$1 protected
  for protected in "${protected_paths[@]}"; do
    [[ "$changed" == "$protected" ]] && return 0
  done
  [[ -n "$target_version" && "$changed" == "$archives_relative/$dependency_name-"*.tgz ]]
}

base_head=$(git -C "$checkout" rev-parse HEAD)
resolve_and_mutate
if [[ ${#changed_paths[@]} -eq 0 ]]; then
  emit_commit_sha "$base_head"
  exit 0
fi

commit_mutation
if git -C "$checkout" push origin "HEAD:refs/heads/$target_ref"; then
  emit_commit_sha "$(git -C "$checkout" rev-parse HEAD)"
  exit 0
fi

git -C "$checkout" fetch --no-tags origin "refs/heads/$target_ref" || fail "push failed and the target branch could not be refreshed"
remote_head=$(git -C "$checkout" rev-parse FETCH_HEAD)
[[ "$remote_head" != "$base_head" ]] || fail "push failed without a concurrent target branch update"
git -C "$checkout" merge-base --is-ancestor "$base_head" "$remote_head" || fail "target branch no longer descends from the checked-out base"

mapfile -d '' -t remote_changed_paths < <(git -C "$checkout" diff --name-only -z "$base_head" "$remote_head")
for path in "${remote_changed_paths[@]}"; do
  remote_change_is_protected "$path" && fail "concurrent update changed protected wrapper state: $path"
done

printf 'Target branch advanced with unrelated changes; refreshing and retrying once\n'
git -C "$checkout" switch --detach "$remote_head" > /dev/null
[[ -z "$(git -C "$checkout" status --porcelain)" ]] || fail "target checkout was not clean after refresh"
resolve_and_mutate
if [[ ${#changed_paths[@]} -eq 0 ]]; then
  emit_commit_sha "$remote_head"
  exit 0
fi

commit_mutation
git -C "$checkout" push origin "HEAD:refs/heads/$target_ref" || fail "bounded retry failed; the target branch may have changed again"
emit_commit_sha "$(git -C "$checkout" rev-parse HEAD)"
