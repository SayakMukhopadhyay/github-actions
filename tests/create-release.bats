#!/usr/bin/env bats

load test-helper

setup() {
	unset MOCK_GH_MODE
	test_root=$(mktemp -d)
	repository="$test_root/repository"
	runner_temp="$test_root/runner-temp"
	output_file="$test_root/github-output"
	mock_bin="$repo_root/tests/fixtures/create-release-bin"
	mkdir -p "$runner_temp"
	: >"$output_file"
	chmod +x "$mock_bin/gh"

	make_git_repo "$repository"
	printf 'initial\n' >"$repository/release.txt"
	git -C "$repository" add release.txt
	git -C "$repository" commit -q -m 'Initial release'
	git -C "$repository" tag 'service/v1.0.0'

	printf 'mainline\n' >>"$repository/release.txt"
	git -C "$repository" add release.txt
	git -C "$repository" commit -q -m 'Direct mainline change'

	git -C "$repository" switch -q -c feature
	printf 'feature\n' >"$repository/feature.txt"
	git -C "$repository" add feature.txt
	git -C "$repository" commit -q -m 'Nested feature detail'
	git -C "$repository" switch -q main
	git -C "$repository" merge -q --no-ff feature -m 'Merge feature safely'
	git -C "$repository" tag 'service/v1.1.0'
	git -C "$repository" tag 'other/v9.9.9'
}

teardown() {
	rm -rf "$test_root"
}

collect_context() {
	: >"$output_file"
	run env \
		GITHUB_WORKSPACE="$repository" \
		GITHUB_OUTPUT="$output_file" \
		RUNNER_TEMP="$runner_temp" \
		INPUT_TAG_NAME="${1:-service/v1.1.0}" \
		TARGET_REPOSITORY=Owner/Project \
		TARGET_SERVER_URL=https://github.example \
		bash "$repo_root/create-release/collect-git-context.sh"
}

read_action_output() {
	local name=$1
	sed -n "s/^${name}=//p" "$output_file"
}

prepare_publisher() {
	collect_context
	[ "$status" -eq 0 ]
	facts_file=$(read_action_output facts-file)
	body_file=$(read_action_output body-file)
	printf 'Validated release body.\n' >"$body_file"

	export MOCK_GH_CALLS="$test_root/gh-calls"
	export MOCK_GH_ENV="$test_root/gh-env"
	export MOCK_RELEASE_STATE="$test_root/release-state.json"
	export MOCK_RELEASE_FIXTURE="$test_root/release-fixture.json"
	export MOCK_CREATE_REQUEST="$test_root/create-request.json"
	export MOCK_TARGET_TAG=service/v1.1.0
	export MOCK_TARGET_OBJECT
	MOCK_TARGET_OBJECT=$(git -C "$repository" rev-parse refs/tags/service/v1.1.0)
	export MOCK_PREVIOUS_TAG=service/v1.0.0
	export MOCK_PREVIOUS_OBJECT
	MOCK_PREVIOUS_OBJECT=$(git -C "$repository" rev-parse refs/tags/service/v1.0.0)
	export MOCK_TARGET_TYPE=${MOCK_TARGET_TYPE:-commit}
	export MOCK_PREVIOUS_TYPE=${MOCK_PREVIOUS_TYPE:-commit}
	printf '%s\n' \
		'{"id":42,"html_url":"https://github.example/Owner/Project/releases/tag/service%2Fv1.1.0","upload_url":"https://uploads.github.example/releases/42/assets{?name,label}"}' \
		>"$MOCK_RELEASE_FIXTURE"
	: >"$MOCK_GH_CALLS"
	: >"$MOCK_GH_ENV"
	: >"$output_file"
}

run_publisher() {
	local mode=$1
	run env \
		PATH="$mock_bin:$PATH" \
		GITHUB_OUTPUT="$output_file" \
		RUNNER_TEMP="$runner_temp" \
		INPUT_TOKEN=github-secret \
		INPUT_RELEASE_NAME='Service 1.1.0' \
		FACTS_FILE="$facts_file" \
		BODY_FILE="$body_file" \
		PUBLISH_MODE="$mode" \
		MOCK_GH_CALLS="$MOCK_GH_CALLS" \
		MOCK_GH_ENV="$MOCK_GH_ENV" \
		MOCK_RELEASE_STATE="$MOCK_RELEASE_STATE" \
		MOCK_RELEASE_FIXTURE="$MOCK_RELEASE_FIXTURE" \
		MOCK_CREATE_REQUEST="$MOCK_CREATE_REQUEST" \
		MOCK_TARGET_TAG="$MOCK_TARGET_TAG" \
		MOCK_TARGET_OBJECT="$MOCK_TARGET_OBJECT" \
		MOCK_PREVIOUS_TAG="$MOCK_PREVIOUS_TAG" \
		MOCK_PREVIOUS_OBJECT="$MOCK_PREVIOUS_OBJECT" \
		MOCK_TARGET_TYPE="$MOCK_TARGET_TYPE" \
		MOCK_PREVIOUS_TYPE="$MOCK_PREVIOUS_TYPE" \
		bash "$repo_root/create-release/publish-release.sh"
}

