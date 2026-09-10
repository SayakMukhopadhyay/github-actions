#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'argocd-verify-deployment: %s\n' "$*" >&2
  exit 1
}

require_single_line() {
  local name=$1 value=$2
  [[ -n $value && $value != *$'\n'* && $value != *$'\r'* ]] || fail "$name must be a non-empty single-line value"
}

require_single_line server "${INPUT_SERVER:-}"
require_single_line application "${INPUT_APPLICATION:-}"
require_single_line auth-token "${INPUT_AUTH_TOKEN:-}"
require_single_line cloudflare-access-client-id "${INPUT_CLOUDFLARE_ACCESS_CLIENT_ID:-}"
require_single_line cloudflare-access-client-secret "${INPUT_CLOUDFLARE_ACCESS_CLIENT_SECRET:-}"
require_single_line expected-commit-sha "${INPUT_EXPECTED_COMMIT_SHA:-}"
require_single_line timeout-seconds "${INPUT_TIMEOUT_SECONDS:-}"
require_single_line argocd-cli-path "${ARGOCD_CLI_PATH:-}"
require_single_line gitops-checkout-path "${GITOPS_CHECKOUT_PATH:-}"
[[ $INPUT_EXPECTED_COMMIT_SHA =~ ^[0-9a-f]{40}$ ]] || fail 'expected-commit-sha must be a full lowercase 40-character Git SHA'
[[ $INPUT_TIMEOUT_SECONDS =~ ^[1-9][0-9]*$ ]] || fail 'timeout-seconds must be a positive integer'
[[ -x $ARGOCD_CLI_PATH ]] || fail "verified Argo CD CLI is not executable: $ARGOCD_CLI_PATH"
[[ -d $GITOPS_CHECKOUT_PATH/.git ]] || fail "GitOps checkout is unavailable: $GITOPS_CHECKOUT_PATH"

export ARGOCD_AUTH_TOKEN=$INPUT_AUTH_TOKEN
unset INPUT_AUTH_TOKEN

argocd_arguments=(
  --server "$INPUT_SERVER"
  --grpc-web
  --header "CF-Access-Client-Id: $INPUT_CLOUDFLARE_ACCESS_CLIENT_ID"
  --header "CF-Access-Client-Secret: $INPUT_CLOUDFLARE_ACCESS_CLIENT_SECRET"
)

application_json=$(mktemp)
application_error=$(mktemp)
cleanup() {
  rm -f -- "$application_json" "$application_error"
}
trap cleanup EXIT

set +e
"$ARGOCD_CLI_PATH" "${argocd_arguments[@]}" app wait "$INPUT_APPLICATION" \
  --sync --health --timeout "$INPUT_TIMEOUT_SECONDS" --output json > "$application_json" 2> "$application_error"
argocd_status=$?
set -e

application_state=$(
  # shellcheck disable=SC2016 # JavaScript template literals must not expand in Bash.
  node -e '
    let source = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { source += chunk; });
    process.stdin.on("end", () => {
      const application = JSON.parse(source);
      const sync = typeof application?.status?.sync?.status === "string" ? application.status.sync.status : "";
      const health = typeof application?.status?.health?.status === "string" ? application.status.health.status : "";
      const revision = typeof application?.status?.sync?.revision === "string" ? application.status.sync.revision : "";
      process.stdout.write(`${sync}\n${health}\n${revision}\n`);
    });
  ' < "$application_json" 2> /dev/null
) || application_state=''
mapfile -t application_fields <<< "$application_state"
sync_status=${application_fields[0]:-}
health_status=${application_fields[1]:-}
synchronized_revision=${application_fields[2]:-}

if [[ $health_status == Degraded || $health_status == Missing || $health_status == Unknown ]]; then
  fail "Application '$INPUT_APPLICATION' is unhealthy (sync=$sync_status, health=$health_status)"
fi
if ((argocd_status != 0)); then
  if [[ -s $application_error ]]; then
    sed 's/^/argocd: /' "$application_error" >&2
  fi
  fail "Application '$INPUT_APPLICATION' did not become Synced and Healthy within ${INPUT_TIMEOUT_SECONDS}s"
fi
[[ $sync_status == Synced && $health_status == Healthy ]] \
  || fail "Argo CD returned success without a Synced and Healthy Application (sync=$sync_status, health=$health_status)"

[[ -n $synchronized_revision ]] || fail 'Argo CD did not report a synchronized revision'
[[ $synchronized_revision =~ ^[0-9a-f]{40}$ ]] \
  || fail "Argo CD reported an unavailable synchronized revision: $synchronized_revision"

git -C "$GITOPS_CHECKOUT_PATH" cat-file -e "$INPUT_EXPECTED_COMMIT_SHA^{commit}" 2> /dev/null \
  || fail "expected GitOps revision is unavailable: $INPUT_EXPECTED_COMMIT_SHA"
git -C "$GITOPS_CHECKOUT_PATH" cat-file -e "$synchronized_revision^{commit}" 2> /dev/null \
  || fail "synchronized GitOps revision is unavailable: $synchronized_revision"

if [[ $INPUT_EXPECTED_COMMIT_SHA != "$synchronized_revision" ]]; then
  set +e
  git -C "$GITOPS_CHECKOUT_PATH" merge-base --is-ancestor "$INPUT_EXPECTED_COMMIT_SHA" "$synchronized_revision"
  ancestry_status=$?
  set -e
  case $ancestry_status in
    0) ;;
    1) fail "expected GitOps revision $INPUT_EXPECTED_COMMIT_SHA is not an ancestor of synchronized revision $synchronized_revision" ;;
    *) fail 'Git could not verify the synchronized revision ancestry' ;;
  esac
fi

if [[ -n ${INPUT_SMOKE_URL:-} ]]; then
  require_single_line smoke-url "$INPUT_SMOKE_URL"
  curl --silent --show-error --fail --output /dev/null \
    --max-time "$INPUT_TIMEOUT_SECONDS" \
    --header "CF-Access-Client-Id: $INPUT_CLOUDFLARE_ACCESS_CLIENT_ID" \
    --header "CF-Access-Client-Secret: $INPUT_CLOUDFLARE_ACCESS_CLIENT_SECRET" \
    -- "$INPUT_SMOKE_URL" || fail "authenticated HTTP smoke test failed: $INPUT_SMOKE_URL"
fi

printf 'synchronized-revision=%s\n' "$synchronized_revision" >> "$GITHUB_OUTPUT"
printf 'Verified Argo CD Application %s at synchronized revision %s.\n' "$INPUT_APPLICATION" "$synchronized_revision"
