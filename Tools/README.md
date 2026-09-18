# HDR image tools

`hdr-image-tool` is a macOS-only diagnostic executable for inspecting,
extracting, comparing, encoding, and verifying SDR, native HDR, and adaptive
HDR images. It uses Core Image and ImageIO so comparisons are performed after
color-managed rendering into a documented common domain.

Build the development plugin and diagnostic tool:

```sh
make debug
build-debug/hdr-image-tool help
```

`Tools/analyze_hdr_image.sh` runs the stable
`build-debug/hdr-image-tool` symlink. It does not invoke Swift Package Manager
or build implicitly. If the binary is unavailable, run `make debug`. Advanced
usage can override the executable with `HDR_IMAGE_TOOL_BIN`.

Debug builds target the current Mac architecture, matching the development
plugin's documented local-machine scope. Release packaging remains responsible
for distributable architecture and signing requirements.

The convenience wrapper accepts one or two images:

```sh
Tools/analyze_hdr_image.sh image.heic
Tools/analyze_hdr_image.sh image.heic reference-sdr.tif
Tools/analyze_hdr_image.sh image.heic reference-hdr.tif
Tools/analyze_hdr_image.sh adaptive-a.heic adaptive-b.jpg
```

With one input, the wrapper prints single-file facts and statistics. With two
inputs, it also compares every rendition both files expose:

- SDR against SDR in encoded sRGB normalized to `[0,1]`.
- HDR against HDR in ITU-R BT.2100 PQ normalized to `[0,1]`.
- Adaptive HDR against SDR using the adaptive image's primary rendition.
- Adaptive HDR against native HDR using the reconstructed HDR rendition.

SDR-only and HDR-only inputs have no common rendition. The wrapper reports the
reason and does not silently tone-map either file. Comparisons never resize or
crop inputs.

Use `--rendition sdr`, `--rendition hdr`, or `--rendition both` to require a
specific comparison. Use `--json` for machine-readable output. JSON mode also
requires `jq`.

Additional commands:

```sh
build-debug/hdr-image-tool extract \
  --output-dir /tmp/hdr-renditions \
  image.heic

build-debug/hdr-image-tool encode-heic \
  --sdr sdr.tif \
  --hdr hdr.tif \
  --gain-map rgb \
  --quality 0.9 \
  --output output.heic

build-debug/hdr-image-tool verify-heic \
  --sdr-reference sdr.tif \
  --hdr-reference hdr.tif \
  output.heic
```

The wrapper uses `file` and, when available, `exiftool`, `heif-info`, and
`jxlinfo` to add container-specific information. The Swift executable itself
does not require those optional command-line tools.

See [HDR and Gain Map Reference](../docs/hdr_gain_map_reference.md) for the
underlying representation, color-management, and validation model.
