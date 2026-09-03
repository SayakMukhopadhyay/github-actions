#!/usr/bin/env bash

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

make_git_repo() {
	local directory=$1
	git init -q -b main "$directory"
	git -C "$directory" config user.name Tester
	git -C "$directory" config user.email tester@example.com
	git -C "$directory" config commit.gpgsign false
	git -C "$directory" config core.autocrlf false
}

write_chart() {
	local directory=$1 app_version=$2 chart_version=$3
	mkdir -p "$directory/charts"
	printf '%s\n' "$app_version" >"$directory/VERSION"
	printf '%s\n' "$chart_version" >"$directory/charts/VERSION"
	printf 'apiVersion: v2\nname: fixture\nversion: %s\nappVersion: "%s"\n' "$chart_version" "$app_version" >"$directory/charts/Chart.yaml"
}
