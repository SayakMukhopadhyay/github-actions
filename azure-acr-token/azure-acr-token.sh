#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

login_server=${INPUT_LOGIN_SERVER:?login-server is required}
normalized_login_server=${login_server,,}
login_server_pattern='^([a-z0-9]{5,50})(-([a-z0-9]+))?\.azurecr\.io$'

[[ "$login_server" =~ ^[A-Za-z0-9.-]+$ ]] || fail "login-server must be an Azure Container Registry host without a scheme, path, port, or whitespace"
[[ "$normalized_login_server" =~ $login_server_pattern ]] || fail "login-server must match <registry>.azurecr.io or <registry>-<suffix>.azurecr.io"

registry_name=${BASH_REMATCH[1]}
suffix=${BASH_REMATCH[3]:-}
login_label=${normalized_login_server%.azurecr.io}
[[ ${#login_label} -le 63 ]] || fail "login-server has an invalid DNS label length"

command -v az > /dev/null || fail "Azure CLI is required"

az_arguments=(
  acr
  login
  --name
  "$registry_name"
)
if [[ -n "$suffix" ]]; then
  az_arguments+=(--suffix "$suffix")
fi
az_arguments+=(
  --expose-token
  --query
  accessToken
  --output
  tsv
)

if ! access_token=$(az "${az_arguments[@]}"); then
  fail "Azure CLI failed to expose an Azure Container Registry access token"
fi
[[ -n "$access_token" ]] || fail "Azure CLI returned an empty Azure Container Registry access token"
[[ "$access_token" != *$'\n'* && "$access_token" != *$'\r'* ]] || fail "Azure CLI returned an invalid multiline Azure Container Registry access token"

username=00000000-0000-0000-0000-000000000000
printf '::add-mask::%s\n' "$access_token"
{
  printf 'username=%s\n' "$username"
  printf 'access-token=%s\n' "$access_token"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
