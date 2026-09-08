#!/usr/bin/env bats

setup() {
	test_root=$(mktemp -d)
	fake_bin="$test_root/bin"
	output_file="$test_root/github-output"
	arguments_file="$test_root/az-arguments"
	mkdir -p "$fake_bin"
	cat > "$fake_bin/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$AZ_ARGUMENTS_FILE"
[[ ${AZ_EXIT_STATUS:-0} == 0 ]] || exit "$AZ_EXIT_STATUS"
printf '%s\n' "${AZ_TOKEN:-}"
EOF
	chmod +x "$fake_bin/az"
	: > "$output_file"
	: > "$arguments_file"
}

teardown() {
	rm -rf "$test_root"
}

run_azure_acr_token() {
	local login_server=$1
	local token=${2-fixture-access-token}
	: > "$output_file"
	: > "$arguments_file"
	run env \
		PATH="$fake_bin:$PATH" \
		GITHUB_OUTPUT="$output_file" \
		INPUT_LOGIN_SERVER="$login_server" \
		AZ_ARGUMENTS_FILE="$arguments_file" \
		AZ_TOKEN="$token" \
		bash "$BATS_TEST_DIRNAME/../azure-acr-token/azure-acr-token.sh"
}

@test "derives the registry name and suffix from the Andromeda DNL login server" {
	run_azure_acr_token greybodygames-bkf5agemepdabtg3.azurecr.io
	[ "$status" -eq 0 ]
	mapfile -t arguments < "$arguments_file"
	[ "${arguments[*]}" = "acr login --name greybodygames --suffix bkf5agemepdabtg3 --expose-token --query accessToken --output tsv" ]
	[ "$output" = "::add-mask::fixture-access-token" ]
	grep -Fx 'username=00000000-0000-0000-0000-000000000000' "$output_file"
	grep -Fx 'access-token=fixture-access-token' "$output_file"
}

@test "normalizes a conventional ACR login server and omits the suffix argument" {
	run_azure_acr_token GreyBodyGames.azurecr.io
	[ "$status" -eq 0 ]
	mapfile -t arguments < "$arguments_file"
	[ "${arguments[*]}" = "acr login --name greybodygames --expose-token --query accessToken --output tsv" ]
	[ "$(wc -l < "$output_file")" -eq 2 ]
}

@test "rejects malformed login servers before invoking Azure CLI" {
	malformed_servers=(
		'https://greybodygames.azurecr.io'
		'greybodygames.azurecr.io/repository'
		'greybodygames.azurecr.io:443'
		'grey_body_games.azurecr.io'
		'abcd.azurecr.io'
		'grey-body-games.azurecr.io'
		'greybodygames-.azurecr.io'
		'greybodygames.azurecr.io.evil.example'
		'greybodygames.azurecr.io '
	)
	for login_server in "${malformed_servers[@]}"; do
		run_azure_acr_token "$login_server"
		[ "$status" -ne 0 ]
		[ ! -s "$arguments_file" ]
		[ ! -s "$output_file" ]
	done
}

@test "fails without publishing outputs when Azure CLI returns an empty token" {
	run_azure_acr_token greybodygames.azurecr.io ''
	[ "$status" -ne 0 ]
	[[ "$output" == *'Azure CLI returned an empty Azure Container Registry access token'* ]]
	[[ "$output" != *'::add-mask::'* ]]
	[ ! -s "$output_file" ]
}
