# ImageIO HEIF Authoring

This document describes the public Apple APIs that are relevant to SDR, native
HDR, and ISO gain-map HEIF authoring. It also records behavior verified on the
project's development system. Framework behavior can change between operating
system releases, so every output must be inspected and decoded after writing.

For gain-map terminology and validation principles, see
[HDR and Gain Map Reference](hdr-gain-maps.md). For an observed
Lightroom private gain-map container, see
[Lightroom HDR TIFF](lightroom-hdr-tiff.md).

## Representation choices

The primary image and the gain-map base image are the same image. The base can
be SDR or HDR; the gain-map metadata identifies the base and alternate
headrooms and determines the reconstruction direction.

| Requested result | ImageIO support | Preferred API |
|---|---|---|
| SDR primary only | Yes | `CIContext.writeHEIFRepresentation` |
| HDR primary only | Yes | `CIContext.writeHEIF10Representation` |
| SDR primary + computed HDR gain map | Yes | `.hdrImage` or staged encoding |
| HDR primary + computed SDR recovery map | No | Compute the inverse map, then attach it |
| SDR primary + existing HDR gain map | Yes | Low-level auxiliary-data API |
| HDR primary + existing SDR recovery map | Yes | Low-level auxiliary-data API |

The unsupported row is specifically automatic inverse-map generation. A legal
inverse map can still be encoded when the caller supplies its pixels and
metadata.

LRExportHEIC supports the first three rows only. Adaptive HDR output always
uses an authored SDR primary and HDR alternate in the high-level automatic
generation path. Existing gain maps and HDR-primary inverse maps are not
accepted because the low-level attachment path does not provide adequate
control over final auxiliary compression.

## Ordinary SDR and native HDR

`CIContext` can write both 8-bit and 10-bit HEIF representations:

```swift
let context = CIContext()

try context.writeHEIFRepresentation(
  of: image,
  to: outputURL,
  format: .RGBA8,
  colorSpace: outputColorSpace,
  options: options)

try context.writeHEIF10Representation(
  of: image,
  to: outputURL,
  colorSpace: outputColorSpace,
  options: options)
```

Bit depth and dynamic range are independent. A 10-bit image is not necessarily
HDR. Native HDR output also needs an HDR image and an appropriate HDR color
space, such as BT.2100 PQ.

Native HDR has no authored SDR fallback. An SDR-only consumer must tone-map the
HDR primary according to its own policy.

## Generate a gain map from SDR and HDR renditions

The established Core Image path takes an SDR primary and an HDR alternate:

```swift
var options: [CIImageRepresentationOption: Any] = [
  kCGImageDestinationLossyCompressionQuality
    as CIImageRepresentationOption: quality,
  .hdrImage: hdrAlternate,
  .hdrGainMapAsRGB: true,
  kCGImageDestinationEncodeRequest
    as CIImageRepresentationOption:
      kCGImageDestinationEncodeToISOGainmap,
]

try context.writeHEIF10Representation(
  of: sdrPrimary,
  to: outputURL,
  colorSpace: sdrColorSpace,
  options: options)
```

The two images must have matching geometry. The primary is the exact SDR
fallback stored in the file; Core Image derives the gain-map pixels and
reconstruction metadata from the HDR alternate.

Setting `kCGImageDestinationEncodeBaseIsSDR` to false does not reverse this
high-level operation. Tests on the current platform still produced an SDR-base
gain map, or a plain HDR image when the inputs were reversed.

### Staged encoding

The current ImageIO SDK also declares a staged interface using:

- `kCGImageDestinationEncodeIsBaseImage`;
- `kCGImageDestinationEncodeGenerateGainMapWithBaseImage`;
- `kCGImageDestinationEncodeBaseColorSpace`;
- `kCGImageDestinationEncodeAlternateColorSpace`;
- `kCGImageDestinationEncodeBasePixelFormatRequest`;
- `kCGImageDestinationEncodeGainMapPixelFormatRequest`;
- `kCGImageDestinationEncodeGainMapSubsampleFactor`.

This interface declares controls for gain-map pixel format and spatial
subsampling. It is newer than the simple `.hdrImage` interface and must be
guarded by the availability version imported by the build SDK.

