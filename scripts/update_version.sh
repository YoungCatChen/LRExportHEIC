#!/bin/bash
# Print the specified file at "$1" to stdout, but replacing the version with
# the latest git tag.

set -o errexit
set -o nounset
set -o pipefail
# set -x

# Assuming `git fetch --tags` was run.
GIT_VERSION=$(git describe --tags $(git rev-list --tags --max-count=1))
MAJOR_VERSION=$(echo $GIT_VERSION | cut -f 1 -d . | tr -d 'v')
MINOR_VERSION=$(echo $GIT_VERSION | cut -f 2 -d .)
PATCH_VERSION=$(echo $GIT_VERSION | cut -f 3 -d .)
BUILD_NUMBER=$(git rev-list --all --count)

VERSION_SPEC="VERSION = { major=${MAJOR_VERSION}, minor=${MINOR_VERSION}, revision=${PATCH_VERSION}, build=${BUILD_NUMBER} },"

sed "s/VERSION = .*/$VERSION_SPEC/" "$1"
