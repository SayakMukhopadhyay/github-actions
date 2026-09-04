#!/usr/bin/env bats

load test-helper

setup() {
	test_root=$(mktemp -d)
	bare="$test_root/remote.git"
	repository="$test_root/repository"
	output_file="$test_root/github-output"
	git init -q --bare "$bare"
	make_git_repo "$repository"
	printf 'first\n' > "$repository/release.txt"
	git -C "$repository" add release.txt
	git -C "$repository" commit -q -m first
	other_commit=$(git -C "$repository" rev-parse HEAD)
	printf 'target\n' >> "$repository/release.txt"
	git -C "$repository" add release.txt
	git -C "$repository" commit -q -m target
	target_commit=$(git -C "$repository" rev-parse HEAD)
	git -C "$repository" remote add origin "$bare"
	git -C "$repository" push -q -u origin main
	: > "$output_file"
}

teardown() {
	rm -rf "$test_root"
}

run_release_tags() {
	local mode=$1 tags=$2
	shift 2
	: > "$output_file"
	run env \
		GITHUB_WORKSPACE="$repository" \
		GITHUB_OUTPUT="$output_file" \
		INPUT_MODE="$mode" \
		INPUT_TAGS="$tags" \
		INPUT_TOKEN=fixture-token \
		TARGET_SHA="$target_commit" \
		"$@" \
		bash "$repo_root/release-tags/release-tags.sh"
}

remote_tag() {
	git --git-dir="$bare" rev-parse "refs/tags/$1^{commit}" 2> /dev/null
}

make_racing_git() {
	race_bin="$test_root/race-bin"
	mkdir -p "$race_bin"
	cat > "$race_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -z ${INPUT_TOKEN:-} ]] || { printf 'INPUT_TOKEN leaked to git\n' >&2; exit 97; }
has_remote_auth=false
for ((index = 0; index < ${GIT_CONFIG_COUNT:-0}; index++)); do
	key_name="GIT_CONFIG_KEY_$index"
	value_name="GIT_CONFIG_VALUE_$index"
	if [[ ${!key_name:-} == http.extraheader && ${!value_name:-} == 'AUTHORIZATION: basic '* ]]; then
		has_remote_auth=true
	fi
done
if [[ ${1:-} == ls-remote || ${1:-} == push ]]; then
	[[ $has_remote_auth == true ]]
else
	[[ $has_remote_auth == false ]] || { printf 'remote auth leaked to local git\n' >&2; exit 98; }
fi
if [[ ${1:-} == push ]]; then
	"$REAL_GIT" --git-dir="$RACE_REMOTE" update-ref "refs/tags/$RACE_TAG" "$RACE_OBJECT"
	[[ ${RACE_ABORT_PUSH:-false} != true ]] || exit 1
fi
exec "$REAL_GIT" "$@"
EOF
	chmod +x "$race_bin/git"
	real_git=$(command -v git)
}

@test "verify reports false for absent tags without creating them" {
	run_release_tags verify $'app/v1.2.3\nchart/v1.2.3'
	[ "$status" -eq 0 ]
	grep -Fx 'tags-match=false' "$output_file"
	! git --git-dir="$bare" show-ref --verify --quiet refs/tags/app/v1.2.3
	! git --git-dir="$bare" show-ref --verify --quiet refs/tags/chart/v1.2.3
}

@test "verify accepts existing lightweight and annotated tags resolving to the target" {
	git --git-dir="$bare" update-ref refs/tags/app/v1.2.3 "$target_commit"
	git -C "$repository" tag -a -m chart chart/v1.2.3 "$target_commit"
	git -C "$repository" push -q origin refs/tags/chart/v1.2.3

	run_release_tags verify $'app/v1.2.3\nchart/v1.2.3'
	[ "$status" -eq 0 ]
	grep -Fx 'tags-match=true' "$output_file"
}

@test "verify reports false and ensure rejects a tag resolving to another commit" {
	git --git-dir="$bare" update-ref refs/tags/app/v1.2.3 "$other_commit"

	run_release_tags verify app/v1.2.3
	[ "$status" -eq 0 ]
	grep -Fx 'tags-match=false' "$output_file"

	run_release_tags ensure app/v1.2.3
	[ "$status" -ne 0 ]
	[[ "$output" == *'refusing to overwrite'* ]]
	[ "$(remote_tag app/v1.2.3)" = "$other_commit" ]
}

@test "input validation rejects duplicate and invalid tags before remote mutation" {
	run_release_tags ensure $'app/v1.2.3\napp/v1.2.3'
	[ "$status" -ne 0 ]
	[[ "$output" == *'duplicate tag'* ]]

	run_release_tags ensure $'app/v1.2.3\nbad tag'
	[ "$status" -ne 0 ]
	[[ "$output" == *'invalid Git tag name'* ]]

	run_release_tags publish app/v1.2.3
	[ "$status" -ne 0 ]
	[[ "$output" == *'mode must be verify or ensure'* ]]
	! git --git-dir="$bare" show-ref --tags --quiet
}

@test "ensure creates only missing lightweight tags in a mixed set" {
	git --git-dir="$bare" update-ref refs/tags/app/v1.2.3 "$target_commit"

	run_release_tags ensure $'app/v1.2.3\nchart/v1.2.3\n'
	[ "$status" -eq 0 ]
	grep -Fx 'tags-match=true' "$output_file"
	[ "$(git --git-dir="$bare" cat-file -t refs/tags/app/v1.2.3)" = commit ]
	[ "$(git --git-dir="$bare" cat-file -t refs/tags/chart/v1.2.3)" = commit ]
	[ "$(remote_tag app/v1.2.3)" = "$target_commit" ]
	[ "$(remote_tag chart/v1.2.3)" = "$target_commit" ]
}

@test "ensure is idempotent when every tag already resolves to the target" {
	git --git-dir="$bare" update-ref refs/tags/app/v1.2.3 "$target_commit"

	run_release_tags ensure app/v1.2.3
	[ "$status" -eq 0 ]
	grep -Fx 'tags-match=true' "$output_file"
	[[ "$output" == *'nothing to create'* ]]
}

@test "ensure fails safely when a competing tag appears before the atomic push" {
	make_racing_git

	run_release_tags ensure $'app/v1.2.3\nchart/v1.2.3' \
		PATH="$race_bin:$PATH" \
		REAL_GIT="$real_git" \
		RACE_REMOTE="$bare" \
		RACE_TAG=app/v1.2.3 \
		RACE_OBJECT="$other_commit"
	[ "$status" -ne 0 ]
	[[ "$output" == *'atomic tag push was rejected'* ]]
	[ "$(remote_tag app/v1.2.3)" = "$other_commit" ]
	! git --git-dir="$bare" show-ref --verify --quiet refs/tags/chart/v1.2.3
}

@test "ensure accepts a failed push when a concurrent run created the same tag" {
	make_racing_git

	run_release_tags ensure app/v1.2.3 \
		PATH="$race_bin:$PATH" \
		REAL_GIT="$real_git" \
		RACE_REMOTE="$bare" \
		RACE_TAG=app/v1.2.3 \
		RACE_OBJECT="$target_commit" \
		RACE_ABORT_PUSH=true
	[ "$status" -eq 0 ]
	grep -Fx 'tags-match=true' "$output_file"
	[[ "$output" == *'concurrent run created'* ]]
	[ "$(remote_tag app/v1.2.3)" = "$target_commit" ]
}
