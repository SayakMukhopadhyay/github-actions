#!/usr/bin/env bats

load test-helper

setup() {
	test_root=$(mktemp -d)
}

teardown() {
	rm -rf "$test_root"
}

@test "container preparation derives the reference without executing inputs" {
	output_file="$test_root/output"
	marker="$test_root/executed"
	component='server;$(touch '"$marker"')'
	run env GITHUB_OUTPUT="$output_file" SOURCE_REPOSITORY=Owner/Project \
		INPUT_VERSION=build-abc INPUT_COMPONENT="$component" INPUT_REGISTRY=ghcr.io \
		INPUT_IMAGE_REPOSITORY='' bash "$repo_root/container-build-push/prepare.sh"
	[ "$status" -eq 0 ]
	[ ! -e "$marker" ]
	grep -F 'image-reference=ghcr.io/owner/project/server;$(touch ' "$output_file"
}
