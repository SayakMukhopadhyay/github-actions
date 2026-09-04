#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

workspace=$(realpath -e -- "${GITHUB_WORKSPACE:-$PWD}")
chart=$(realpath -e -- "${INPUT_CHART_DIRECTORY:?chart-directory is required}") || fail "chart directory does not exist"
[[ "$chart" == "$workspace" || "$chart" == "$workspace/"* ]] || fail "chart directory escapes the checkout"

repositories_file=$(realpath -e -- "${INPUT_REPOSITORIES_FILE:?repositories-file is required}") || fail "dependency repositories file does not exist"
runner_temp=$(realpath -e -- "${RUNNER_TEMP:?RUNNER_TEMP is required}")
[[ "$repositories_file" == "$runner_temp/"* ]] || fail "dependency repositories file escapes RUNNER_TEMP"

chart_name=${INPUT_CHART_NAME:?chart-name is required}
chart_version=${INPUT_CHART_VERSION:?chart-version is required}
[[ "$chart_name" != -* && "$chart_name" != */* && "$chart_name" != *$'\n'* ]] || fail "chart-name is unsafe"
[[ "$chart_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9a-f]{40})?$ ]] || fail "chart-version is invalid"

cd -- "$chart"
while IFS= read -r -d '' name; do
  IFS= read -r -d '' url || fail "dependency repositories file is truncated"
  [[ -n "$name" && "$name" != -* && "$name" != *$'\n'* ]] || fail "dependency repository name is unsafe"
  [[ "$url" == http://* || "$url" == https://* ]] || fail "dependency repository URL is unsafe"
  helm repo add "$name" "$url"
done < "$repositories_file"

helm dependency build
helm lint .
package_arguments=(. --version "$chart_version")
if [[ -n "${INPUT_APP_VERSION:-}" ]]; then
  package_arguments+=(--app-version "$INPUT_APP_VERSION")
fi
helm package "${package_arguments[@]}"

package_path="$chart_name-$chart_version.tgz"
[[ -f "$package_path" ]] || fail "Helm did not create the expected package: $chart/$package_path"

if [[ "${INPUT_PUSH:-true}" == true ]]; then
  registry=${INPUT_REGISTRY:-ghcr.io}
  repository=${INPUT_REPOSITORY:-}
  [[ -n "$repository" ]] || repository="${REPOSITORY_OWNER:?github.repository_owner is required}/charts"
  helm push "$package_path" "oci://${registry,,}/${repository,,}"
fi
