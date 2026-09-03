#!/usr/bin/env bats

load test-helper

setup() {
	test_root=$(mktemp -d)
	repository="$test_root/repository"
	make_git_repo "$repository"
	printf 'initial\n' >"$repository/VERSION"
	printf 'keep\n' >"$repository/keep.txt"
	git -C "$repository" add .
	git -C "$repository" commit -q -m initial
	initial=$(git -C "$repository" rev-parse HEAD)
}

teardown() {
	rm -rf "$test_root"
}

detect() {
	local base=$1 head=$2 pattern=$3
	output_file="$test_root/output"
	: >"$output_file"
	run env GITHUB_WORKSPACE="$repository" GITHUB_OUTPUT="$output_file" INPUT_TOKEN=test-token BASE_SHA="$base" HEAD_SHA="$head" INPUT_PATTERN="$pattern" bash "$repo_root/is-file-changed/is-file-changed.sh"
}

@test "multi-commit ranges match exact paths" {
	printf 'middle\n' >"$repository/other.txt"
	git -C "$repository" add . && git -C "$repository" commit -q -m middle
	printf '1.2.3\n' >"$repository/VERSION"
	git -C "$repository" add . && git -C "$repository" commit -q -m version
	head=$(git -C "$repository" rev-parse HEAD)
	detect "$initial" "$head" '^VERSION$'
	[ "$status" -eq 0 ]
	grep -Fx 'changed=true' "$output_file"
}

@test "non-matching ranges return deterministic false" {
	printf 'changed\n' >"$repository/other.txt"
	git -C "$repository" add . && git -C "$repository" commit -q -m unrelated
	head=$(git -C "$repository" rev-parse HEAD)
	detect "$initial" "$head" '^(VERSION|charts/)'
	[ "$status" -eq 0 ]
	grep -Fx 'changed=false' "$output_file"
}

@test "renames match both old and new names and deletions match old names" {
	git -C "$repository" mv keep.txt 'new name;$(safe).txt'
	git -C "$repository" commit -q -m rename
	renamed=$(git -C "$repository" rev-parse HEAD)
	detect "$initial" "$renamed" '^keep\.txt$'
	[ "$status" -eq 0 ]
	grep -Fx 'changed=true' "$output_file"
	detect "$initial" "$renamed" '^new name;\$\(safe\)\.txt$'
	[ "$status" -eq 0 ]
	grep -Fx 'changed=true' "$output_file"

	git -C "$repository" rm -q 'new name;$(safe).txt'
	git -C "$repository" commit -q -m delete
	deleted=$(git -C "$repository" rev-parse HEAD)
	detect "$renamed" "$deleted" '^new name;\$\(safe\)\.txt$'
	[ "$status" -eq 0 ]
	grep -Fx 'changed=true' "$output_file"
}

@test "copies match both source and destination paths" {
	cp "$repository/keep.txt" "$repository/copied file.txt"
	git -C "$repository" add . && git -C "$repository" commit -q -m copy
	head=$(git -C "$repository" rev-parse HEAD)

	detect "$initial" "$head" '^keep\.txt$'
	[ "$status" -eq 0 ]
	grep -Fx 'changed=true' "$output_file"
	detect "$initial" "$head" '^copied file\.txt$'
	[ "$status" -eq 0 ]
	grep -Fx 'changed=true' "$output_file"
}

@test "initial pushes compare the complete root tree" {
	printf 'later\n' >"$repository/later.txt"
	git -C "$repository" add . && git -C "$repository" commit -q -m later
	head=$(git -C "$repository" rev-parse HEAD)
	detect 0000000000000000000000000000000000000000 "$head" '^VERSION$'
	[ "$status" -eq 0 ]
	grep -Fx 'changed=true' "$output_file"
}

@test "unrelated force-push endpoints compare trees directly" {
	git -C "$repository" checkout -q --orphan replacement
	git -C "$repository" rm -q -rf .
	printf 'replacement\n' >"$repository/replacement.txt"
	git -C "$repository" add . && git -C "$repository" commit -q -m replacement
	head=$(git -C "$repository" rev-parse HEAD)
	detect "$initial" "$head" '^VERSION$'
	[ "$status" -eq 0 ]
	grep -Fx 'changed=true' "$output_file"
}

@test "invalid regular expressions fail instead of returning false" {
	head=$(git -C "$repository" rev-parse HEAD)
	detect "$initial" "$head" '['
	[ "$status" -ne 0 ]
	[[ "$output" == *"invalid POSIX"* ]]
}

@test "missing endpoints fail closed with an actionable diagnostic" {
	head=$(git -C "$repository" rev-parse HEAD)
	detect 1111111111111111111111111111111111111111 "$head" '^VERSION$'
	[ "$status" -ne 0 ]
	[[ "$output" == *"could not fetch base commit"* ]]
	[[ "$output" == *"ensure the token can read the repository"* ]]
}
