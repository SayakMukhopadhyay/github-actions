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
	chart_version="0.0.0-build-$sha"
	repositories_file="$test_root/repositories"
	: >"$repositories_file"
	run env GITHUB_WORKSPACE="$fixture" RUNNER_TEMP="$test_root" \
		INPUT_CHART_DIRECTORY="$fixture/charts" INPUT_CHART_NAME=fixture INPUT_CHART_VERSION="$chart_version" \
		INPUT_REPOSITORIES_FILE="$repositories_file" INPUT_PUSH=false \
		INPUT_REGISTRY=ghcr.io INPUT_REPOSITORY=owner/charts REPOSITORY_OWNER=owner \
		bash "$repo_root/helm-package-push/helm-transaction.sh"
	[ "$status" -eq 0 ]
	[ -f "$fixture/charts/fixture-$chart_version.tgz" ]
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
	dependency_name=${2:-golfs}
	dependency_alias=${3:-}
	values_root=${dependency_alias:-$dependency_name}
	wrapper="$repository/$wrapper_relative"
	git init -q --bare "$bare"
	make_git_repo "$repository"

	mkdir -p "$repository/dependency/templates" "$wrapper"
	printf 'apiVersion: v2\nname: %s\ntype: application\nversion: 0.1.0\n' "$dependency_name" >"$repository/dependency/Chart.yaml"
	printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: golfs\n' >"$repository/dependency/templates/configmap.yaml"
	printf '%s:\n  image:\n    tag: initial\nreplicaCount: 1\n' "$values_root" >"$wrapper/values.yaml"
	printf 'apiVersion: v2\nname: golfs-wrapper\ntype: application\nversion: 1.0.0\ndependencies:\n  - name: %s\n' "$dependency_name" >"$wrapper/Chart.yaml"
	if [[ -n "$dependency_alias" ]]; then
		printf '    alias: %s\n' "$dependency_alias" >>"$wrapper/Chart.yaml"
	fi
	printf '    version: "0.1.0"\n    repository: file://../../../dependency\n' >>"$wrapper/Chart.yaml"
	helm dependency update "$wrapper" >/dev/null
	git -C "$repository" add . && git -C "$repository" commit -q -m initial

	sed -i 's/version: 0.1.0/version: 0.2.0/' "$repository/dependency/Chart.yaml"
	git -C "$repository" add dependency/Chart.yaml && git -C "$repository" commit -q -m 'add dependency version'
	git -C "$repository" remote add origin "$bare"
	git -C "$repository" push -q -u origin main
}

run_promotion() {
	local version=${1:-}
	local image_tag=${2:-}
	local chart_name=${3:-golfs}
	local dependency=${4:-}
	local wrapper_chart_path=${5:-}
	output_file="$test_root/promotion-output"
	: >"$output_file"
	run env GITHUB_WORKSPACE="$test_root" GITHUB_OUTPUT="$output_file" \
		INPUT_TOKEN=test-token INPUT_CHECKOUT_PATH=repository INPUT_TARGET_REF=main \
		INPUT_ENVIRONMENT=dev INPUT_CHART_NAME="$chart_name" INPUT_CHART_VERSION="$version" \
		INPUT_IMAGE_TAG="$image_tag" INPUT_DEPENDENCY="$dependency" INPUT_WRAPPER_CHART_PATH="$wrapper_chart_path" \
		bash "$repo_root/chart-update-deploy/chart-update-deploy.sh"
}

make_static_site_gitops_fixture() {
	bare="$test_root/remote.git"
	repository="$test_root/repository"
	wrapper_relative=${1:-landscape/envs/dev}
	wrapper="$repository/$wrapper_relative"
	git init -q --bare "$bare"
	make_git_repo "$repository"

	mkdir -p "$repository/static-sites/templates" "$wrapper"
	printf 'apiVersion: v2\nname: static-sites\ntype: application\nversion: 1.0.0\n' >"$repository/static-sites/Chart.yaml"
	printf 'image:\n  repository: ghcr.io/example/static-site\n  tag: initial\n' >"$repository/static-sites/values.yaml"
	printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: static-site\ndata:\n  image-tag: {{ .Values.image.tag | quote }}\n' >"$repository/static-sites/templates/configmap.yaml"
	printf 'apiVersion: v2\nname: landscape-wrapper\ntype: application\nversion: 1.0.0\ndependencies:\n  - name: static-sites\n    alias: staticSites\n    version: "1.0.0"\n    repository: file://../../../static-sites\n' >"$wrapper/Chart.yaml"
	printf 'staticSites:\n  image:\n    tag: initial\n' >"$wrapper/values.yaml"
	helm dependency update "$wrapper" >/dev/null
	git -C "$repository" add . && git -C "$repository" commit -q -m initial
	git -C "$repository" remote add origin "$bare"
	git -C "$repository" push -q -u origin main
}

