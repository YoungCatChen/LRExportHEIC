# Lightroom HDR TIFF Structure

This document records the structure observed in TIFF files exported by
Lightroom Classic with HDR Output enabled. The Maximum Compatibility form uses
private TIFF tags around standard ISO 21496-1 gain-map metadata; treat the
layout as an observed Lightroom implementation detail, not a stable TIFF
extension contract.

## Export modes

For the tested Lightroom Classic version, Maximum Compatibility changes the HDR
representation rather than merely adding a flattened preview:

| Export | Primary | Additional HDR data |
|---|---|---|
| TIFF, Maximum Compatibility off | 16-bit PQ HDR | None |
| TIFF, Maximum Compatibility on | 16-bit sRGB SDR | RGB gain map in a SubIFD |
| JPEG XL, Maximum Compatibility off | 16-bit PQ HDR | None |
| JPEG XL, Maximum Compatibility on | 16-bit sRGB SDR | RGB gain map in `jhgm` |

In the measured matching exports:

- the TIFF and JPEG XL SDR primaries were pixel-identical;
- the ordinary TIFF and JPEG XL PQ renditions were pixel-identical;
- the compatibility files contained the same 141-byte ISO gain-map metadata;
- both gain maps were full-resolution, three-channel, and 16-bit before lossy
  container encoding.

The TIFF path is attractive because ZIP-compressed TIFF preserves the Lightroom
gain-map pixels losslessly and renders much faster than JPEG XL in Lightroom.

## TIFF organization

The observed file is organized as follows:

```text
TIFF header
└── IFD0
    ├── 16-bit sRGB SDR primary image
    └── SubIFDs tag (330)
        └── private gain-map IFD
            ├── full-resolution 16-bit RGB samples
            ├── PhotometricInterpretation = 52553
            └── tag 52557 = gain-map metadata
```

The gain map is not a normal second page and is not a thumbnail. Software that
only follows the main IFD chain will see an ordinary SDR TIFF.

### Relevant TIFF fields

A decoder must follow the standard TIFF byte-order marker and IFD offsets. The
gain-map SubIFD then uses ordinary image-storage fields for its raster data,
including dimensions, bits per sample, samples per pixel, strip offsets, strip
byte counts, compression, predictor, and sample format.

The tested export used:

- ZIP/Deflate compression;
- horizontal differencing predictor 2;
- 16-bit unsigned RGB samples;
- full-resolution geometry matching the primary;
- private photometric interpretation `52553`;
- private metadata tag `52557`.

Do not hard-code these compression and tiling details. Lightroom may choose
strips or tiles, change rows per strip, or emit a different supported TIFF
compression in another version or export configuration.

## Private tag 52557

The observed tag contains 145 bytes:

```text
4-byte Lightroom TIFF prefix
141-byte ISO gain-map metadata payload
```

The 141-byte suffix was byte-for-byte identical to the `jhgm` metadata box in a
matching Maximum Compatibility JPEG XL export.

Within the observed payload:

```text
4-byte metadata version header
1-byte flags
base headroom rational
alternate headroom rational
per-channel reconstruction fields
```

The flags identify one versus three channels and whether reconstruction uses
the base color space. Each rational is stored as an eight-byte numerator and
denominator pair in big-endian order. Signed fields use a signed 32-bit
numerator. Per-channel fields are:

```text
gain-map minimum
gain-map maximum
gamma
base offset
alternate offset
```

A three-channel payload contains one set for red, green, and blue. A
single-channel payload applies the same reconstruction parameters to all color
channels.

This byte layout is an empirical observation. A parser must validate:

- TIFF byte order and all offsets before reading;
- tag type and byte count;
- nonzero rational denominators;
- reserved flag bits;
- channel count and exact remaining payload size;
- image dimensions, sample count, and supported compression;
- allocation sizes and integer overflow before decoding pixels.

If validation fails, fall back to the two-rendition export path rather than
guessing.

## Inspect the container

List the main TIFF directories and tags:

```sh
tiffinfo 'maximum-compatible.tif'

exiftool -G1 -a -s -n \
  -ImageWidth \
  -ImageHeight \
  -BitsPerSample \
  -Compression \
  -PhotometricInterpretation \
  -SubIFD \
  'maximum-compatible.tif'
```

Once the SubIFD offset is known, libtiff tools can address it directly:

```sh
tiffcp -o SUBIFD_OFFSET \
  'maximum-compatible.tif' \
  /tmp/gain-map.tif

tiffinfo /tmp/gain-map.tif
```

Extract the private metadata bytes without interpreting them:

```sh
exiftool -b -Unknown_0xcd4d \
  'maximum-compatible.tif' > /tmp/gain-map-metadata.bin
```

ExifTool naming for unknown private tags can vary. Confirm that hexadecimal
`0xcd4d` is decimal `52557` and verify the extracted byte count.

## ImageIO behavior

ImageIO decodes IFD0 as the SDR primary but does not expose Lightroom's private
SubIFD as `kCGImageAuxiliaryDataTypeISOGainMap`. Consequently:

- opening the TIFF as an ordinary `CIImage` returns the SDR primary;
- requesting `.auxiliaryHDRGainMap` returns no recognized auxiliary image;
- requesting `.expandToHDR` cannot reconstruct the hidden HDR rendition;
- an inspection tool that relies only on ImageIO reports a false-negative
  SDR-only result.

Reading this representation therefore requires a TIFF adapter even though
ImageIO can author a final HEIF gain-map container.

## Possible conversion pipeline

A converter that preserves the embedded map would need this path:

```text
Maximum Compatibility TIFF
        │
        ├── IFD0 ───────────────→ SDR primary pixels
        │
        └── private SubIFD
              ├── raster data ──→ RGB gain-map pixels
              └── tag 52557 ────→ ISO reconstruction metadata

SDR primary + gain pixels + metadata
        │
        └── CGImageDestinationAddAuxiliaryDataInfo
                    ↓
              ISO tmap HEIC
```

One implementation can avoid a TIFF pixel decoder by making an in-memory copy
of the TIFF, redirecting the header's first-IFD pointer to the gain-map SubIFD,
and changing only its private photometric value to ordinary RGB. ImageIO can
then perform the strip or tile and compression decoding without modifying the
source file.

This adapter deliberately parses only enough TIFF structure to locate and
validate the SubIFD and metadata. It does not duplicate ImageIO's TIFF pixel
decoder.

The output gain map could be spatially downsampled before it is handed to
ImageIO. Resampling must occur in encoded gain space with the reconstruction
metadata kept consistent; do not treat the samples as an ordinary display RGB
image.

## Compatibility and fallback policy

The private TIFF structure may change without notice. A production importer
should:

1. Detect the expected SubIFD and private tags.
2. Validate every structural and metadata assumption.
3. Decode without modifying the source file.
4. Emit diagnostics describing the detected layout.
5. Fall back to separate SDR and HDR Lightroom renditions on any unsupported
   variation.

LRExportHEIC does not import this private representation. Its supported
adaptive-HDR path requests separate authored SDR and HDR renditions, then lets
ImageIO generate and compress the final gain map. This avoids depending on the
private TIFF layout and on the low-level auxiliary attachment path, whose gain
map compression quality is not controllable through public API.
