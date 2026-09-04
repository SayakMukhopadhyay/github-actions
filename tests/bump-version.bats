#!/usr/bin/env bats

load test-helper

setup() {
	test_root=$(mktemp -d)
	bare="$test_root/remote.git"
	repository="$test_root/repository"
	git init -q --bare "$bare"
	make_git_repo "$repository"
	write_chart "$repository" 1.2.3 0.4.0
	git -C "$repository" add . && git -C "$repository" commit -q -m initial
	git -C "$repository" remote add origin "$bare"
	git -C "$repository" push -q -u origin main
}

teardown() {
	rm -rf "$test_root"
}

run_bump() {
	local helm=$1 go=${2:-false}
	run env \
		GITHUB_WORKSPACE="$repository" \
		INPUT_INCREMENT=patch INPUT_WORKING_DIRECTORY=. INPUT_HELM="$helm" \
		INPUT_GO="$go" TARGET_REF=main \
		bash "$repo_root/tests/fixtures/core-actions/run-bump-version.sh" "$repo_root"
}

@test "Helm and Go selectors bump and commit only three declared files" {
	run_bump true true
	[ "$status" -eq 0 ]
	[ "$(cat "$repository/VERSION")" = 1.2.4 ]
	[ "$(cat "$repository/charts/VERSION")" = 0.4.1 ]
	grep -F 'version: 0.4.1' "$repository/charts/Chart.yaml"
	grep -F 'appVersion: "1.2.4"' "$repository/charts/Chart.yaml"
	mapfile -t changed < <(git -C "$repository" diff-tree --no-commit-id --name-only -r HEAD | sort)
	[ "${#changed[@]}" -eq 3 ]
	[ "${changed[0]}" = VERSION ]
	[ "${changed[1]}" = charts/Chart.yaml ]
	[ "${changed[2]}" = charts/VERSION ]
}

@test "Helm-only bump preserves application authority and appVersion" {
	run_bump true
	[ "$status" -eq 0 ]
	[ "$(cat "$repository/VERSION")" = 1.2.3 ]
	[ "$(cat "$repository/charts/VERSION")" = 0.4.1 ]
	grep -F 'appVersion: "1.2.3"' "$repository/charts/Chart.yaml"
}

@test "Go-only bump updates only the application authority" {
	run_bump false true
	[ "$status" -eq 0 ]
	[ "$(cat "$repository/VERSION")" = 1.2.4 ]
	mapfile -t changed < <(git -C "$repository" diff-tree --no-commit-id --name-only -r HEAD | sort)
	[ "${#changed[@]}" -eq 1 ]
	[ "${changed[0]}" = VERSION ]
}

@test "a remote race rejects the version push without force" {
	competitor="$test_root/competitor"
	git clone -q --branch main "$bare" "$competitor"
	git -C "$competitor" config user.name Competitor
	git -C "$competitor" config user.email competitor@example.com
	git -C "$competitor" config commit.gpgsign false
	git -C "$competitor" config core.autocrlf false
	printf 'race\n' >"$competitor/race.txt"
	git -C "$competitor" add race.txt
	git -C "$competitor" commit -q -m race
	git -C "$competitor" push -q origin main
	remote_head=$(git --git-dir="$bare" rev-parse refs/heads/main)

	run_bump true
	[ "$status" -ne 0 ]
	[ "$(git --git-dir="$bare" rev-parse refs/heads/main)" = "$remote_head" ]
}
