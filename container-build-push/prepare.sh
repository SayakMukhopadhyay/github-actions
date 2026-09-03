#!/usr/bin/env bash

set -euo pipefail

version=${INPUT_VERSION:?version is required}
component=${INPUT_COMPONENT:-}
registry=${INPUT_REGISTRY:-ghcr.io}
repository=${INPUT_IMAGE_REPOSITORY:-}
[[ -n "$repository" ]] || repository=${SOURCE_REPOSITORY:?github.repository is required}

image_name="${registry,,}/${repository,,}"
[[ -z "$component" ]] || image_name="$image_name/${component,,}"
printf 'image-reference=%s:%s\n' "$image_name" "$version" >>"$GITHUB_OUTPUT"
printf 'created=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" >>"$GITHUB_OUTPUT"
