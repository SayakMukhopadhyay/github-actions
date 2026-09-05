#!/usr/bin/env bats

load test-helper

setup() {
	test_root=$(mktemp -d)
	export HELM_CONFIG_HOME="$test_root/helm-config"
	export HELM_CACHE_HOME="$test_root/helm-cache"
	export HELM_DATA_HOME="$test_root/helm-data"
}

teardown() {
	rm -rf "$test_root"
}

@test "helm-package-push creates a stable package and dependencies in place" {
	fixture="$test_root/stable"
	cp -a "$repo_root/tests/fixtures/go-chart" "$fixture"
	mkdir -p "$fixture/dependency/templates"
	printf 'apiVersion: v2\nname: dependency\ntype: application\nversion: 1.0.0\n' >"$fixture/dependency/Chart.yaml"
	printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: dependency\n' >"$fixture/dependency/templates/configmap.yaml"
	printf '\ndependencies:\n  - name: dependency\n    version: 1.0.0\n    repository: file://../dependency\n' >>"$fixture/charts/Chart.yaml"
	repositories_file="$test_root/repositories"
	: >"$repositories_file"
	run env GITHUB_WORKSPACE="$fixture" RUNNER_TEMP="$test_root" \
		INPUT_CHART_DIRECTORY="$fixture/charts" INPUT_CHART_NAME=fixture INPUT_CHART_VERSION=0.4.0 \
		INPUT_REPOSITORIES_FILE="$repositories_file" INPUT_PUSH=false \
		INPUT_REGISTRY=ghcr.io INPUT_REPOSITORY=owner/charts REPOSITORY_OWNER=owner \
		bash "$repo_root/helm-package-push/helm-transaction.sh"
	[ "$status" -eq 0 ]
	[ -f "$fixture/charts/fixture-0.4.0.tgz" ]
	[ -f "$fixture/charts/charts/dependency-1.0.0.tgz" ]
}

@test "helm-package-push derives development metadata from the full commit SHA" {
	fixture="$test_root/development"
	cp -a "$repo_root/tests/fixtures/go-chart" "$fixture"
	sha=abcdef1234567890abcdef1234567890abcdef12
	repositories_file="$test_root/repositories"
	: >"$repositories_file"
	run env GITHUB_WORKSPACE="$fixture" RUNNER_TEMP="$test_root" \
		INPUT_CHART_DIRECTORY="$fixture/charts" INPUT_CHART_NAME=fixture INPUT_CHART_VERSION="0.4.0-$sha" \
		INPUT_REPOSITORIES_FILE="$repositories_file" INPUT_PUSH=false \
		INPUT_REGISTRY=ghcr.io INPUT_REPOSITORY=owner/charts REPOSITORY_OWNER=owner \
		bash "$repo_root/helm-package-push/helm-transaction.sh"
	[ "$status" -eq 0 ]
	[ -f "$fixture/charts/fixture-0.4.0-$sha.tgz" ]
}

@test "helm-package-push preserves Helm's free-form appVersion contract" {
	fixture="$test_root/chart-only"
	cp -a "$repo_root/tests/fixtures/go-chart" "$fixture"
	rm "$fixture/VERSION"
	repositories_file="$test_root/repositories"
	: >"$repositories_file"
	run env GITHUB_WORKSPACE="$fixture" RUNNER_TEMP="$test_root" \
		INPUT_CHART_DIRECTORY="$fixture/charts" INPUT_CHART_NAME=fixture INPUT_CHART_VERSION=0.4.0 \
		INPUT_REPOSITORIES_FILE="$repositories_file" INPUT_PUSH=false \
		INPUT_APP_VERSION='release candidate 7' INPUT_REGISTRY=ghcr.io INPUT_REPOSITORY=owner/charts REPOSITORY_OWNER=owner \
		bash "$repo_root/helm-package-push/helm-transaction.sh"
	[ "$status" -eq 0 ]
	helm show chart "$fixture/charts/fixture-0.4.0.tgz" | yq -e '.appVersion == "release candidate 7"'
}

make_gitops_fixture() {
	bare="$test_root/remote.git"
	repository="$test_root/repository"
	wrapper_relative=${1:-golfs/envs/dev}
	wrapper="$repository/$wrapper_relative"
	git init -q --bare "$bare"
	make_git_repo "$repository"

	mkdir -p "$repository/dependency/templates" "$wrapper"
	printf 'apiVersion: v2\nname: golfs\ntype: application\nversion: 0.1.0\n' >"$repository/dependency/Chart.yaml"
	printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: golfs\n' >"$repository/dependency/templates/configmap.yaml"
	printf 'replicaCount: 1\n' >"$wrapper/values.yaml"
	printf 'apiVersion: v2\nname: golfs-wrapper\ntype: application\nversion: 1.0.0\ndependencies:\n  - name: golfs\n    version: "0.1.0"\n    repository: file://../../../dependency\n' >"$wrapper/Chart.yaml"
	helm dependency update "$wrapper" >/dev/null
	git -C "$repository" add . && git -C "$repository" commit -q -m initial

	sed -i 's/version: 0.1.0/version: 0.2.0/' "$repository/dependency/Chart.yaml"
	git -C "$repository" add dependency/Chart.yaml && git -C "$repository" commit -q -m 'add dependency version'
	git -C "$repository" remote add origin "$bare"
	git -C "$repository" push -q -u origin main
}

