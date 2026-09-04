#!/usr/bin/env bash

set -euo pipefail

install_directory=${1:?usage: install-actionlint.sh INSTALL_DIRECTORY}
version=${ACTIONLINT_VERSION:?ACTIONLINT_VERSION is required}
expected_sha256=${ACTIONLINT_SHA256:?ACTIONLINT_SHA256 is required}

[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'Invalid actionlint version: %s\n' "$version" >&2
  exit 1
}
[[ $expected_sha256 =~ ^[0-9a-f]{64}$ ]] || {
  printf 'Invalid actionlint SHA-256: %s\n' "$expected_sha256" >&2
  exit 1
}

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

archive="actionlint_${version}_linux_amd64.tar.gz"
gh release download "v$version" \
  --repo rhysd/actionlint \
  --pattern "$archive" \
  --dir "$temporary_directory"

printf '%s  %s\n' "$expected_sha256" "$temporary_directory/$archive" | sha256sum --check --strict
gh attestation verify "$temporary_directory/$archive" --repo rhysd/actionlint

tar -xzf "$temporary_directory/$archive" -C "$temporary_directory" actionlint
mkdir -p "$install_directory"
install -m 0755 "$temporary_directory/actionlint" "$install_directory/actionlint"