@test "collector selects the previous tag in the same family and uses first-parent commits" {
	collect_context
	[ "$status" -eq 0 ]

	facts_file=$(read_action_output facts-file)
	context_file=$(read_action_output context-file)
	[ "$(jq -r '.tagName' "$facts_file")" = service/v1.1.0 ]
	[ "$(jq -r '.previousTag' "$facts_file")" = service/v1.0.0 ]
	[ "$(jq -r '.commits | length' "$facts_file")" -eq 2 ]
	jq -e '.commits | map(.subject) == ["Direct mainline change", "Merge feature safely"]' "$facts_file"
	! grep -F 'Nested feature detail' "$context_file"
	grep -F 'BEGIN UNTRUSTED REPOSITORY DATA' "$context_file"
	grep -F 'END UNTRUSTED REPOSITORY DATA' "$context_file"
}

@test "collector chooses semantic versions rather than lexical tag order" {
	git -C "$repository" tag 'service/v1.9.0' HEAD~1
	git -C "$repository" tag 'service/v1.10.0'

	collect_context service/v1.10.0
	[ "$status" -eq 0 ]
	facts_file=$(read_action_output facts-file)
	[ "$(jq -r '.previousTag' "$facts_file")" = service/v1.9.0 ]
}

@test "collector supports an initial release without a previous family tag" {
	collect_context other/v9.9.9
	[ "$status" -eq 0 ]
	facts_file=$(read_action_output facts-file)
	[ "$(jq -r '.previousTag' "$facts_file")" = null ]
	[ "$(jq -r '.commits | length' "$facts_file")" -gt 0 ]
}

@test "collector rejects a selected previous tag outside first-parent history" {
	empty_tree=$(git -C "$repository" hash-object -t tree -w /dev/null)
	unrelated_commit=$(printf 'Unrelated release\n' | git -C "$repository" commit-tree "$empty_tree")
	git -C "$repository" tag 'service/v1.0.5' "$unrelated_commit"

	collect_context
	[ "$status" -ne 0 ]
	[[ "$output" == *"not on the target commit first-parent history"* ]]
}

@test "collector rejects noncanonical tags and a checkout that does not match the tag" {
	git -C "$repository" tag 'service/v1.02.0'
	collect_context service/v1.02.0
	[ "$status" -ne 0 ]
	[[ "$output" == *"canonical MAJOR.MINOR.PATCH"* ]]

	git -C "$repository" checkout -q service/v1.0.0
	collect_context service/v1.1.0
	[ "$status" -ne 0 ]
	[[ "$output" == *"checkout HEAD does not match"* ]]
}

@test "collector bounds untrusted context and records omitted mainline commits" {
	fast_import="$test_root/many-commits.fast-import"
	parent=$(git -C "$repository" rev-parse main)
	: >"$fast_import"
	for number in $(seq 1 50); do
		{
			printf 'commit refs/heads/main\n'
			printf 'mark :%s\n' "$number"
			printf 'author Tester <tester@example.com> %s +0000\n' "$((100000 + number))"
			printf 'committer Tester <tester@example.com> %s +0000\n' "$((100000 + number))"
			printf 'data <<MESSAGE\nMainline change %s\nMESSAGE\n' "$number"
			if ((number == 1)); then
				printf 'from %s\n\n' "$parent"
			else
				printf 'from :%s\n\n' "$((number - 1))"
			fi
		} >>"$fast_import"
	done
	git -C "$repository" fast-import --quiet <"$fast_import"
	git -C "$repository" reset -q --hard main
	git -C "$repository" tag 'service/v1.2.0'

	collect_context service/v1.2.0
	[ "$status" -eq 0 ]
	facts_file=$(read_action_output facts-file)
	context_file=$(read_action_output context-file)
	[ "$(jq -r '.commits | length' "$facts_file")" -eq 48 ]
	[ "$(jq -r '.omittedCommitCount' "$facts_file")" -eq 2 ]
	[ "$(wc -c <"$context_file")" -le 60000 ]
}

@test "collector preserves annotated tag objects separately from peeled commits" {
	git -C "$repository" tag -d service/v1.0.0 service/v1.1.0 >/dev/null
	git -C "$repository" tag -a -m 'Annotated previous' service/v1.0.0 HEAD~2
	git -C "$repository" tag -a -m 'Annotated target' service/v1.1.0 HEAD

	collect_context
	[ "$status" -eq 0 ]
	facts_file=$(read_action_output facts-file)
	[ "$(jq -r '.targetObject' "$facts_file")" = "$(git -C "$repository" rev-parse refs/tags/service/v1.1.0)" ]
	[ "$(jq -r '.targetCommit' "$facts_file")" = "$(git -C "$repository" rev-parse refs/tags/service/v1.1.0^{commit})" ]
	[ "$(jq -r '.previousObject' "$facts_file")" = "$(git -C "$repository" rev-parse refs/tags/service/v1.0.0)" ]
}