run_promotion() {
	local version=$1
	local chart_name=${2:-golfs}
	local dependency=${3:-}
	local wrapper_chart_path=${4:-}
	output_file="$test_root/promotion-output"
	: >"$output_file"
	run env GITHUB_WORKSPACE="$test_root" GITHUB_OUTPUT="$output_file" \
		INPUT_TOKEN=test-token INPUT_CHECKOUT_PATH=repository INPUT_TARGET_REF=main \
		INPUT_ENVIRONMENT=dev INPUT_CHART_NAME="$chart_name" INPUT_CHART_VERSION="$version" \
		INPUT_DEPENDENCY="$dependency" INPUT_WRAPPER_CHART_PATH="$wrapper_chart_path" \
		bash "$repo_root/chart-update-deploy/chart-update-deploy.sh"
}

@test "chart-update-deploy derives the environment wrapper and dependency from chart-name" {
	make_gitops_fixture
	run_promotion 0.2.0
	if [[ "$status" -ne 0 ]]; then
		printf '%s\n' "$output"
	fi
	[ "$status" -eq 0 ]
	mapfile -t changed < <(git -C "$repository" diff-tree --no-commit-id --name-only -r HEAD | sort)
	[ "${#changed[@]}" -eq 4 ]
	[ "${changed[0]}" = golfs/envs/dev/Chart.lock ]
	[ "${changed[1]}" = golfs/envs/dev/Chart.yaml ]
	[ "${changed[2]}" = golfs/envs/dev/charts/golfs-0.1.0.tgz ]
	[ "${changed[3]}" = golfs/envs/dev/charts/golfs-0.2.0.tgz ]

	first_promotion_head=$(git -C "$repository" rev-parse HEAD)
	run_promotion 0.2.0
	[ "$status" -eq 0 ]
	[ "$(git -C "$repository" rev-parse HEAD)" = "$first_promotion_head" ]
}

@test "chart-update-deploy preserves explicit wrapper and dependency overrides" {
	make_gitops_fixture custom-service/envs/stage
	run_promotion 0.2.0 service golfs custom-service/envs/stage
	[ "$status" -eq 0 ]
	dependency_version=$(env DEPENDENCY=golfs yq -er '.dependencies[] | select(.name == strenv(DEPENDENCY)) | .version' "$wrapper/Chart.yaml")
	[ "$dependency_version" = 0.2.0 ]
}

@test "chart-update-deploy fails instead of repairing inconsistent no-op state" {
	make_gitops_fixture
	rm "$wrapper/charts/golfs-0.1.0.tgz"
	git -C "$repository" add -u && git -C "$repository" commit -q -m inconsistent
	git -C "$repository" push -q
	run_promotion 0.1.0
	[ "$status" -ne 0 ]
	[[ "$output" == *"vendored archive is missing"* ]]
}

@test "chart-update-deploy detects a target branch race before push" {
	make_gitops_fixture
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

	run_promotion 0.2.0
	[ "$status" -ne 0 ]
	[[ "$output" == *"[rejected]"* || "$output" == *"fetch first"* ]]
	[ "$(git --git-dir="$bare" rev-parse refs/heads/main)" = "$remote_head" ]
}

@test "chart-update-deploy rejects duplicate dependency matches" {
	make_gitops_fixture
	chart_file="$wrapper/Chart.yaml"
	printf '  - name: golfs\n    version: "0.1.0"\n    repository: file://../../../dependency\n' >>"$chart_file"
	git -C "$repository" add "$chart_file"
	git -C "$repository" commit -q -m duplicate
	git -C "$repository" push -q

	run_promotion 0.2.0
	[ "$status" -ne 0 ]
	[[ "$output" == *"exactly one dependency named 'golfs'; found 2"* ]]
}

@test "chart-update-deploy rejects unrelated dependency archive changes" {
	make_gitops_fixture
	mkdir -p "$repository/other/templates"
	printf 'apiVersion: v2\nname: other\ntype: application\nversion: 0.1.0\n' >"$repository/other/Chart.yaml"
	printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: other\n' >"$repository/other/templates/configmap.yaml"
	DEPENDENCY_PATH='file://../../../other' yq -i '.dependencies += [{"name": "other", "version": ">=0.1.0", "repository": strenv(DEPENDENCY_PATH)}]' "$wrapper/Chart.yaml"
	sed -i 's/version: 0.2.0/version: 0.1.0/' "$repository/dependency/Chart.yaml"
	helm dependency update "$wrapper" >/dev/null
	sed -i 's/version: 0.1.0/version: 0.2.0/' "$repository/dependency/Chart.yaml"
	git -C "$repository" add .
	git -C "$repository" commit -q -m 'add other dependency'
	git -C "$repository" push -q

	sed -i 's/version: 0.1.0/version: 0.2.0/' "$repository/other/Chart.yaml"
	git -C "$repository" add other/Chart.yaml
	git -C "$repository" commit -q -m 'update other dependency'
	git -C "$repository" push -q
	remote_head=$(git --git-dir="$bare" rev-parse refs/heads/main)

	run_promotion 0.2.0
	[ "$status" -ne 0 ]
	[[ "$output" == *"changed unexpected path"* ]]
	[ "$(git --git-dir="$bare" rev-parse refs/heads/main)" = "$remote_head" ]
}
