#!/usr/bin/env bats

load test-helper

setup() {
	test_root=$(mktemp -d)
}

teardown() {
	rm -rf "$test_root"
}

checkout_dependency_validation() {
	yq -r '.runs.steps[] | select(.name == "Validate dependency configuration") | .run' \
		"$repo_root/checkout-dependencies/action.yaml"
}

@test "checkout dependencies requires at least one configured ecosystem" {
	validation=$(checkout_dependency_validation)
	run env INPUT_GO_VERSION='' INPUT_NODE_VERSION='' INPUT_NODE_VERSION_FILE='' bash -c "$validation"
	[ "$status" -ne 0 ]
	[[ "$output" == *"configure at least one ecosystem"* ]]
}

@test "checkout dependencies rejects both Node version selectors" {
	validation=$(checkout_dependency_validation)
	run env INPUT_GO_VERSION='' INPUT_NODE_VERSION=24 INPUT_NODE_VERSION_FILE=.node-version bash -c "$validation"
	[ "$status" -ne 0 ]
	[[ "$output" == *"mutually exclusive"* ]]
}

@test "checkout dependencies accepts Go and either Node version selector" {
	validation=$(checkout_dependency_validation)
	run env INPUT_GO_VERSION=1.27 INPUT_NODE_VERSION=24 INPUT_NODE_VERSION_FILE='' bash -c "$validation"
	[ "$status" -eq 0 ]

	run env INPUT_GO_VERSION=1.27 INPUT_NODE_VERSION='' INPUT_NODE_VERSION_FILE=.node-version bash -c "$validation"
	[ "$status" -eq 0 ]
}

container_preparation() {
	yq -r '.runs.steps[] | select(.id == "prepare") | .run' "$repo_root/container-build-push/action.yaml"
}

@test "container preparation derives a normalized valid reference" {
	output_file="$test_root/output"
	preparation=$(container_preparation)
	run env GITHUB_OUTPUT="$output_file" SOURCE_REPOSITORY=Owner/Project \
		INPUT_VERSION=build-abc INPUT_COMPONENT=API-Service INPUT_REGISTRY=GHCR.IO \
		INPUT_IMAGE_REPOSITORY='' bash -c "$preparation"
	[ "$status" -eq 0 ]
	grep -Fx 'image-reference=ghcr.io/owner/project/api-service:build-abc' "$output_file"
}

@test "container preparation rejects shell metacharacters in image path fields" {
	output_file="$test_root/output"
	marker="$test_root/executed"
	component='server;$(touch '"$marker"')'
	preparation=$(container_preparation)
	run env GITHUB_OUTPUT="$output_file" SOURCE_REPOSITORY=Owner/Project \
		INPUT_VERSION=build-abc INPUT_COMPONENT="$component" INPUT_REGISTRY=ghcr.io \
		INPUT_IMAGE_REPOSITORY='' bash -c "$preparation"
	[ "$status" -ne 0 ]
	[ ! -e "$marker" ]
	[ ! -s "$output_file" ]
}

@test "container preparation rejects output-protocol line injection" {
	output_file="$test_root/output"
	preparation=$(container_preparation)
	run env GITHUB_OUTPUT="$output_file" SOURCE_REPOSITORY=Owner/Project \
		INPUT_VERSION=$'build-abc\ninjected=value' INPUT_COMPONENT=server INPUT_REGISTRY=ghcr.io \
		INPUT_IMAGE_REPOSITORY='' bash -c "$preparation"
	[ "$status" -ne 0 ]
	[ ! -s "$output_file" ]
}

@test "container preparation rejects carriage returns" {
	output_file="$test_root/output"
	preparation=$(container_preparation)
	run env GITHUB_OUTPUT="$output_file" SOURCE_REPOSITORY=Owner/Project \
		INPUT_VERSION=build-abc INPUT_COMPONENT=server INPUT_REGISTRY=ghcr.io \
		INPUT_IMAGE_REPOSITORY=$'owner/project\rinjected=value' bash -c "$preparation"
	[ "$status" -ne 0 ]
	[ ! -s "$output_file" ]
}
