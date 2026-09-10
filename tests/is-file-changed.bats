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
	run env GITHUB_WORKSPACE="$repository" GITHUB_OUTPUT="$output_file" EVENT_NAME=push BASE_SHA="$base" HEAD_SHA="$head" INPUT_PATTERN="$pattern" bash "$repo_root/tests/fixtures/core-actions/run-is-file-changed.sh" "$repo_root"
}

detect_explicit() {
	local base=$1 head=$2 pattern=$3
	output_file="$test_root/output"
	: >"$output_file"
	run env GITHUB_WORKSPACE="$repository" GITHUB_OUTPUT="$output_file" EVENT_NAME=workflow_dispatch BASE_REF="$base" HEAD_REF="$head" INPUT_PATTERN="$pattern" bash "$repo_root/tests/fixtures/core-actions/run-is-file-changed.sh" "$repo_root"
}

validate_range() {
	local base=$1 head=$2
	run env EVENT_NAME=workflow_dispatch BASE_REF="$base" HEAD_REF="$head" bash "$repo_root/is-file-changed/collect-changed-files.sh" validate
}

changed_value() {
	awk '
		/^changed=/ { print substr($0, length("changed=") + 1); exit }
		/^changed<</ {
			delimiter = substr($0, index($0, "<<") + 2)
			collecting = 1
			next
		}
		collecting && $0 == delimiter { exit }
		collecting { print }
	' "$output_file"
}

assert_changed() {
	[[ "$(changed_value)" == "$1" ]]
}

@test "multi-commit ranges match exact paths" {
	printf 'middle\n' >"$repository/other.txt"
	git -C "$repository" add . && git -C "$repository" commit -q -m middle
	printf '1.2.3\n' >"$repository/VERSION"
	git -C "$repository" add . && git -C "$repository" commit -q -m version
	head=$(git -C "$repository" rev-parse HEAD)
	detect "$initial" "$head" '^VERSION$'
	[ "$status" -eq 0 ]
	assert_changed true
}

@test "explicit refs compare complete multi-commit ranges outside push events" {
	printf 'middle\n' >"$repository/other.txt"
	git -C "$repository" add . && git -C "$repository" commit -q -m middle
	printf '1.2.3\n' >"$repository/VERSION"
	git -C "$repository" add . && git -C "$repository" commit -q -m version
	head=$(git -C "$repository" rev-parse HEAD)

	detect_explicit "$initial" "$head" '^VERSION$'
	[ "$status" -eq 0 ]
	assert_changed true
}

@test "explicit stable tag bases resolve as commits" {
	git -C "$repository" tag chart-v1.2.3 "$initial"
	printf '1.2.3\n' >"$repository/VERSION"
	git -C "$repository" add . && git -C "$repository" commit -q -m version
	head=$(git -C "$repository" rev-parse HEAD)

	detect_explicit chart-v1.2.3 "$head" '^VERSION$'
	[ "$status" -eq 0 ]
	assert_changed true
}

@test "non-matching ranges return deterministic false" {
	printf 'changed\n' >"$repository/other.txt"
	git -C "$repository" add . && git -C "$repository" commit -q -m unrelated
	head=$(git -C "$repository" rev-parse HEAD)
	detect "$initial" "$head" '^(VERSION|charts/)'
	[ "$status" -eq 0 ]
	assert_changed false
}

@test "renames match both old and new names and deletions match old names" {
	git -C "$repository" mv keep.txt 'new name;$(safe).txt'
	git -C "$repository" commit -q -m rename
	renamed=$(git -C "$repository" rev-parse HEAD)
	detect "$initial" "$renamed" '^keep\.txt$'
	[ "$status" -eq 0 ]
	assert_changed true
	detect "$initial" "$renamed" '^new name;\$\(safe\)\.txt$'
	[ "$status" -eq 0 ]
	assert_changed true

	git -C "$repository" rm -q 'new name;$(safe).txt'
	git -C "$repository" commit -q -m delete
	deleted=$(git -C "$repository" rev-parse HEAD)
	detect "$renamed" "$deleted" '^new name;\$\(safe\)\.txt$'
	[ "$status" -eq 0 ]
	assert_changed true
}

@test "copies match both source and destination paths" {
	cp "$repository/keep.txt" "$repository/copied file.txt"
	git -C "$repository" add . && git -C "$repository" commit -q -m copy
	head=$(git -C "$repository" rev-parse HEAD)

	detect "$initial" "$head" '^keep\.txt$'
	[ "$status" -eq 0 ]
	assert_changed true
	detect "$initial" "$head" '^copied file\.txt$'
	[ "$status" -eq 0 ]
	assert_changed true
}

@test "initial pushes compare the complete root tree" {
	printf 'later\n' >"$repository/later.txt"
	git -C "$repository" add . && git -C "$repository" commit -q -m later
	head=$(git -C "$repository" rev-parse HEAD)
	detect 0000000000000000000000000000000000000000 "$head" '^VERSION$'
	[ "$status" -eq 0 ]
	assert_changed true
}

@test "unrelated force-push endpoints compare trees directly" {
	git -C "$repository" checkout -q --orphan replacement
	git -C "$repository" rm -q -rf .
	printf 'replacement\n' >"$repository/replacement.txt"
	git -C "$repository" add . && git -C "$repository" commit -q -m replacement
	head=$(git -C "$repository" rev-parse HEAD)
	detect "$initial" "$head" '^VERSION$'
	[ "$status" -eq 0 ]
	assert_changed true
}

@test "invalid JavaScript regular expressions fail instead of returning false" {
	head=$(git -C "$repository" rev-parse HEAD)
	detect "$initial" "$head" '['
	[ "$status" -ne 0 ]
	[[ "$output" == *"invalid JavaScript"* ]]
}

@test "missing endpoints fail closed with an actionable diagnostic" {
	head=$(git -C "$repository" rev-parse HEAD)
	detect 1111111111111111111111111111111111111111 "$head" '^VERSION$'
	[ "$status" -ne 0 ]
	[[ "$output" == *"could not resolve or fetch base ref"* ]]
	[[ "$output" == *"ensure the token can read the repository"* ]]
}

@test "explicit refs must be a complete pair" {
	validate_range "$initial" ''
	[ "$status" -ne 0 ]
	[[ "$output" == *"base-ref and head-ref must be provided together"* ]]

	validate_range '' "$initial"
	[ "$status" -ne 0 ]
	[[ "$output" == *"base-ref and head-ref must be provided together"* ]]
}

@test "explicit refs reject invalid syntax and zero head IDs" {
	validate_range 'chart-v1.2.3^{commit}' "$initial"
	[ "$status" -ne 0 ]
	[[ "$output" == *"base-ref must be a full commit object ID or valid Git ref"* ]]

	validate_range "$initial" 0000000000000000000000000000000000000000
	[ "$status" -ne 0 ]
	[[ "$output" == *"head-ref must not be a zero object ID"* ]]
}

@test "explicit refs reject missing commit objects" {
	detect_explicit 1111111111111111111111111111111111111111 "$initial" '^VERSION$'
	[ "$status" -ne 0 ]
	[[ "$output" == *"could not resolve or fetch base ref"* ]]
}