run_static_site_promotion() {
	local version=$1
	local chart_name=${2:-landscape}
	local wrapper_chart_path=${3:-}
	local environment=${4:-dev}
	run env GITHUB_WORKSPACE="$test_root" \
		INPUT_TOKEN=test-token INPUT_CHECKOUT_PATH=repository INPUT_TARGET_REF=main \
		INPUT_ENVIRONMENT="$environment" INPUT_CHART_NAME="$chart_name" INPUT_IMAGE_VERSION="$version" \
		INPUT_WRAPPER_CHART_PATH="$wrapper_chart_path" \
		bash "$repo_root/static-site-update-deploy/static-site-update-deploy.sh"
}

@test "chart-update-deploy performs a chart-only update" {
	make_gitops_fixture
	run_promotion 0.2.0 ''
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
	[ "$(yq -er '.golfs.image.tag' "$wrapper/values.yaml")" = initial ]
	[ "$(sed -n 's/^commit-sha=//p' "$output_file")" = "$(git -C "$repository" rev-parse HEAD)" ]
	[ "$(git --git-dir="$bare" rev-parse refs/heads/main)" = "$(git -C "$repository" rev-parse HEAD)" ]
	[ "$(git -C "$repository" log -1 --format=%s)" = 'feat: update umbrella chart for golfs in dev environment for chart version 0.2.0' ]
	[ "$(git -C "$repository" rev-list --count HEAD)" -eq 3 ]
	[ "$(git --git-dir="$bare" rev-list --count refs/heads/main)" -eq 3 ]
}

@test "chart-update-deploy performs an image-only update" {
	make_gitops_fixture
	run_promotion '' build-abcdef1234567890
	if [[ "$status" -ne 0 ]]; then
		printf '%s\n' "$output"
	fi
	[ "$status" -eq 0 ]
	mapfile -t changed < <(git -C "$repository" diff-tree --no-commit-id --name-only -r HEAD)
	[ "${#changed[@]}" -eq 1 ]
	[ "${changed[0]}" = golfs/envs/dev/values.yaml ]
	[ "$(yq -er '.dependencies[0].version' "$wrapper/Chart.yaml")" = 0.1.0 ]
	[ "$(yq -er '.dependencies[0].version' "$wrapper/Chart.lock")" = 0.1.0 ]
	[ "$(yq -er '.golfs.image.tag' "$wrapper/values.yaml")" = build-abcdef1234567890 ]
	[ "$(sed -n 's/^commit-sha=//p' "$output_file")" = "$(git -C "$repository" rev-parse HEAD)" ]
}

@test "chart-update-deploy commits chart and image changes atomically" {
	make_gitops_fixture
	base_head=$(git -C "$repository" rev-parse HEAD)
	run_promotion 0.2.0 build-abcdef1234567890
	if [[ "$status" -ne 0 ]]; then
		printf '%s\n' "$output"
	fi
	[ "$status" -eq 0 ]
	[ "$(git -C "$repository" rev-list --count "$base_head..HEAD")" -eq 1 ]
	mapfile -t changed < <(git -C "$repository" diff-tree --no-commit-id --name-only -r HEAD | sort)
	[ "${#changed[@]}" -eq 5 ]
	[ "${changed[0]}" = golfs/envs/dev/Chart.lock ]
	[ "${changed[1]}" = golfs/envs/dev/Chart.yaml ]
	[ "${changed[2]}" = golfs/envs/dev/charts/golfs-0.1.0.tgz ]
	[ "${changed[3]}" = golfs/envs/dev/charts/golfs-0.2.0.tgz ]
	[ "${changed[4]}" = golfs/envs/dev/values.yaml ]
	[ "$(yq -er '.golfs.image.tag' "$wrapper/values.yaml")" = build-abcdef1234567890 ]
	[ "$(git -C "$repository" log -1 --format=%s)" = 'feat: update umbrella chart for golfs in dev environment for chart version 0.2.0 and image tag build-abcdef1234567890' ]
}

@test "chart-update-deploy emits the current target HEAD for a no-op" {
	make_gitops_fixture
	initial_head=$(git -C "$repository" rev-parse HEAD)
	run_promotion 0.1.0 initial
	[ "$status" -eq 0 ]
	[ "$(git -C "$repository" rev-parse HEAD)" = "$initial_head" ]
	[ "$(git --git-dir="$bare" rev-parse refs/heads/main)" = "$initial_head" ]
	[ "$(sed -n 's/^commit-sha=//p' "$output_file")" = "$initial_head" ]
	[[ "$output" == *"already consistently pinned"* ]]
	[[ "$output" == *"already pinned to image tag"* ]]
}

