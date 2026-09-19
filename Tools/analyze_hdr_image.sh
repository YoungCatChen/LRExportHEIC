#!/bin/bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  Tools/analyze_hdr_image.sh [--json] IMAGE
  Tools/analyze_hdr_image.sh [--json] [--rendition auto|sdr|hdr|both] IMAGE_A IMAGE_B

One image prints its single-file facts and statistics. Two images also compare
every common rendition. The comparison never resizes, crops, or implicitly
tone-maps an input.
EOF
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
tool_path=${HDR_IMAGE_TOOL_BIN:-"$repo_root/build-debug/hdr-image-tool"}
rendition=auto
json=false
images=()

while (($# > 0)); do
  case "$1" in
    --json)
      json=true
      shift
      ;;
    --rendition)
      if (($# < 2)); then
        echo "error: --rendition requires a value" >&2
        exit 2
      fi
      rendition=$2
      shift 2
      ;;
    --rendition=*)
      rendition=${1#*=}
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      while (($# > 0)); do
        images+=("$1")
        shift
      done
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      images+=("$1")
      shift
      ;;
  esac
done

if ((${#images[@]} < 1 || ${#images[@]} > 2)); then
  usage >&2
  exit 2
fi

for image in "${images[@]}"; do
  if [[ ! -f "$image" ]]; then
    echo "error: image does not exist: $image" >&2
    exit 2
  fi
done

if [[ ! -x "$tool_path" ]]; then
  echo "error: HDR image tool is not built: $tool_path" >&2
  echo "Please run: make debug" >&2
  exit 2
fi

run_tool() {
  "$tool_path" "$@"
}

if [[ "$json" == true ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: --json requires jq" >&2
    exit 2
  fi

  first=$(run_tool inspect --json "${images[0]}")
  if ((${#images[@]} == 1)); then
    printf '%s\n' "$first"
    exit 0
  fi

  second=$(run_tool inspect --json "${images[1]}")
  comparison=$(run_tool compare \
    --json \
    --rendition "$rendition" \
    "${images[0]}" \
    "${images[1]}")
  jq -n \
    --argjson inputA "$first" \
    --argjson inputB "$second" \
    --argjson comparison "$comparison" \
    '{inputA: $inputA, inputB: $inputB, comparison: $comparison}'
  exit 0
fi

print_external_summary() {
  local image=$1
  local extension
  extension=$(printf '%s' "${image##*.}" | tr '[:upper:]' '[:lower:]')

  if command -v file >/dev/null 2>&1; then
    echo
    echo "File identification"
    file "$image"
  fi

  if command -v exiftool >/dev/null 2>&1; then
    echo
    echo "Selected metadata"
    exiftool \
      -G1 -a -s -n \
      -FileType -ImageWidth -ImageHeight -BitsPerSample \
      -ProfileDescription -ColorPrimaries -TransferCharacteristics \
      -MatrixCoefficients -VideoFullRangeFlag -ImagePixelDepth \
      -MajorBrand -CompatibleBrands -PrimaryItemReference \
      -NumberOfImages -MPImageType -Copyright \
      "$image"
  fi

  case "$extension" in
    heic | heif | hif | avif)
      if command -v heif-info >/dev/null 2>&1; then
        echo
        echo "HEIF structure"
        heif-info "$image"
      fi
      ;;
    jxl)
      if command -v jxlinfo >/dev/null 2>&1; then
        echo
        echo "JPEG XL structure"
        jxlinfo "$image"
      fi
      ;;
  esac
}

for index in "${!images[@]}"; do
  label=A
  if ((index == 1)); then
    label=B
  fi
  echo "Input $label"
  echo "======="
  run_tool inspect "${images[index]}"
  print_external_summary "${images[index]}"
  if ((index + 1 < ${#images[@]})); then
    echo
  fi
done

if ((${#images[@]} == 2)); then
  echo
  echo "Comparison"
  echo "=========="
  run_tool compare \
    --rendition "$rendition" \
    "${images[0]}" \
    "${images[1]}"
fi
