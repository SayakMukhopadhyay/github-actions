#!/usr/bin/env bash

set -euo pipefail

readonly MAX_RELEASE_BODY_BYTES=120000

die() {
  printf 'create-release: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" > /dev/null 2>&1 || die "required command not found: $1"
}

require_value() {
  local name=$1 value=$2
  [[ -n "$value" ]] || die "$name is required"
}

validate_release_response() {
  local response_file=$1
  jq -e '
		type == "object" and
		(.id | type == "number" and . > 0 and floor == .) and
		(.html_url | type == "string" and startswith("https://") and (contains("\n") | not) and (contains("\r") | not)) and
		(.upload_url | type == "string" and startswith("https://") and (contains("\n") | not) and (contains("\r") | not))
	' "$response_file" > /dev/null
}

write_outputs() {
  local response_file=$1 release_id html_url upload_url
  validate_release_response "$response_file" || die 'GitHub returned malformed release details'
  release_id=$(jq -r '.id' "$response_file")
  html_url=$(jq -r '.html_url' "$response_file")
  upload_url=$(jq -r '.upload_url' "$response_file")
  {
    printf 'release-id=%s\n' "$release_id"
    printf 'html-url=%s\n' "$html_url"
    printf 'upload-url=%s\n' "$upload_url"
  } >> "$GITHUB_OUTPUT"
}

get_release() {
  local endpoint=$1 response_file=$2 error_file=$3
  if GH_TOKEN="$github_token" GH_HOST="$github_host" \
    gh api --method GET "$endpoint" > "$response_file" 2> "$error_file"; then
    validate_release_response "$response_file" || return 2
    return 0
  fi
  if grep -Eq '(^|[^0-9])404([^0-9]|$)' "$error_file"; then
    return 1
  fi
  return 2
}

github_token=${INPUT_TOKEN:-}
release_name=${INPUT_RELEASE_NAME:-}
facts_file=${FACTS_FILE:-}
body_file=${BODY_FILE:-}
runner_temp=${RUNNER_TEMP:-}
publish_mode=${PUBLISH_MODE:-publish}

require_value token "$github_token"
require_value facts-file "$facts_file"
require_value RUNNER_TEMP "$runner_temp"
require_value GITHUB_OUTPUT "${GITHUB_OUTPUT:-}"
[[ "$publish_mode" == check || "$publish_mode" == publish ]] || die 'PUBLISH_MODE must be check or publish'
[[ "$github_token" != *$'\n'* && "$github_token" != *$'\r'* ]] \
  || die 'token contains an invalid line break'

require_command gh
require_command jq

umask 077

