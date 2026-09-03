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

bump() {
	local version=$1 increment=$2 major minor patch
	IFS=. read -r major minor patch <<<"$version"
	case "$increment" in
	major) printf '%s.0.0\n' "$((major + 1))" ;;
	minor) printf '%s.%s.0\n' "$major" "$((minor + 1))" ;;
	patch) printf '%s.%s.%s\n' "$major" "$minor" "$((patch + 1))" ;;
	*) fail "increment must be patch, minor, or major" ;;
	esac
}

replace_chart_scalar() {
	local file=$1 field=$2 value=$3
	[[ $(grep -Ec "^${field}:" "$file") -eq 1 ]] || fail "$file must contain exactly one top-level $field field"
	sed -i -E "s|^(${field}:[[:space:]]*)(['\"]?)[^'\"[:space:]#]+\\2(.*)$|\\1\\2${value}\\2\\3|" "$file"
	[[ $(yq -er ".${field}" "$file") == "$value" ]] || fail "could not update $file field $field"
}

increment=${INPUT_INCREMENT:-patch}
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
[[ -z "$(git status --porcelain)" ]] || fail "checkout is not clean before version mutation"

application_file="$project/VERSION"
application_version=$(read_version "$application_file" "application version")
new_application_version=$application_version

if [[ "$helm" == true ]]; then
	command -v yq >/dev/null || fail "yq v4 is required"
	[[ $(yq --version) =~ version[[:space:]]+v?4\. ]] || fail "yq v4 is required"
	chart_version_file="$project/charts/VERSION"
	chart_file="$project/charts/Chart.yaml"
	chart_version=$(read_version "$chart_version_file" "chart version")
	[[ $(yq -er '.version' "$chart_file") == "$chart_version" ]] || fail "$chart_file field version does not match $chart_version_file"
	[[ $(yq -er '.appVersion' "$chart_file") == "$application_version" ]] || fail "$chart_file field appVersion does not match $application_file"
fi

declare -a expected=()
if [[ "$go" == true ]]; then
	new_application_version=$(bump "$application_version" "$increment")
	printf '%s\n' "$new_application_version" >"$application_file"
	expected+=("$(realpath --relative-to="$workspace" "$application_file")")
fi

if [[ "$helm" == true ]]; then
	new_chart_version=$(bump "$chart_version" "$increment")
	printf '%s\n' "$new_chart_version" >"$chart_version_file"
	replace_chart_scalar "$chart_file" version "$new_chart_version"
	if [[ "$go" == true ]]; then
		replace_chart_scalar "$chart_file" appVersion "$new_application_version"
	fi
	expected+=("$(realpath --relative-to="$workspace" "$chart_version_file")")
	expected+=("$(realpath --relative-to="$workspace" "$chart_file")")
fi

git add -- "${expected[@]}"

if [[ "$helm" == true && "$go" == true ]]; then
	message="feat: bump chart version to $new_chart_version and app version to $new_application_version"
elif [[ "$helm" == true ]]; then
	message="feat: bump chart version to $new_chart_version"
else
	message="feat: bump app version to $new_application_version"
fi
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git -c commit.gpgsign=false commit -m "$message"

ref=${TARGET_REF:?current branch is required}
git push origin "HEAD:refs/heads/$ref"