@test "publisher preflight returns an existing release without creating another" {
	prepare_publisher
	cp "$MOCK_RELEASE_FIXTURE" "$MOCK_RELEASE_STATE"

	run_publisher check
	[ "$status" -eq 0 ]
	grep -Fx 'release-exists=true' "$output_file"
	grep -Fx 'release-id=42' "$output_file"
	! grep -F 'POST repos/Owner/Project/releases' "$MOCK_GH_CALLS"
	grep -Fx 'github-token=github-secret openai-key=' "$MOCK_GH_ENV"
}

@test "publisher creates one release from the validated body and writes all outputs" {
	prepare_publisher

	run_publisher publish
	[ "$status" -eq 0 ]
	grep -Fx 'release-id=42' "$output_file"
	grep -Fx 'html-url=https://github.example/Owner/Project/releases/tag/service%2Fv1.1.0' "$output_file"
	grep -Fx 'upload-url=https://uploads.github.example/releases/42/assets{?name,label}' "$output_file"
	[ "$(jq -r '.tag_name' "$MOCK_CREATE_REQUEST")" = service/v1.1.0 ]
	[ "$(jq -r '.name' "$MOCK_CREATE_REQUEST")" = 'Service 1.1.0' ]
	[ "$(jq -r '.body' "$MOCK_CREATE_REQUEST")" = 'Validated release body.' ]
	jq -e '.draft == false and .prerelease == false and .generate_release_notes == false' "$MOCK_CREATE_REQUEST"
	grep -Fx 'github-token=github-secret openai-key=' "$MOCK_GH_ENV"
}

@test "publisher treats concurrent release creation as an idempotent success" {
	prepare_publisher
	export MOCK_GH_MODE=race

	run_publisher publish
	[ "$status" -eq 0 ]
	[[ "$output" == *"created concurrently"* ]]
	grep -Fx 'release-id=42' "$output_file"
}

@test "publisher fails closed if the target tag moved before publication" {
	prepare_publisher
	export MOCK_TARGET_OBJECT
	MOCK_TARGET_OBJECT=$(printf 'f%.0s' {1..40})

	run_publisher publish
	[ "$status" -ne 0 ]
	[[ "$output" == *"remote tag moved"* ]]
	! grep -F 'POST repos/Owner/Project/releases' "$MOCK_GH_CALLS"
}

@test "publisher reverifies annotated target and previous tag objects" {
	git -C "$repository" tag -d service/v1.0.0 service/v1.1.0 >/dev/null
	git -C "$repository" tag -a -m 'Annotated previous' service/v1.0.0 HEAD~2
	git -C "$repository" tag -a -m 'Annotated target' service/v1.1.0 HEAD
	export MOCK_TARGET_TYPE=tag
	export MOCK_PREVIOUS_TYPE=tag
	prepare_publisher

	run_publisher check
	[ "$status" -eq 0 ]
	grep -Fx 'release-exists=false' "$output_file"

	prepare_publisher
	MOCK_PREVIOUS_OBJECT=$(printf 'e%.0s' {1..40})
	run_publisher publish
	[ "$status" -ne 0 ]
	[[ "$output" == *"previous remote tag moved"* ]]
	! grep -F 'POST repos/Owner/Project/releases' "$MOCK_GH_CALLS"
}

@test "always-run cleanup removes only a collector-owned release session" {
	collect_context
	[ "$status" -eq 0 ]
	session_directory=$(read_action_output session-directory)
	[ -d "$session_directory" ]

	run env RUNNER_TEMP="$runner_temp" SESSION_DIRECTORY="$session_directory" \
		INPUT_TOKEN=must-not-be-needed INPUT_OPENAI_API_KEY=must-not-be-needed \
		bash "$repo_root/create-release/cleanup-release-session.sh"
	[ "$status" -eq 0 ]
	[ ! -e "$session_directory" ]

	outside_directory="$test_root/create-release.outside"
	mkdir -p "$outside_directory"
	run env RUNNER_TEMP="$runner_temp" SESSION_DIRECTORY="$outside_directory" \
		bash "$repo_root/create-release/cleanup-release-session.sh"
	[ "$status" -ne 0 ]
	[ -d "$outside_directory" ]
}

@test "publisher rejects malformed GitHub responses and does not expose the OpenAI key" {
	prepare_publisher
	printf '%s\n' '{"id":"not-a-number","html_url":"javascript:bad","upload_url":"bad"}' >"$MOCK_RELEASE_STATE"

	run_publisher check
	[ "$status" -ne 0 ]
	[[ "$output" == *"could not check for an existing GitHub Release"* ]]
	grep -Fx 'github-token=github-secret openai-key=' "$MOCK_GH_ENV"
}