@test "chart-update-deploy resolves a dependency alias and uses it as the values root" {
	make_gitops_fixture golfs/envs/dev upstream golfs
	run_promotion 0.2.0 build-abcdef1234567890
	if [[ "$status" -ne 0 ]]; then
		printf '%s\n' "$output"
	fi
	[ "$status" -eq 0 ]
	[ "$(yq -er '.dependencies[] | select(.name == "upstream").version' "$wrapper/Chart.yaml")" = 0.2.0 ]
	[ "$(yq -er '.golfs.image.tag' "$wrapper/values.yaml")" = build-abcdef1234567890 ]
	[ -f "$wrapper/charts/upstream-0.2.0.tgz" ]
	[ ! -e "$wrapper/charts/golfs-0.2.0.tgz" ]
}

@test "chart-update-deploy requires chart-version or image-tag" {
	make_gitops_fixture
	run_promotion '' ''
	[ "$status" -ne 0 ]
	[[ "$output" == *"at least one of chart-version or image-tag is required"* ]]
}

@test "chart-update-deploy preserves explicit wrapper and dependency overrides" {
	make_gitops_fixture custom-service/envs/stage
	run_promotion 0.2.0 '' service golfs custom-service/envs/stage
	[ "$status" -eq 0 ]
	dependency_version=$(env DEPENDENCY=golfs yq -er '.dependencies[] | select(.name == strenv(DEPENDENCY)) | .version' "$wrapper/Chart.yaml")
	[ "$dependency_version" = 0.2.0 ]
}

@test "chart-update-deploy fails instead of repairing inconsistent no-op state" {
	make_gitops_fixture
	rm "$wrapper/charts/golfs-0.1.0.tgz"
	git -C "$repository" add -u && git -C "$repository" commit -q -m inconsistent
	git -C "$repository" push -q
	run_promotion 0.1.0 ''
	[ "$status" -ne 0 ]
	[[ "$output" == *"vendored archive is missing"* ]]
}

@test "chart-update-deploy retries once after an unrelated target branch update" {
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

	run_promotion '' build-abcdef1234567890
	if [[ "$status" -ne 0 ]]; then
		printf '%s\n' "$output"
	fi
	[ "$status" -eq 0 ]
	[[ "$output" == *"refreshing and retrying once"* ]]
	result_head=$(sed -n 's/^commit-sha=//p' "$output_file")
	[ "$(git --git-dir="$bare" rev-parse refs/heads/main)" = "$result_head" ]
	git --git-dir="$bare" merge-base --is-ancestor "$remote_head" "$result_head"
	[ "$(git --git-dir="$bare" show "${result_head}:race.txt")" = race ]
	[ "$(git --git-dir="$bare" show "${result_head}:golfs/envs/dev/values.yaml" | yq -er '.golfs.image.tag')" = build-abcdef1234567890 ]
}

@test "chart-update-deploy fails safely when a concurrent update changes the same wrapper state" {
	make_gitops_fixture
	competitor="$test_root/competitor"
	git clone -q --branch main "$bare" "$competitor"
	git -C "$competitor" config user.name Competitor
	git -C "$competitor" config user.email competitor@example.com
	git -C "$competitor" config commit.gpgsign false
	git -C "$competitor" config core.autocrlf false
	yq -i '.golfs.image.tag = "competitor"' "$competitor/golfs/envs/dev/values.yaml"
	git -C "$competitor" add golfs/envs/dev/values.yaml
	git -C "$competitor" commit -q -m 'competing wrapper update'
	git -C "$competitor" push -q origin main
	remote_head=$(git --git-dir="$bare" rev-parse refs/heads/main)

	run_promotion '' build-abcdef1234567890
	[ "$status" -ne 0 ]
	[[ "$output" == *"concurrent update changed protected wrapper state: golfs/envs/dev/values.yaml"* ]]
	[ "$(git --git-dir="$bare" rev-parse refs/heads/main)" = "$remote_head" ]
	[ ! -s "$output_file" ]
}

@test "chart-update-deploy rejects duplicate dependency matches" {
	make_gitops_fixture
	chart_file="$wrapper/Chart.yaml"
	printf '  - name: golfs\n    version: "0.1.0"\n    repository: file://../../../dependency\n' >>"$chart_file"
	git -C "$repository" add "$chart_file"
	git -C "$repository" commit -q -m duplicate
	git -C "$repository" push -q

	run_promotion 0.2.0 ''
	[ "$status" -ne 0 ]
	[[ "$output" == *"exactly one dependency matching 'golfs'; found 2"* ]]
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

	run_promotion 0.2.0 ''
	[ "$status" -ne 0 ]
	[[ "$output" == *"changed unexpected path"* ]]
	[ "$(git --git-dir="$bare" rev-parse refs/heads/main)" = "$remote_head" ]
}

