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
		INPUT_PATHSPECS="${2-}" \
		TARGET_REPOSITORY=Owner/Project \
		TARGET_SERVER_URL=https://github.example \
		bash "$repo_root/create-release/collect-git-context.sh"
}

make_scoped_history() {
	local metachar_path='charts/templates/literal $(touch injected); [x].yaml'

	mkdir -p "$repository/charts/templates" "$repository/cmd" "$repository/src"
	printf 'old chart\n' >"$repository/charts/templates/old chart.yaml"
	printf 'old app\n' >"$repository/src/obsolete file.go"
	git -C "$repository" add charts cmd src
	git -C "$repository" commit -q -m 'Establish scoped baseline'
	git -C "$repository" tag 'scoped/v1.0.0'

	printf 'chart only\n' >"$repository/charts/templates/chart-only.yaml"
	git -C "$repository" add charts/templates/chart-only.yaml
	git -C "$repository" commit -q -m 'Update chart only'

	printf 'app only\n' >"$repository/cmd/server.go"
	git -C "$repository" add cmd/server.go
	git -C "$repository" commit -q -m 'Update application only'

	printf 'mixed chart\n' >"$repository/charts/templates/mixed.yaml"
	printf 'mixed app\n' >>"$repository/cmd/server.go"
	git -C "$repository" add charts/templates/mixed.yaml cmd/server.go
	git -C "$repository" commit -q -m 'Update chart and application together'

	git -C "$repository" mv 'charts/templates/old chart.yaml' 'charts/templates/new [chart].yaml'
	git -C "$repository" commit -q -m 'Rename chart template'

	git -C "$repository" rm -q 'src/obsolete file.go'
	git -C "$repository" commit -q -m 'Delete obsolete application file'

	printf 'literal metachar path\n' >"$repository/$metachar_path"
	git -C "$repository" add "$metachar_path"
	git -C "$repository" commit -q -m 'Add chart path with metacharacters'
	git -C "$repository" tag 'scoped/v1.1.0'
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

@test "collector preserves unscoped behavior when pathspecs are omitted or empty" {
	collect_context
	[ "$status" -eq 0 ]
	unscoped_facts=$(read_action_output facts-file)
	cp "$unscoped_facts" "$test_root/unscoped-facts.json"

	collect_context service/v1.1.0 ''
	[ "$status" -eq 0 ]
	empty_facts=$(read_action_output facts-file)
	jq -e --slurpfile expected "$test_root/unscoped-facts.json" '. == $expected[0]' "$empty_facts"
}

@test "collector scopes chart commits and per-commit evidence with an include-only pathspec" {
	make_scoped_history
	collect_context scoped/v1.1.0 ':(top,glob)charts/**'
	[ "$status" -eq 0 ]
	facts_file=$(read_action_output facts-file)
	context_file=$(read_action_output context-file)

	jq -e '.commits | map(.subject) == [
		"Update chart only",
		"Update chart and application together",
		"Rename chart template",
		"Add chart path with metacharacters"
	]' "$facts_file"
	grep -F 'charts/templates/chart-only.yaml' "$context_file"
	grep -F 'charts/templates/mixed.yaml' "$context_file"
	grep -F 'charts/templates/new [chart].yaml' "$context_file"
	grep -F 'charts/templates/literal $(touch injected); [x].yaml' "$context_file"
	! grep -F 'cmd/server.go' "$context_file"
	! grep -F 'src/obsolete file.go' "$context_file"
}

@test "collector scopes application commits with match-all plus chart exclusion" {
	make_scoped_history
	collect_context scoped/v1.1.0 $':(top,glob)**\n:(top,glob,exclude)charts/**'
	[ "$status" -eq 0 ]
	facts_file=$(read_action_output facts-file)
	context_file=$(read_action_output context-file)

	jq -e '.commits | map(.subject) == [
		"Update application only",
		"Update chart and application together",
		"Delete obsolete application file"
	]' "$facts_file"
	grep -F 'cmd/server.go' "$context_file"
	grep -F 'src/obsolete file.go' "$context_file"
	! grep -F 'charts/' "$context_file"
}

@test "collector passes spaces and metacharacters as one literal Git pathspec argument" {
	make_scoped_history
	pathspec=':(top,literal)charts/templates/literal $(touch injected); [x].yaml'
	collect_context scoped/v1.1.0 "$pathspec"
	[ "$status" -eq 0 ]
	facts_file=$(read_action_output facts-file)
	context_file=$(read_action_output context-file)

	jq -e '.commits | map(.subject) == ["Add chart path with metacharacters"]' "$facts_file"
	grep -F 'charts/templates/literal $(touch injected); [x].yaml' "$context_file"
	[ ! -e "$repository/injected" ]
}

@test "collector rejects empty entries, the no-pathspec sentinel, and invalid Git pathspec magic" {
	collect_context service/v1.1.0 $':(top,glob)charts/**\n\n:(top,glob)cmd/**'
	[ "$status" -ne 0 ]
	[[ "$output" == *"pathspecs must not contain empty lines"* ]]

	collect_context service/v1.1.0 ':'
	[ "$status" -ne 0 ]
	[[ "$output" == *"must not contain the Git no-pathspec sentinel"* ]]

	collect_context service/v1.1.0 ':(unknown)charts/**'
	[ "$status" -ne 0 ]
	[[ "$output" == *"valid native Git pathspecs"* ]]
}

@test "collector accepts CRLF-delimited pathspecs and one trailing line ending" {
	collect_context service/v1.1.0 $':(top,literal)release.txt\r\n'
	[ "$status" -eq 0 ]
	facts_file=$(read_action_output facts-file)
	jq -e '.commits | map(.subject) == ["Direct mainline change"]' "$facts_file"
}

@test "collector accepts a valid pathspec that selects no commits" {
	collect_context service/v1.1.0 ':(top,literal)missing file.txt'
	[ "$status" -eq 0 ]
	facts_file=$(read_action_output facts-file)
	context_file=$(read_action_output context-file)

	[ "$(jq '.commits | length' "$facts_file")" -eq 0 ]
	[ "$(jq '.omittedCommitCount' "$facts_file")" -eq 0 ]
	grep -F 'No mainline commits are present in this tag range.' "$context_file"
	! grep -F 'release.txt' "$context_file"
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
