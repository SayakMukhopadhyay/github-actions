#!/usr/bin/env bash

set -euo pipefail

fail() {
	printf '::error::%s\n' "$*" >&2
	exit 1
}

read_version() {
	local file=$1 label=$2 value
	[[ -f "$file" ]] || fail "$label file does not exist: $file"
	[[ $(awk 'END { print NR }' "$file") -eq 1 ]] || fail "$label file must contain exactly one line: $file"
	value=$(<"$file")
	[[ "$value" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "$label in $file must be canonical MAJOR.MINOR.PATCH; got '$value'"
	printf '%s\n' "$value"
}

helm=${INPUT_HELM:-false}
workspace=${GITHUB_WORKSPACE:-$PWD}
workspace=$(realpath -e -- "$workspace")
project=$(realpath -e -- "$workspace/${INPUT_WORKING_DIRECTORY:-.}") || fail "working-directory does not exist"
[[ "$project" == "$workspace" || "$project" == "$workspace/"* ]] || fail "working-directory escapes the checkout"
application_file="$project/VERSION"
application_version=$(read_version "$application_file" "application version")

if [[ "$helm" == true ]]; then
	command -v yq >/dev/null || fail "yq v4 is required"
	[[ $(yq --version) =~ version[[:space:]]+v?4\. ]] || fail "yq v4 is required"
	chart_version_file="$project/charts/VERSION"
	chart_file="$project/charts/Chart.yaml"
	chart_version=$(read_version "$chart_version_file" "chart version")
	actual_chart_version=$(yq -er '.version' "$chart_file") || fail "could not read $chart_file field version"
	actual_application_version=$(yq -er '.appVersion' "$chart_file") || fail "could not read $chart_file field appVersion"
	[[ "$actual_chart_version" == "$chart_version" ]] || fail "$chart_file field version mismatch: expected '$chart_version', got '$actual_chart_version'"
	[[ "$actual_application_version" == "$application_version" ]] || fail "$chart_file field appVersion mismatch: expected '$application_version', got '$actual_application_version'"
fi

printf 'Version metadata is consistent\n'