@test "static-site-update-deploy derives the environment wrapper and updates the fixed alias" {
	make_static_site_gitops_fixture
	run_static_site_promotion build-abcdef1234567890
	if [[ "$status" -ne 0 ]]; then
		printf '%s\n' "$output"
	fi
	[ "$status" -eq 0 ]
	mapfile -t changed < <(git -C "$repository" diff-tree --no-commit-id --name-only -r HEAD)
	[ "${#changed[@]}" -eq 1 ]
	[ "${changed[0]}" = landscape/envs/dev/values.yaml ]
	[ "$(yq -er '.staticSites.image.tag' "$wrapper/values.yaml")" = build-abcdef1234567890 ]
	[ "$(git -C "$repository" log -1 --format=%s)" = 'feat: update static site landscape in dev environment to image version build-abcdef1234567890' ]

	first_promotion_head=$(git -C "$repository" rev-parse HEAD)
	run_static_site_promotion build-abcdef1234567890
	[ "$status" -eq 0 ]
	[ "$(git -C "$repository" rev-parse HEAD)" = "$first_promotion_head" ]
}

@test "static-site-update-deploy preserves an explicit wrapper override" {
	make_static_site_gitops_fixture custom-site/envs/stage
	run_static_site_promotion release-2026.09 landscape custom-site/envs/stage stage
	[ "$status" -eq 0 ]
	[ "$(yq -er '.staticSites.image.tag' "$wrapper/values.yaml")" = release-2026.09 ]
}

@test "static-site-update-deploy requires the fixed dependency alias" {
	make_static_site_gitops_fixture
	yq -i '(.dependencies[] | select(.name == "static-sites")).alias = "landscape"' "$wrapper/Chart.yaml"
	git -C "$repository" add "$wrapper/Chart.yaml"
	git -C "$repository" commit -q -m 'change alias'
	git -C "$repository" push -q

	run_static_site_promotion build-abcdef
	[ "$status" -ne 0 ]
	[[ "$output" == *"must define alias 'staticSites'"* ]]
}

@test "static-site-update-deploy rejects duplicate static-sites dependencies" {
	make_static_site_gitops_fixture
	yq -i '.dependencies += [{"name": "static-sites", "alias": "otherSite", "version": "1.0.0", "repository": "file://../../../static-sites"}]' "$wrapper/Chart.yaml"
	git -C "$repository" add "$wrapper/Chart.yaml"
	git -C "$repository" commit -q -m 'duplicate static-sites dependency'
	git -C "$repository" push -q

	run_static_site_promotion build-abcdef
	[ "$status" -ne 0 ]
	[[ "$output" == *"exactly one dependency named 'static-sites'; found 2"* ]]
}

@test "static-site-update-deploy requires an existing string image tag" {
	make_static_site_gitops_fixture
	yq -i 'del(.staticSites.image.tag)' "$wrapper/values.yaml"
	git -C "$repository" add "$wrapper/values.yaml"
	git -C "$repository" commit -q -m 'remove image tag'
	git -C "$repository" push -q

	run_static_site_promotion build-abcdef
	[ "$status" -ne 0 ]
	[[ "$output" == *"must contain a string at staticSites.image.tag"* ]]
}

@test "static-site-update-deploy rejects invalid container image tags" {
	make_static_site_gitops_fixture
	run_static_site_promotion 'build/abcdef'
	[ "$status" -ne 0 ]
	[[ "$output" == *"must be a valid container image tag"* ]]
}

@test "static-site-update-deploy rejects unexpected changes produced during validation" {
	make_static_site_gitops_fixture
	fake_bin="$test_root/bin"
	mkdir -p "$fake_bin"
	printf '#!/usr/bin/env bash\ntouch "$GITHUB_WORKSPACE/repository/unexpected.txt"\n' >"$fake_bin/helm"
	chmod +x "$fake_bin/helm"
	export PATH="$fake_bin:$PATH"

	run_static_site_promotion build-abcdef
	[ "$status" -ne 0 ]
	[[ "$output" == *"changed unexpected path: unexpected.txt"* ]]
}

@test "static-site-update-deploy detects a target branch race before push" {
	make_static_site_gitops_fixture
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

	run_static_site_promotion build-abcdef
	[ "$status" -ne 0 ]
	[[ "$output" == *"[rejected]"* || "$output" == *"fetch first"* ]]
	[ "$(git --git-dir="$bare" rev-parse refs/heads/main)" = "$remote_head" ]
}
