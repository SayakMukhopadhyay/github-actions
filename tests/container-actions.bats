#!/usr/bin/env bats

load test-helper

setup() {
	test_root=$(mktemp -d)
	mock_bin="$test_root/bin"
	docker_log="$test_root/docker-log"
	output_file="$test_root/github-output"
	mkdir -p "$mock_bin"
	cp "$repo_root/tests/fixtures/container-promote-bin/docker" "$mock_bin/docker"
	chmod +x "$mock_bin/docker"
}

teardown() {
	rm -rf "$test_root"
}

promotion_preparation() {
	yq -r '.runs.steps[] | select(.id == "prepare") | .run' "$repo_root/container-promote/action.yaml"
}

promotion_command() {
	yq -r '.runs.steps[] | select(.name == "Create target image tag") | .run' "$repo_root/container-promote/action.yaml"
}

@test "container promotion constructs one digest source and one target tag" {
	digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	preparation=$(promotion_preparation)
	run env GITHUB_OUTPUT="$output_file" SOURCE_REPOSITORY=Owner/Project \
		INPUT_SOURCE_DIGEST="$digest" INPUT_TAG=v1.2.3 INPUT_COMPONENT=API \
		INPUT_REGISTRY=GHCR.IO INPUT_IMAGE_REPOSITORY='' bash -c "$preparation"
	[ "$status" -eq 0 ]
	grep -Fx "source-reference=ghcr.io/owner/project/api@$digest" "$output_file"
	grep -Fx 'target-reference=ghcr.io/owner/project/api:v1.2.3' "$output_file"
}

@test "container promotion performs one registry-side digest-to-tag command without pulling or building" {
	digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	command=$(promotion_command)
	run env PATH="$mock_bin:$PATH" MOCK_DOCKER_LOG="$docker_log" \
		SOURCE_REFERENCE="ghcr.io/owner/project@$digest" TARGET_REFERENCE=ghcr.io/owner/project:v1.2.3 \
		bash -c "$command"
	[ "$status" -eq 0 ]
	grep -Fx "buildx imagetools create --prefer-index=false --tag ghcr.io/owner/project:v1.2.3 ghcr.io/owner/project@$digest" "$docker_log"
	! grep -Eq '(^| )(build|pull)( |$)' "$docker_log"
}

@test "container promotion propagates Docker command failures" {
	digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	command=$(promotion_command)
	run env PATH="$mock_bin:$PATH" MOCK_DOCKER_LOG="$docker_log" MOCK_DOCKER_STATUS=42 \
		SOURCE_REFERENCE="ghcr.io/owner/project@$digest" TARGET_REFERENCE=ghcr.io/owner/project:v1.2.3 \
		bash -c "$command"
	[ "$status" -eq 42 ]
}
