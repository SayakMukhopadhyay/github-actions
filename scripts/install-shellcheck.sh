#!/usr/bin/env bash

set -euo pipefail

version=${SHELLCHECK_VERSION:?SHELLCHECK_VERSION is required}
expected=${SHELLCHECK_SHA256:?SHELLCHECK_SHA256 is required}
archive="${RUNNER_TEMP:-/tmp}/shellcheck-v$version.tar.xz"
url="https://github.com/koalaman/shellcheck/releases/download/v$version/shellcheck-v$version.linux.x86_64.tar.xz"

curl --fail --location --silent --show-error --retry 3 --retry-all-errors --max-time 120 --output "$archive" "$url"
printf '%s  %s\n' "$expected" "$archive" | sha256sum --check --status
tar -xJf "$archive" -C "${RUNNER_TEMP:-/tmp}"
printf '%s\n' "${RUNNER_TEMP:-/tmp}/shellcheck-v$version" >>"$GITHUB_PATH"
