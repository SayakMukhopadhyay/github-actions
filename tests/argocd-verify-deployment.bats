#!/usr/bin/env bats

load test-helper

setup() {
	test_root_unix=$(mktemp -d)
	if command -v cygpath >/dev/null 2>&1; then
		test_root=$(cygpath -w "$test_root_unix")
	else
		test_root=$test_root_unix
	fi
	gitops_repository="$test_root/gitops"
	make_git_repo "$gitops_repository"
	printf 'base\n' >"$gitops_repository/state"
	git -C "$gitops_repository" add state
	git -C "$gitops_repository" commit -q -m base
	expected_revision=$(git -C "$gitops_repository" rev-parse HEAD)
	printf 'descendant\n' >>"$gitops_repository/state"
	git -C "$gitops_repository" commit -q -am descendant
	descendant_revision=$(git -C "$gitops_repository" rev-parse HEAD)
	git -C "$gitops_repository" checkout -q --orphan unrelated
	git -C "$gitops_repository" rm -q -rf .
	printf 'unrelated\n' >"$gitops_repository/unrelated"
	git -C "$gitops_repository" add unrelated
	git -C "$gitops_repository" commit -q -m unrelated
	unrelated_revision=$(git -C "$gitops_repository" rev-parse HEAD)
	git -C "$gitops_repository" checkout -q main

	fixture_source="$repo_root/tests/fixtures/argocd-verify-deployment-bin"
	fixture_bin="$test_root/bin"
	mkdir -p "$fixture_bin"
	cp "$fixture_source/argocd" "$fixture_source/curl" "$fixture_bin/"
	chmod +x "$fixture_bin/argocd" "$fixture_bin/curl"
	export PATH="$fixture_bin:$PATH"
	export ARGOCD_CLI_PATH="$fixture_bin/argocd"
	export GITOPS_CHECKOUT_PATH=$gitops_repository
	export INPUT_SERVER=argocd.example.test
	export INPUT_APPLICATION=fixture
	export INPUT_AUTH_TOKEN=fixture-argocd-token
	export INPUT_CLOUDFLARE_ACCESS_CLIENT_ID=fixture-access-id
	export INPUT_CLOUDFLARE_ACCESS_CLIENT_SECRET=fixture-access-secret
	export INPUT_EXPECTED_COMMIT_SHA=$expected_revision
	export INPUT_TIMEOUT_SECONDS=5
	export INPUT_SMOKE_URL=
	export ARGOCD_FAKE_REVISION=$expected_revision
	export ARGOCD_FAKE_LOG="$test_root/argocd.log"
	export CURL_FAKE_LOG="$test_root/curl.log"
	export GITHUB_OUTPUT="$test_root/github-output"
}

teardown() {
	rm -rf -- "$test_root_unix"
}

run_verifier() {
	run bash "$repo_root/argocd-verify-deployment/verify-deployment.sh"
}

@test 'accepts an exact synchronized revision and sends both Access headers through gRPC-web' {
	run_verifier

	[ "$status" -eq 0 ]
	grep -Fx -- '--grpc-web' "$ARGOCD_FAKE_LOG"
	grep -Fx -- 'CF-Access-Client-Id: fixture-access-id' "$ARGOCD_FAKE_LOG"
	grep -Fx -- 'CF-Access-Client-Secret: fixture-access-secret' "$ARGOCD_FAKE_LOG"
	grep -Fx -- 'synchronized-revision='"$expected_revision" "$GITHUB_OUTPUT"
}

@test 'accepts a synchronized descendant of the expected revision' {
	export ARGOCD_FAKE_REVISION=$descendant_revision
	run_verifier

	[ "$status" -eq 0 ]
	grep -Fx -- 'synchronized-revision='"$descendant_revision" "$GITHUB_OUTPUT"
}

@test 'fails when the Application does not become ready before the timeout' {
	export ARGOCD_FAKE_SYNC_STATUS=OutOfSync
	export ARGOCD_FAKE_HEALTH_STATUS=Progressing
	export ARGOCD_FAKE_EXIT=20
	run_verifier

	[ "$status" -ne 0 ]
	[[ $output == *'did not become Synced and Healthy within 5s'* ]]
}

@test 'fails explicitly for a degraded Application' {
	export ARGOCD_FAKE_HEALTH_STATUS=Degraded
	export ARGOCD_FAKE_EXIT=20
	run_verifier

	[ "$status" -ne 0 ]
	[[ $output == *"is unhealthy (sync=Synced, health=Degraded)"* ]]
}

@test 'rejects an unrelated synchronized revision' {
	export ARGOCD_FAKE_REVISION=$unrelated_revision
	run_verifier

	[ "$status" -ne 0 ]
	[[ $output == *'is not an ancestor of synchronized revision'* ]]
}

@test 'rejects an unavailable synchronized revision' {
	export ARGOCD_FAKE_REVISION=0000000000000000000000000000000000000000
	run_verifier

	[ "$status" -ne 0 ]
	[[ $output == *'synchronized GitOps revision is unavailable'* ]]
}

@test 'passes an authenticated HTTP smoke request with both Access headers' {
	export INPUT_SMOKE_URL=https://service.example.test/health
	run_verifier

	[ "$status" -eq 0 ]
	grep -Fx -- 'CF-Access-Client-Id: fixture-access-id' "$CURL_FAKE_LOG"
	grep -Fx -- 'CF-Access-Client-Secret: fixture-access-secret' "$CURL_FAKE_LOG"
	grep -Fx -- 'https://service.example.test/health' "$CURL_FAKE_LOG"
}

@test 'fails when the authenticated HTTP smoke request fails' {
	export INPUT_SMOKE_URL=https://service.example.test/health
	export CURL_FAKE_EXIT=22
	run_verifier

	[ "$status" -ne 0 ]
	[[ $output == *'authenticated HTTP smoke test failed'* ]]
}