The staged implementation still expects an SDR base followed by an
extended-range HDR alternate. It is not an automatic inverse-map generator.
Testing also found that adding only the staged subsampling key to the
high-level `.hdrImage` options is silently ignored, while an attempted direct
two-image staged call was not sufficiently stable for production use. The
project therefore does not currently depend on this interface.

LRExportHEIC does not use the staged interface. It supplies the SDR and HDR
renditions to the high-level `.hdrImage` path during every final encode and lets
ImageIO choose the gain-map resolution and coded representation.

## Attach an existing ISO gain map

The low-level ImageIO path accepts decoded gain-map samples and reconstruction
metadata without recomputing either:

```swift
CGImageDestinationAddImage(
  destination,
  primaryCGImage,
  primaryOptions as CFDictionary)

let auxiliaryInfo: [CFString: Any] = [
  kCGImageAuxiliaryDataInfoData: gainMapData,
  kCGImageAuxiliaryDataInfoDataDescription: [
    kCGImagePropertyWidth: gainMapWidth,
    kCGImagePropertyHeight: gainMapHeight,
    kCGImagePropertyBytesPerRow: gainMapBytesPerRow,
    kCGImagePropertyPixelFormat: gainMapPixelFormat,
  ],
  kCGImageAuxiliaryDataInfoMetadata: gainMapMetadata,
  kCGImageAuxiliaryDataInfoColorSpace: gainMapColorSpace,
]

CGImageDestinationAddAuxiliaryDataInfo(
  destination,
  kCGImageAuxiliaryDataTypeISOGainMap,
  auxiliaryInfo as CFDictionary)

guard CGImageDestinationFinalize(destination) else {
  throw EncodingError.couldNotFinalize
}
```

`kCGImageAuxiliaryDataTypeISOGainMap` is public on macOS 15 and newer. The
dictionary requires all of the following to agree:

- decoded pixel buffer layout;
- width, height, bytes per row, and Core Video pixel format;
- channel count and color space;
- ISO gain-map reconstruction metadata;
- whether the primary is the SDR or HDR base.

ImageIO encodes the supplied samples into a HEVC item and builds the HEIF
`tmap` relationship. Supplying raw pixels does not imply that their input bit
depth, RGB packing, or chroma layout will be preserved in the coded item.

### Apple gain-map metadata

ImageIO accepts reconstruction metadata as `CGImageMetadata` in this namespace:

```text
http://ns.apple.com/HDRToneMap/1.0/
```

The relevant paths are:

```text
HDRToneMap:Version
HDRToneMap:BaseHeadroom
HDRToneMap:AlternateHeadroom
HDRToneMap:BaseColorIsWorkingColor
HDRToneMap:ChannelMetadata
```

Each channel structure contains:

```text
GainMapMin
GainMapMax
Gamma
BaseOffset
AlternateOffset
```

Use three channel structures for an RGB gain map and one for a monochrome map.
Values are serialized as strings in the metadata tags even though their
meaning is numeric.

## Inverse gain maps

An inverse map uses an HDR primary as the base and reconstructs an SDR
alternate. ImageIO's low-level auxiliary API accepts this representation when
the supplied metadata describes it correctly, including:

```text
BaseHeadroom > AlternateHeadroom
```

The automatic `.hdrImage` and staged generation paths do not calculate this
inverse representation. The application must calculate the map or transform a
known forward representation, then attach the result through
`CGImageDestinationAddAuxiliaryDataInfo`.

ISO 21496-1 stores the gain magnitude from the SDR representation toward the
HDR representation regardless of which rendition is the base. The decoder
derives a signed interpolation weight from the ordering of `BaseHeadroom` and
`AlternateHeadroom`. Therefore, converting a generated forward map into its
equivalent inverse representation requires:

- preserving the encoded gain-map samples;
- preserving `GainMapMin`, `GainMapMax`, and `Gamma`;
- swapping base and alternate headroom;
- swapping base and alternate offsets;
- toggling `BaseColorIsWorkingColor`, so the same working color space remains
  selected after the renditions exchange roles.

Do not negate `GainMapMin`/`GainMapMax` or replace each encoded sample `u` with
`1-u`. That would apply the direction twice. This is easy to miss because a
container inspector will still report a structurally valid `tmap`.

