#!/usr/bin/env bats

load test-helper

setup() {
	test_root=$(mktemp -d)
}

teardown() {
	rm -rf "$test_root"
}

@test "check-version validates canonical Go and Helm authorities" {
	run env GITHUB_WORKSPACE="$repo_root/tests/fixtures/go-chart" \
		INPUT_WORKING_DIRECTORY=. INPUT_HELM=true \
		bash "$repo_root/check-version/check-version.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Version metadata is consistent"* ]]
}

@test "check-version rejects prereleases and additional lines" {
	project="$test_root/project"
	mkdir -p "$project"
	printf '1.2.3-rc.1\n' >"$project/VERSION"
	run env GITHUB_WORKSPACE="$project" INPUT_WORKING_DIRECTORY=. INPUT_HELM=false \
		bash "$repo_root/check-version/check-version.sh"
	[ "$status" -ne 0 ]
	[[ "$output" == *"canonical MAJOR.MINOR.PATCH"* ]]

	printf '1.2.3\n\n' >"$project/VERSION"
	run env GITHUB_WORKSPACE="$project" INPUT_WORKING_DIRECTORY=. INPUT_HELM=false \
		bash "$repo_root/check-version/check-version.sh"
	[ "$status" -ne 0 ]
	[[ "$output" == *"exactly one line"* ]]
}

@test "check-version supports spaces and reports exact chart mismatches" {
	project="$test_root/project with spaces"
	cp -R "$repo_root/tests/fixtures/go-chart" "$project"
	sed -i 's/appVersion: "1.2.3"/appVersion: "9.9.9"/' "$project/charts/Chart.yaml"
	run env GITHUB_WORKSPACE="$project" INPUT_WORKING_DIRECTORY=. INPUT_HELM=true \
		bash "$repo_root/check-version/check-version.sh"
	[ "$status" -ne 0 ]
	[[ "$output" == *"$project/charts/Chart.yaml field appVersion mismatch"* ]]
	[[ "$output" == *"expected '1.2.3', got '9.9.9'"* ]]
}

@test "check-version validates the Go authority without Helm" {
	project="$test_root/go project"
	mkdir -p "$project"
	printf '1.2.3\n' >"$project/VERSION"
	run env GITHUB_WORKSPACE="$project" INPUT_WORKING_DIRECTORY=. INPUT_HELM=false \
		bash "$repo_root/check-version/check-version.sh"
	[ "$status" -eq 0 ]
}

@test "check-version rejects a working directory outside the checkout" {
	project="$test_root/project"
	mkdir -p "$project"
	run env GITHUB_WORKSPACE="$project" INPUT_WORKING_DIRECTORY=.. INPUT_HELM=false \
		bash "$repo_root/check-version/check-version.sh"
	[ "$status" -ne 0 ]
	[[ "$output" == *"escapes the checkout"* ]]
}
