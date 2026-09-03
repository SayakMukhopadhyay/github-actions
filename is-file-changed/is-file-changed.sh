#!/usr/bin/env bash

set -euo pipefail

fail() {
	printf '::error::%s\n' "$*" >&2
	exit 1
}

workspace=${GITHUB_WORKSPACE:-$PWD}
cd -- "$workspace"
diff_file=$(mktemp "${RUNNER_TEMP:-/tmp}/changed-paths.XXXXXX")
trap 'rm -f -- "$diff_file"' EXIT

pattern=${INPUT_PATTERN:?pattern is required}
if printf '' | grep -Eq -- "$pattern"; then
	:
else
	status=$?
	[[ $status -ne 2 ]] || fail "invalid POSIX extended regular expression: $pattern"
fi

ensure_commit() {
	local sha=$1 label=$2 attempt
	git cat-file -e "$sha^{commit}" 2>/dev/null && return 0
	for attempt in 1 2; do
		if git fetch --no-tags --depth=1 origin "$sha" && git cat-file -e "$sha^{commit}" 2>/dev/null; then
			return 0
		fi
		printf 'Fetch attempt %s failed for %s commit %s\n' "$attempt" "$label" "$sha" >&2
	done
	fail "could not fetch $label commit $sha after 2 attempts; ensure the token can read the repository and the object still exists"
}

head=${HEAD_SHA:?HEAD_SHA is required}
base=${BASE_SHA:?BASE_SHA is required}
ensure_commit "$head" head
if [[ "$base" =~ ^0+$ ]]; then
	base=$(git hash-object -t tree /dev/null)
else
	ensure_commit "$base" base
fi

git diff --name-status -z --find-renames --find-copies --find-copies-harder "$base" "$head" >"$diff_file" || fail "Git could not compare $base and $head"

changed=false
matches() {
	printf '%s\n' "$1" | grep -Eq -- "$pattern"
}
while IFS= read -r -d '' status; do
	case "${status:0:1}" in
	R | C)
		IFS= read -r -d '' old_path || fail "truncated Git rename/copy record"
		IFS= read -r -d '' new_path || fail "truncated Git rename/copy record"
		if matches "$old_path" || matches "$new_path"; then
			changed=true
		fi
		;;
	*)
		IFS= read -r -d '' path || fail "truncated Git name-status record"
		matches "$path" && changed=true
		;;
	esac
done <"$diff_file"

printf 'changed=%s\n' "$changed" >>"$GITHUB_OUTPUT"
