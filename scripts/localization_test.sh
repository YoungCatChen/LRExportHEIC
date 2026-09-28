#!/bin/bash
# Validates the dictionary encoding and syntax, then checks that source and
# translation keys match exactly without missing, duplicate, or stale entries.

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
dictionary="$repo_root/LRPlugin/TranslatedStrings_zh_cn.txt"
source_keys=$(mktemp)
translation_keys=$(mktemp)
trap 'rm -f "$source_keys" "$translation_keys"' EXIT

iconv -f UTF-8 -t UTF-8 "$dictionary" >/dev/null

invalid_lines=$(
  rg --line-number --invert-match \
    '^("\$\$\$/LRExportHEIC/[A-Za-z0-9/]+=.+")?$' \
    "$dictionary" || true
)
if [[ -n "$invalid_lines" ]]; then
  echo "Invalid localization dictionary lines:" >&2
  echo "$invalid_lines" >&2
  exit 1
fi

rg --no-filename --only-matching \
  '\$\$\$/LRExportHEIC/[A-Za-z0-9/]+' \
  "$repo_root/LRPlugin" \
  --glob '*.lua' \
  --glob '*.lua.template' \
  | sort -u >"$source_keys"

rg --no-filename --only-matching \
  '\$\$\$/LRExportHEIC/[A-Za-z0-9/]+' \
  "$dictionary" \
  | sort >"$translation_keys"

duplicates=$(uniq -d "$translation_keys")
if [[ -n "$duplicates" ]]; then
  echo "Duplicate localization keys:" >&2
  echo "$duplicates" >&2
  exit 1
fi

missing=$(comm -23 "$source_keys" "$translation_keys")
extra=$(comm -13 "$source_keys" "$translation_keys")
if [[ -n "$missing" || -n "$extra" ]]; then
  if [[ -n "$missing" ]]; then
    echo "Missing zh_cn translations:" >&2
    echo "$missing" >&2
  fi
  if [[ -n "$extra" ]]; then
    echo "Unused zh_cn translations:" >&2
    echo "$extra" >&2
  fi
  exit 1
fi

echo "Localization keys are synchronized."