The simplified reconstruction is:

```text
weight = sign(AlternateHeadroom - BaseHeadroom)
alternate =
  (base + baseOffset) * 2^(gainMagnitude * weight)
  - alternateOffset
```

For an HDR base and SDR alternate, `weight` is negative.

A caller can create an inverse map by first obtaining a normal SDR-primary map,
applying the metadata transformation above, and attaching the unchanged gain
samples to the original HDR primary. This preserves the same SDR/HDR
relationship without implementing a second gain-map estimator.

When validating an inverse map with Core Image, `image.applyingGainMap(map)`
selects the maximum available headroom and therefore returns the HDR base
unchanged. Request the SDR endpoint explicitly:

```swift
let sdrAlternate = hdrBase.applyingGainMap(gainMap, headroom: 1)
```

The project's analyzer detects the headroom ordering and uses this form for
inverse maps.

## Important ImageIO behavior

### High-level existing-map API is not equivalent

Core Image exposes `.hdrGainMapImage` and `.hdrGainMapAsRGB`, but experiments
with a Lightroom RGB ISO gain map produced a legacy monochrome auxiliary image
instead of preserving the three-channel ISO representation. With an HDR
primary, the high-level writer ignored the supplied inverse map.

Use the low-level auxiliary-data API when the caller already owns the gain-map
pixels and metadata.

### Quality controls differ by authoring path

For the high-level automatic-generation path, the ordinary ImageIO
compression-quality option is part of the operation that writes both the
primary and generated gain map. Supplying an independent auxiliary quality
option did not change the output in testing.

It was observed that automatic RGB gain-map compression follows approximately
the ordinary 8-bit HEIF quality scale, but with a quality floor near `0.9`.
Gain-map payload size remained constant while requested quality ranged from
`0.1` through `0.9`, then increased consistently with higher requested quality.
This resembles:

```text
gain_map_quality ≈ max(requested_quality, 0.9)
```

This relationship is observed behavior, not an API guarantee. It may change
with the OS, codec implementation, image content, or requested pixel format.

For the low-level `CGImageDestinationAddAuxiliaryDataInfo` path, the quality
property passed to `CGImageDestinationAddImage` controls the primary only. It
was observed that gain-map item sizes remained unchanged across the requested
quality range while primary item sizes changed substantially. The auxiliary API
takes raw pixels but exposes no separate compression-quality parameter, so its
encoder quality is controlled internally by ImageIO. Consequently, a
size-limited writer using this path can vary primary quality but retains a
nearly fixed gain-map payload.

Applications that need a strict size budget can control:

- overall quality;
- gain-map spatial resolution;
- RGB versus monochrome semantics where acceptable.

ImageIO does not currently expose the same independent primary/gain quality and
chroma controls as libavif or direct x265 encoding.

### Requested formats are not guaranteed container facts

ImageIO can transform supplied RGBA gain samples into a different coded pixel
format. A test supplying 16-bit RGBA data produced a three-channel HEVC gain
item using a bi-planar YCbCr representation. Always inspect the resulting
container instead of inferring its bit depth or chroma format from the input
buffer.

### Write atomically

Write to a sibling temporary URL and replace the destination only after
`CGImageDestinationFinalize` or the Core Image write call succeeds. This keeps
an existing destination intact when encoding fails.

## Validation checklist

Inspect the HEIF item graph:

```sh
heif-info -d output.heic |
  rg 'pitm|item_ID|item_type|dimg|altr|pixi|hvcC|colr'
```

Check ImageIO's primary and ISO gain-map descriptions:

```swift
let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
let primary = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
let gainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
  source,
  0,
  kCGImageAuxiliaryDataTypeISOGainMap)
```

Then decode and compare both renditions independently:

1. Primary against the intended base image.
2. Expanded HDR or SDR alternate against the intended alternate image.
3. Gain-map dimensions and channel count against the request.
4. Headroom, min/max, gamma, and offsets against the source metadata.

Do not accept a file merely because ImageIO can reopen it. A plain HDR HEIF, a
legacy auxiliary gain map, and an ISO `tmap` can all decode successfully while
representing different compatibility behavior.
