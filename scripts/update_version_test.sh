#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
REPOSITORY_ROOT=$(cd "$SCRIPT_DIRECTORY/.." && pwd)
TEMPORARY_REPOSITORY=$(mktemp -d "${TMPDIR:-/tmp}/update-version.XXXXXX")
trap 'rm -rf "$TEMPORARY_REPOSITORY"' EXIT

git -C "$TEMPORARY_REPOSITORY" init --quiet
git -C "$TEMPORARY_REPOSITORY" config user.email version-test
git -C "$TEMPORARY_REPOSITORY" config user.name Test
git -C "$TEMPORARY_REPOSITORY" commit --quiet --allow-empty -m Initial
git -C "$TEMPORARY_REPOSITORY" tag v2.1.2
git -C "$TEMPORARY_REPOSITORY" switch --quiet -c feature
git -C "$TEMPORARY_REPOSITORY" commit --quiet --allow-empty -m Feature
git -C "$TEMPORARY_REPOSITORY" tag test-fixtures-v1
git -C "$TEMPORARY_REPOSITORY" switch --quiet --orphan unrelated
git -C "$TEMPORARY_REPOSITORY" commit --quiet --allow-empty -m Unrelated
git -C "$TEMPORARY_REPOSITORY" tag v99.0.0
git -C "$TEMPORARY_REPOSITORY" switch --quiet feature

output=$(
  cd "$TEMPORARY_REPOSITORY"
  "$REPOSITORY_ROOT/scripts/update_version.sh" \
    "$REPOSITORY_ROOT/LRPlugin/Info.lua.template"
)

expected='VERSION = { major=2, minor=1, revision=2, build=2 },'
if ! grep -Fq "$expected" <<< "$output"; then
  echo "Expected generated Info.lua to contain: $expected" >&2
  exit 1
fi
