#!/usr/bin/env bash

set -euo pipefail

fail() {
	printf '::error::%s\n' "$*" >&2
	exit 1
}

development=${INPUT_DEVELOPMENT:-false}
push=${INPUT_PUSH:-true}
registry=${INPUT_REGISTRY:-ghcr.io}
repository=${INPUT_REPOSITORY:-}
[[ -n "$repository" ]] || repository="${REPOSITORY_OWNER:?github.repository_owner is required}/charts"

workspace=${GITHUB_WORKSPACE:-$PWD}
workspace=$(realpath -e -- "$workspace")
chart=$(realpath -e -- "$workspace/${INPUT_WORKING_DIRECTORY:-.}/charts") || fail "chart directory does not exist"
[[ "$chart" == "$workspace/"* ]] || fail "working-directory escapes the checkout"
cd -- "$chart"

command -v yq >/dev/null || fail "yq v4 is required"
[[ $(yq --version) =~ version[[:space:]]+v?4\. ]] || fail "yq v4 is required"
[[ $(awk 'END { print NR }' VERSION) -eq 1 ]] || fail "chart version file must contain exactly one line: $chart/VERSION"
chart_version=$(<VERSION)
[[ "$chart_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "chart version must be canonical MAJOR.MINOR.PATCH; got '$chart_version'"
chart_file_version=$(yq -er '.version' Chart.yaml) || fail "could not read Chart.yaml field version"
[[ "$chart_file_version" == "$chart_version" ]] || fail "Chart.yaml field version mismatch: expected '$chart_version', got '$chart_file_version'"
chart_name=$(yq -er '.name' Chart.yaml) || fail "could not read Chart.yaml field name"

if [[ "$development" == true ]]; then
	sha=${COMMIT_SHA:?github.sha is required}
	chart_version="$chart_version-${sha,,}"
fi
package_application_version=${INPUT_APP_VERSION:-}

while IFS=$'\t' read -r name url; do
	case "$url" in
	http://* | https://*) helm repo add "$name" "$url" ;;
	esac
done < <(yq -r '.dependencies[]? | [.name, .repository] | @tsv' Chart.yaml)

helm dependency build
helm lint .
package_arguments=(. --version "$chart_version")
if [[ -n "$package_application_version" ]]; then
	package_arguments+=(--app-version "$package_application_version")
fi
helm package "${package_arguments[@]}"
package_path="$chart_name-$chart_version.tgz"
[[ -f "$package_path" ]] || fail "Helm did not create the expected package: $chart/$package_path"

if [[ "$push" == true ]]; then
	helm push "$package_path" "oci://${registry,,}/${repository,,}"
fi

printf 'chart-name=%s\n' "$chart_name" >>"$GITHUB_OUTPUT"
printf 'chart-version=%s\n' "$chart_version" >>"$GITHUB_OUTPUT"