[[ -f "$facts_file" && ! -L "$facts_file" ]] || die 'facts-file must be a regular file'
runner_temp=$(realpath -- "$runner_temp")
facts_file=$(realpath -- "$facts_file")
case "$facts_file" in
  "$runner_temp"/*) ;;
  *) die 'facts-file must be contained by RUNNER_TEMP' ;;
esac
session_directory=$(dirname -- "$facts_file")

if [[ "$publish_mode" == publish ]]; then
  require_value release-name "$release_name"
  require_value body-file "$body_file"
  [[ -f "$body_file" && ! -L "$body_file" ]] || die 'body-file must be a regular file'
  body_file=$(realpath -- "$body_file")
  case "$body_file" in
    "$runner_temp"/*) ;;
    *) die 'body-file must be contained by RUNNER_TEMP' ;;
  esac
  [[ $(dirname -- "$facts_file") == "$(dirname -- "$body_file")" ]] \
    || die 'release handoff files must share one session directory'
  body_size=$(wc -c < "$body_file")
  ((body_size > 0 && body_size <= MAX_RELEASE_BODY_BYTES)) \
    || die 'release body is empty or exceeds the maximum size'
fi

if ! jq -e \
  --argjson maxRepositoryLength 256 \
  --argjson maxServerUrlLength 255 \
  --argjson maxTagNameLength 255 \
  --argjson maxRenderedCommits 48 '
	type == "object" and
	(keys | sort) == (["commits", "omittedCommitCount", "previousObject", "previousTag", "repository", "schemaVersion", "serverUrl", "tagName", "targetCommit", "targetObject"] | sort) and
	.schemaVersion == 1 and
	(.repository | type == "string" and length <= $maxRepositoryLength and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
	(.serverUrl | type == "string" and length <= $maxServerUrlLength and test("^https://[A-Za-z0-9.-]+(:[0-9]+)?$")) and
	(.tagName | type == "string" and length > 0 and length <= $maxTagNameLength and (contains("\n") | not) and (contains("\r") | not)) and
	(.targetObject | type == "string" and test("^[0-9a-fA-F]{40,64}$")) and
	(.targetCommit | type == "string" and test("^[0-9a-fA-F]{40,64}$")) and
	((.previousTag == null and .previousObject == null) or
	 ((.previousTag | type == "string" and length > 0 and length <= $maxTagNameLength and (contains("\n") | not) and (contains("\r") | not)) and
	  (.previousObject | type == "string" and test("^[0-9a-fA-F]{40,64}$")))) and
	(.omittedCommitCount | type == "number" and floor == . and . >= 0) and
	(.commits | type == "array" and length <= $maxRenderedCommits and all(.[];
		type == "object" and
		(keys | sort) == ["sha", "subject"] and
		(.sha | type == "string" and test("^[0-9a-fA-F]{40,64}$")) and
		(.subject | type == "string" and length > 0 and length <= 240 and
			all(explode[]; . >= 32 and . != 127))))
' "$facts_file" > /dev/null; then
  die 'release facts are malformed'
fi

target_repository=$(jq -r '.repository' "$facts_file")
server_url=$(jq -r '.serverUrl' "$facts_file")
tag_name=$(jq -r '.tagName' "$facts_file")
target_object=$(jq -r '.targetObject' "$facts_file")
github_host=${server_url#https://}
encoded_tag=$(jq -nr --arg value "$tag_name" '$value | @uri')

temp_directory="$session_directory/publisher"
mkdir -p -- "$temp_directory"
tag_response="$temp_directory/tag-response.json"
github_error="$temp_directory/github-error"
tag_endpoint="repos/$target_repository/git/ref/tags/$encoded_tag"
if ! GH_TOKEN="$github_token" GH_HOST="$github_host" \
  gh api --method GET "$tag_endpoint" > "$tag_response" 2> "$github_error"; then
  die "could not reverify remote tag before release creation: $tag_name"
fi
remote_object=$(jq -er --arg expectedRef "refs/tags/$tag_name" '
	select(.ref == $expectedRef) |
	select(.object.type == "commit" or .object.type == "tag") |
	.object.sha | select(type == "string" and test("^[0-9a-fA-F]{40,64}$"))
' "$tag_response") \
  || die 'GitHub returned malformed tag details'
[[ "${remote_object,,}" == "${target_object,,}" ]] \
  || die "remote tag moved during release creation: $tag_name"

previous_tag=$(jq -r '.previousTag // empty' "$facts_file")
if [[ -n "$previous_tag" ]]; then
  previous_object=$(jq -r '.previousObject' "$facts_file")
  encoded_previous_tag=$(jq -nr --arg value "$previous_tag" '$value | @uri')
  previous_tag_endpoint="repos/$target_repository/git/ref/tags/$encoded_previous_tag"
  if ! GH_TOKEN="$github_token" GH_HOST="$github_host" \
    gh api --method GET "$previous_tag_endpoint" > "$tag_response" 2> "$github_error"; then
    die "could not reverify previous remote tag before release creation: $previous_tag"
  fi
  remote_previous_object=$(jq -er --arg expectedRef "refs/tags/$previous_tag" '
	select(.ref == $expectedRef) |
	select(.object.type == "commit" or .object.type == "tag") |
	.object.sha | select(type == "string" and test("^[0-9a-fA-F]{40,64}$"))
' "$tag_response") \
    || die 'GitHub returned malformed previous-tag details'
  [[ "${remote_previous_object,,}" == "${previous_object,,}" ]] \
    || die "previous remote tag moved during release creation: $previous_tag"
fi

release_endpoint="repos/$target_repository/releases/tags/$encoded_tag"
release_response="$temp_directory/release-response.json"
if get_release "$release_endpoint" "$release_response" "$github_error"; then
  write_outputs "$release_response"
  printf 'release-exists=true\n' >> "$GITHUB_OUTPUT"
  printf 'GitHub Release already exists for %s; returning it unchanged.\n' "$tag_name"
  exit 0
else
  get_release_status=$?
  ((get_release_status == 1)) || die 'could not check for an existing GitHub Release'
fi

if [[ "$publish_mode" == check ]]; then
  printf 'release-exists=false\n' >> "$GITHUB_OUTPUT"
  exit 0
fi

create_request="$temp_directory/create-request.json"
jq -n --arg tag "$tag_name" --arg name "$release_name" --rawfile body "$body_file" '
	{
		tag_name: $tag,
		name: $name,
		body: $body,
		draft: false,
		prerelease: false,
		generate_release_notes: false
	}
' > "$create_request"

create_endpoint="repos/$target_repository/releases"
if GH_TOKEN="$github_token" GH_HOST="$github_host" \
  gh api --method POST "$create_endpoint" --input "$create_request" > "$release_response" 2> "$github_error"; then
  write_outputs "$release_response"
  printf 'Created published GitHub Release for %s.\n' "$tag_name"
  exit 0
fi

# A concurrent retry may have created the release after the final preflight check.
if get_release "$release_endpoint" "$release_response" "$github_error"; then
  write_outputs "$release_response"
  printf 'GitHub Release was created concurrently; returning it unchanged.\n'
  exit 0
fi

die 'GitHub Release creation failed'
