#!/bin/bash
# Print the specified file at "$1" to stdout, replacing its version with the
# highest semantic-version tag reachable from HEAD.

set -o errexit
set -o nounset
set -o pipefail
# set -x

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 INFO_LUA_TEMPLATE" >&2
  exit 2
fi

# Non-release tags may exist on development branches. Select only an exact
# vMAJOR.MINOR.PATCH tag that is an ancestor of the source being built.
VERSION_TAG=''
while IFS= read -r tag; do
  if [[ $tag =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    VERSION_TAG=$tag
    MAJOR_VERSION=${BASH_REMATCH[1]}
    MINOR_VERSION=${BASH_REMATCH[2]}
    PATCH_VERSION=${BASH_REMATCH[3]}
    break
  fi
done < <(git tag --merged HEAD --sort=-version:refname)

if [[ -z $VERSION_TAG ]]; then
  echo "No vMAJOR.MINOR.PATCH tag is reachable from HEAD" >&2
  exit 1
fi

BUILD_NUMBER=$(git rev-list --count HEAD)

VERSION_SPEC="VERSION = { major=${MAJOR_VERSION}, minor=${MINOR_VERSION}, revision=${PATCH_VERSION}, build=${BUILD_NUMBER} },"

sed "s/VERSION = .*/$VERSION_SPEC/" "$1"
