# HDR and Gain Map Reference

This document summarizes the HDR concepts, file-format mappings, implementation
constraints, and validation methods relevant to LRExportHEIC. It deliberately
separates standards-level behavior from codec choices and platform-specific
implementation behavior.

Unless explicitly stated otherwise:

- "must" describes a requirement imposed by a cited specification or by this
  project's correctness policy;
- "commonly" describes an implementation choice, not a format requirement;
- Apple API behavior is implementation behavior and may change by OS release.

## General HDR concepts

### SDR and HDR renditions

An SDR rendition is an image intended to fit within standard dynamic-range
display conditions. An HDR rendition can represent highlights above diffuse
white and requires a display pipeline with additional luminance headroom.

Two broad storage models are relevant:

- Native HDR stores one HDR image using an HDR transfer function or an
  extended-linear representation. An SDR display path must tone-map it.
- Adaptive HDR stores a base rendition plus a gain map and metadata. A decoder
  can display the base directly or combine it with the gain map according to
  available display headroom.

A file extension alone does not identify the model. HEIF, AVIF, and JPEG XL can
carry native HDR; JPEG, HEIF, and AVIF can carry adaptive HDR. The actual
container items, color metadata, and auxiliary data must be inspected.

### Color primaries, transfer functions, and bit depth

These properties describe different things and must not be conflated:

- Color primaries define the RGB gamut, such as BT.709/sRGB, Display P3, or
  BT.2020.
- A transfer function maps stored code values to or from light. Examples include
  sRGB, PQ, HLG, and linear light.
- Bit depth controls sample precision. It does not by itself make an image HDR.
- Chroma subsampling controls spatial color resolution. It is independent of
  the semantic meaning of the image channels.

For example, a 16-bit sRGB image can still be SDR, while a 10-bit PQ image can
be HDR. A three-channel RGB gain map may be transformed and compressed as
YCbCr 4:2:0 even though it reconstructs three independent RGB gains.

PQ represents absolute display luminance according to SMPTE ST 2084. HLG is a
relative HDR transfer system. Extended-linear formats can encode values greater
than `1.0`, but their effective headroom must still be established by metadata
or by an agreed interpretation.

### Diffuse white and headroom

Diffuse white is the reference level for ordinary reflecting white surfaces.
Specular highlights, light sources, and reflections may extend above it.

Headroom is commonly expressed as a linear ratio:

```text
headroom_ratio = HDR_peak / SDR_white
```

The equivalent value in photographic stops is:

```text
headroom_stops = log2(headroom_ratio)
```

For example, `4.0x` headroom is `2.0` stops. Metadata and APIs may expose either
the linear ratio or its base-2 logarithm. Callers must verify the unit instead
of comparing the numbers directly.

Headroom does not uniquely determine physical output luminance. The display's
SDR white level, current EDR budget, ambient-light behavior, window size, power
state, and tone mapper can all affect the final luminance in nits.

## Gain-map representation

### Purpose and simplified reconstruction model

A gain map describes how to transform one rendition into another. In a common
forward arrangement, the base is SDR and the alternate rendition is HDR.

After converting both renditions to compatible linear-light RGB values, a
simplified per-channel gain is:

```text
gain = log2((HDR_linear + offset_hdr) /
            (SDR_linear + offset_sdr))
```

The gain is normalized using encoded minimum, maximum, and gamma parameters:

```text
encoded_gain = clamp((gain - gain_min) /
                     (gain_max - gain_min), 0, 1) ^ (1 / gamma)
```

A decoder reconstructs the gain and applies a display-dependent weight:

```text
decoded_gain = gain_min +
               encoded_gain ^ gamma * (gain_max - gain_min)

output_linear = (base_linear + offset_base) *
                2 ^ (weight * decoded_gain) -
                offset_alternate
```

The exact field names, vector rules, and interpolation behavior depend on the
metadata specification. Implementations should follow ISO 21496-1 or the
applicable Adobe metadata specification rather than treating these simplified
equations as serialization rules.

### Display adaptation

At SDR headroom, a forward gain map has a weight near zero, so the decoder shows
the base rendition. As available display headroom increases, the decoder applies
more of the gain map until reaching the encoded alternate rendition.

This makes the base rendition part of the authored image, not merely a decoder
fallback detail. A structurally valid adaptive HDR file can still have a poor
SDR presentation if its base rendition was clipped or tone-mapped poorly.

### Mono and RGB gain maps

A mono gain map stores one scalar gain per location and applies it equally to
red, green, and blue:

```text
(R, G, B)_alternate = (R, G, B)_base * gain
```

It can change luminance while preserving the base RGB ratios. It cannot recover
a highlight hue or saturation that differs between the base and alternate
renditions.

An RGB gain map stores three independent gains:

```text
R_alternate = R_base * gain_r
G_alternate = G_base * gain_g
B_alternate = B_base * gain_b
```

Use an RGB gain map when SDR and HDR renditions differ chromatically, including
color grading in bright clouds, colored light sources, neon, fire, or saturated
specular highlights. A mono gain map is appropriate when the renditions differ
primarily in luminance and its smaller size or simpler decode path is valuable.

### Semantic channels and codec representation

"RGB gain map" describes reconstruction semantics. It does not require the
compressed bitstream to store literal RGB 4:4:4 samples.

A codec may transform a three-channel gain map to Y'CbCr and apply 4:2:0 or
4:2:2 chroma subsampling. After decoding back to RGB, the three channels still
represent independent red, green, and blue gains. Smooth chromatic differences
usually survive this well; fine colored edges are more sensitive to chroma
subsampling.

A mono gain map has no chroma planes. It may be stored as a true monochrome
image when the codec and container support that representation.

### Spatial resolution

A gain map may be full resolution or spatially subsampled. Lower-resolution gain
maps reduce file size because HDR gain often varies more slowly than base-image
texture. They can also introduce halos or imprecise reconstruction at sharp
high-contrast boundaries.

Subsampling is an encoder choice, not a universal gain-map requirement. Tools
must inspect the encoded dimensions rather than assume a fixed factor.

## File-format mappings

### JPEG adaptive HDR

A conventional JPEG can serve as the SDR base. An additional JPEG image can
carry a mono or RGB gain map, with MPF metadata locating the related image.
Newer files may also carry ISO 21496-1 metadata, while existing ecosystems may
use Adobe gain-map metadata.

Legacy JPEG readers normally display only the primary image. Adaptive HDR
readers locate the gain map and reconstruct an HDR rendition.

Important variables are not fixed by the `.jpg` extension:

- primary and gain-map dimensions;
- mono versus RGB gain-map semantics;
- 4:4:4, 4:2:2, or 4:2:0 JPEG sampling;
- gain-map offsets, gamma, minimum, maximum, and headroom;
- metadata namespace and compatibility profile.

The primary image must already be a satisfactory SDR rendition. Gain-map
metadata cannot repair its appearance in a legacy reader that never decodes the
gain map.

### HEIF, HEIC, and AVIF

HEIF-family containers can represent HDR in several ways:

- a native HDR coded image using PQ, HLG, or another HDR color description;
- a base image plus an auxiliary or derived gain-map relationship;
- an ISO gain-map `tmap` derived image that relates the base and gain map to an
  alternate rendition.

In a `tmap` arrangement, implementations should inspect:

- the primary item;
- the coded image items or grids used by the base;
- the gain-map coded items or grid;
- the `tmap` derived item and its `dimg` references;
- the alternate group relationship;
- pixel depth and color properties associated with each item.

The base, gain map, and alternate rendition do not need to use the same bit
depth or chroma format. A container may use an 8-bit sRGB primary, an 8-bit mono
or RGB gain map, and a derived 10-bit PQ alternate rendition.

Calling an API with "10-bit" in its name does not prove that every contained
item is 10-bit. The resulting container must be inspected. The operational
recipes below show both the preferred project command and lower-level container
commands.

### JPEG XL

JPEG XL can represent HDR natively with high-precision integer or floating-point
sample semantics and an HDR transfer function. A native PQ or HLG JPEG XL does
not require a gain map.

SDR presentation of native HDR JPEG XL depends on the decoder's tone-mapping
behavior unless the file contains a separately defined adaptive representation.
Do not infer an inverse gain map from the `.jxl` extension. Verify extra channels
and metadata explicitly using the JPEG XL inspection recipe below.

JPEG XL's internal coding tools and XYB transform are codec mechanisms; they do
not mean every decoded JPEG XL is exposed as XYB or as a floating-point image.
The decoded color space, transfer function, bit depth, and intensity target are
the relevant application-facing properties.

### Format comparison summary

| Concern | JPEG gain map | HEIF/HEIC gain map | Native HDR JPEG XL |
|---|---|---|---|
| Legacy base | Conventional JPEG primary | HEIF primary item | Not inherently present |
| HDR data | Secondary gain-map JPEG | Gain-map item or grid | Native HDR samples |
| Relationship | MPF and gain-map metadata | `tmap`/item references | Native codestream metadata |
| SDR behavior | Display primary | Display primary | Decoder tone mapping |
| Mono/RGB map | Either | Either | Not required for native HDR |
| Chroma sampling | Encoder choice | Codec and encoder choice | Codec choice |

## Authoring and implementation guidance

### Preserve the creator-controlled SDR rendition

An adaptive HDR encoder should receive two deliberate inputs:

```text
creator-approved SDR base
creator-approved HDR target
```

It should compute the gain map from those two renditions. Passing only the HDR
image forces the encoder or platform framework to invent an SDR base. That may
clip highlights, flatten contrast, alter color, or otherwise discard the
creator's SDR intent even when the reconstructed HDR remains correct.

An HDR application's "SDR preview" is valuable only if the exact resulting
pixels become the encoded base rendition. Merely previewing a tone map in the
editor does not guarantee that a post-processing plug-in receives it.

### Lightroom export behavior

Lightroom can export native HDR and adaptive HDR representations depending on
format, settings, application version, and export path. Plug-ins should not
infer the final representation from the selected extension or nominal bit depth.

For a two-rendition workflow, verify that the plug-in receives or produces:

- the HDR master in a color space that preserves its headroom;
- the authored SDR preview as a separate raster;
- identical geometry and orientation for both images;
- enough metadata to interpret both color spaces unambiguously.

A 32-bit extended-linear TIFF and a 16-bit PQ TIFF can describe the same HDR
appearance, but their numeric pixel values are not directly comparable. They
must first be rendered into a common color domain. The comparison commands below
perform this conversion before calculating metrics.

### Apple Core Image and ImageIO

Relevant decoding concepts include:

- `CIImageOption.auxiliaryHDRGainMap` for reading a gain-map image;
- `CIImageOption.expandToHDR` for requesting the reconstructed HDR rendition;
- `CIImage.contentHeadroom` for the decoded rendition's linear headroom.

Relevant adaptive HDR encoding options include:

- `CIImageRepresentationOption.hdrImage` for the alternate HDR image;
- `CIImageRepresentationOption.hdrGainMapAsRGB` for RGB gain-map semantics;
- `kCGImageDestinationEncodeToISOGainmap` for an ISO gain-map encode request.

The base image passed as the main image should be the authored SDR rendition.
The HDR image should be supplied separately through the HDR representation
option. Encoding a single HDR image and allowing the framework to derive the
base does not preserve an independently authored SDR rendition.

Core Image and ImageIO behavior is OS-version dependent. Validate the produced
container, base rendition, gain map, and reconstructed HDR instead of assuming
behavior from an API name.

### Encoder policy

For LRExportHEIC, the preferred policy is:

- use the Lightroom-authored SDR output as the primary image;
- use the Lightroom-authored HDR output as the alternate image;
- default to an RGB gain map when chromatic differences must be preserved;
- offer mono gain maps as a size or compatibility tradeoff;
- refuse mismatched geometry rather than silently resize;
- refuse to overwrite an output unless explicitly requested;
- decode and validate the result after encoding.

## Analysis and validation

### Rendition capability model

Treat every input as exposing one or more renditions:

```text
SDR-only image:
  SDR

Native HDR image:
  HDR

Adaptive HDR image:
  SDR primary
  HDR reconstruction
  gain map
```

Two images can be compared only in a common rendition:

| Input A | Input B | Automatic comparison |
|---|---|---|
| SDR | SDR | SDR against SDR |
| HDR | HDR | HDR against HDR |
| Adaptive HDR | SDR | Adaptive primary against SDR |
| Adaptive HDR | HDR | Adaptive reconstruction against HDR |
| Adaptive HDR | Adaptive HDR | SDR and HDR comparisons |
| SDR | HDR | None without an explicit tone-mapping policy |

Do not silently tone-map an HDR image to manufacture a comparison target.

### Single-image facts and statistics

Single-image facts include:

- container and item relationships;
- dimensions and orientation;
- bit depth, color primaries, and transfer function;
- chroma format and range flags;
- available SDR and HDR renditions;
- gain-map presence, dimensions, and channel count;
- content headroom;
- minimum, maximum, mean, histogram, and clipping percentages;
- file size and checksum.

These statistics describe one image. Showing the same statistic for two images
side by side is useful, but it does not turn it into a pairwise metric.

### Pairwise full-reference metrics

RMSE and PSNR require two aligned images:

```text
RMSE(A, B) = sqrt(mean((A - B)^2))

PSNR(A, B) = 20 * log10(MAX / RMSE(A, B))
```

When samples are normalized to `[0,1]`, `MAX` is `1.0`.

Every result must state:

- candidate and reference paths;
- compared rendition;
- color space and transfer function;
- numeric range and sample precision;
- geometry;
- whether alpha was included;
- whether resizing, cropping, or resampling occurred.

The project uses these default domains:

- SDR: encoded sRGB RGB, 16-bit render, normalized to `[0,1]`;
- HDR: ITU-R BT.2100 PQ RGB, 16-bit render, normalized to `[0,1]`;
- alpha ignored;
- no implicit resizing or cropping.

RMSE and PSNR are broad fidelity indicators. They may miss perceptually
important local errors, particularly highlight hue changes. Useful extensions
include highlight-only RGB error, chroma error, luminance error, and perceptual
color-difference metrics.

### Round-trip validation

An adaptive HDR encoder should be validated in this order:

1. Confirm that the output contains an adaptive HDR relationship and gain map.
2. Decode the primary without applying the gain map.
3. Compare that primary with the intended SDR reference.
4. Decode or reconstruct the full HDR rendition.
5. Compare the reconstruction with the intended HDR reference.
6. Inspect highlight clipping and chromatic differences separately.
7. Test thumbnails, full-screen rendering, zoom transitions, and SDR/HDR display
   modes on target devices.

A successful HDR reconstruction does not prove that the SDR base is correct.
Both comparisons are required.

The recipes below use widely available command-line tools and public platform
APIs. Project-specific automation is documented separately in
[HDR image tools](../Tools/README.md).

## From concepts to practice

### Match a question to evidence

Different tools answer different questions. A successful decode does not prove
that metadata is correct, and valid metadata does not prove that both renditions
match the intended images.

| Question | Broadly available evidence |
|---|---|
| What file and pixel format is this? | `file`, ExifTool, ImageMagick |
| Does a JPEG contain another image? | ExifTool MPF tags |
| How are HEIF items related? | `heif-info -d` |
| Does JPEG XL declare native HDR or extra channels? | `jxlinfo -v` |
| What does a normal HEIF decoder treat as primary? | `heif-convert` |
| What does Apple expose as the gain map or HDR rendition? | Core Image |
| Do two renditions match? | Color-managed renders plus RMSE/PSNR |
| Does a target phone present the file correctly? | Device testing |

Use at least one structural check and one decoded-pixel check for adaptive HDR.

### Establish a basic inventory

Identify the format and collect metadata before decoding:

```sh
file image.heic

exiftool -G1 -a -s \
  -FileType \
  -ImageWidth \
  -ImageHeight \
  -BitsPerSample \
  -ProfileDescription \
  -ColorPrimaries \
  -TransferCharacteristics \
  -MatrixCoefficients \
  -ImagePixelDepth \
  image.heic
```

The extension, bit depth, or an `HDR` filename is not enough to classify the
representation. Look for both color metadata and container relationships.

ImageMagick provides a decoded-pixel summary for supported formats:

```sh
magick identify -verbose image.tif
```

It reports geometry, profiles, channel depth, extrema, means, and chroma
sampling. Whether ImageMagick applies a gain map depends on its delegates and
version, so its output must not be assumed to be the HDR reconstruction.

### Inspect HEIF container relationships

Start with the concise libheif summary:

```sh
heif-info image.heic
```

Inspect the low-level item graph for adaptive HDR:

```sh
heif-info -d image.heic |
  rg 'pitm|item_ID|item_type|reference with type|entity IDs'
```

Relevant evidence includes:

```text
pitm
  identifies the primary item

item_type: grid
  identifies a tiled image grid

item_type: tmap
  identifies a tone-mapped derived image

dimg references
  connect a grid to tiles and a tmap item to its source images

altr group
  associates alternate renditions
```

Inspect color and coded-pixel properties separately:

```sh
heif-info -d image.heic |
  rg 'colr|pixi|hvcC|bits_per_channel|colour_primaries'

heif-info -d image.heic |
  rg 'transfer_characteristics|matrix_coefficients|chroma_format|bit_depth'
```

The following FFmpeg command enumerates coded HEVC streams and their pixel
formats:

```sh
ffprobe -v error \
  -show_entries \
  stream=index,id,profile,width,height,pix_fmt,color_range,color_space,color_transfer,color_primaries \
  -of compact=p=0:nk=0 \
  image.heic
```

Tiled HEIF images may appear as many dependent streams. `ffprobe` describes
coded streams; `heif-info -d` is needed to recover the item graph and determine
which tiles form the primary or gain-map grid.

Decode what libheif considers the primary image:

```sh
heif-convert image.heic primary.png
```

This is a useful SDR fallback check, but it does not prove that the tool decoded
or applied the gain map. Inspect the output and the tool version.

### Inspect JPEG gain-map structure

Inspect MPF and gain-map metadata:

```sh
exiftool -G1 -a -s \
  -MPFVersion \
  -NumberOfImages \
  -MPImageType \
  -MPImageLength \
  -MPImageStart \
  -UniformResourceName \
  -Version \
  adaptive.jpg
```

Extract the MPF secondary image:

```sh
exiftool -b -MPImage2 adaptive.jpg > /tmp/gain-map.jpg
magick identify -verbose /tmp/gain-map.jpg
```

Inspect JPEG chroma sampling directly:

```sh
exiftool -G1 -a -s -YCbCrSubSampling adaptive.jpg
magick identify -verbose adaptive.jpg | rg 'sampling-factor|Colorspace'
```

The extracted image shows coded dimensions, component count, and sampling. Its
visible appearance is not the decoded gain until minimum, maximum, gamma, and
offset metadata are applied.

### Inspect JPEG XL HDR representation

Inspect a JPEG XL codestream and container with libjxl:

```sh
jxlinfo -v image.jxl
```

Check:

- decoded bit depth;
- color primaries;
- transfer function;
- intensity target;
- number and type of extra channels.

Decode the image while preserving its declared color metadata:

```sh
djxl image.jxl decoded.png
```

A PQ transfer function, an HDR intensity target, and zero extra channels are
evidence of native HDR without a gain-map extra channel. They do not prove how
an SDR viewer will tone-map the image. A PNG containing PQ code values may also
look wrong in software that treats it as ordinary sRGB.

### Access adaptive HDR renditions with Core Image

On Apple platforms, Core Image exposes the base, auxiliary gain map, and expanded
HDR rendition through public options. The essential Swift operations are:

```swift
import CoreImage
import Foundation

let url = URL(fileURLWithPath: inputPath)

let base = CIImage(
  contentsOf: url,
  options: [.applyOrientationProperty: true]
)

let gainMap = CIImage(
  contentsOf: url,
  options: [
    .applyOrientationProperty: true,
    .auxiliaryHDRGainMap: true,
  ]
)

let hdr = CIImage(
  contentsOf: url,
  options: [
    .applyOrientationProperty: true,
    .expandToHDR: true,
  ]
)
```

Interpret the results as follows:

- `base` is the ordinary primary rendition;
- a non-`nil` `gainMap` indicates an auxiliary gain map recognized by Core
  Image;
- `hdr` requests the expanded HDR rendition when the format supports it;
- `contentHeadroom` reports the rendition's linear headroom on supported OS
  releases.

The options describe requested decode behavior. Container inspection is still
needed to distinguish a native image, auxiliary image, grid, and `tmap`
relationship.

### Render images into a common color domain

Raw code values from sRGB, linear RGB, PQ, and HLG are not directly comparable.
A color-managed renderer must convert both inputs to the same primaries,
transfer function, numeric range, precision, orientation, and geometry.

For an SDR comparison, render both images to encoded sRGB:

```swift
let context = CIContext()
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

try context.writePNGRepresentation(
  of: image,
  to: outputURL,
  format: .RGBA16,
  colorSpace: sRGB,
  options: [:]
)
```

For an HDR comparison, first request the HDR rendition when needed, then render
both images to BT.2100 PQ:

```swift
let hdrOptions: [CIImageOption: Any] = [
  .applyOrientationProperty: true,
  .expandToHDR: true,
]
let hdr = CIImage(contentsOf: inputURL, options: hdrOptions)!
let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!

try context.writePNGRepresentation(
  of: hdr,
  to: outputURL,
  format: .RGBA16,
  colorSpace: pq,
  options: [:]
)
```

Use the same procedure for both inputs. Do not judge the PQ PNG in an SDR-only
viewer; it is an interchange artifact for a color-managed HDR path or numeric
comparison.

Other color-management systems can be used, but both sides must use the same
explicit transform. A decoder that silently tone-maps one side is not a valid
full-reference comparison pipeline.

### Calculate pairwise metrics

After producing two same-size, same-domain images, calculate RMSE and PSNR with
ImageMagick:

```sh
magick compare -metric RMSE candidate.png reference.png null:
magick compare -metric PSNR candidate.png reference.png null:
```

ImageMagick may print both quantum-space and normalized values for RMSE. Record
which value is used. A portable report should use normalized samples in `[0,1]`
and compute:

```text
PSNR = 20 * log10(1 / normalized_RMSE)
```

Before comparing, confirm geometry and profiles:

```sh
magick identify \
  -format '%f %wx%h depth=%z colorspace=%[colorspace]\n' \
  candidate.png \
  reference.png

exiftool -G1 -a -s -ProfileDescription candidate.png reference.png
```

RMSE and PSNR are pairwise full-reference metrics. Lower RMSE and higher PSNR
indicate closer decoded values, but do not establish artistic correctness. A
small highlight region with an important hue error may have little effect on a
whole-image score.

### Calculate single-image clipping statistics

Estimate the percentage of near-white SDR pixels with ImageMagick:

```sh
magick image.png \
  -colorspace gray \
  -threshold '98%' \
  -format '%[fx:100*mean]\n' \
  info:
```

Run the same command independently for the candidate primary and SDR reference.
The two percentages are side-by-side single-image statistics, not a pairwise
metric. A large increase in the candidate can indicate highlight clipping or an
overly aggressive SDR base.

Threshold statistics do not distinguish white from colored clipping and do not
measure highlight hue. For color-sensitive HDR work, inspect highlighted regions
and consider highlight-only RGB, chroma, or perceptual color-difference metrics.

### Encode an explicit SDR and HDR pair with ImageIO

On supported Apple platforms, supply the authored SDR image as the main image
and the HDR target separately:

```swift
import CoreImage
import ImageIO

let context = CIContext()
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let options: [CIImageRepresentationOption: Any] = [
  kCGImageDestinationLossyCompressionQuality
    as CIImageRepresentationOption: 0.9,
  .hdrImage: hdrImage,
  .hdrGainMapAsRGB: true,
  kCGImageDestinationEncodeRequest
    as CIImageRepresentationOption:
      kCGImageDestinationEncodeToISOGainmap,
]

try context.writeHEIFRepresentation(
  of: sdrImage,
  to: outputURL,
  format: .RGBA8,
  colorSpace: sRGB,
  options: options
)
```

Set `hdrGainMapAsRGB` to `false` only when a single scalar gain can reconstruct
the intended HDR color. API availability and output behavior vary by OS release,
so inspect and decode the resulting file.

Cross-platform implementations can build the same logical pipeline with
libultrahdr, libheif, or another ISO 21496-1 implementation. Their command-line
interfaces and supported containers vary by version; consult the installed
tool's help and verify the output rather than copying version-specific flags.

### Verify an encoded image end to end

Use a four-part validation sequence:

1. Inspect the container and confirm the primary, gain map, and their
   relationship.
2. Decode the primary without applying the gain map and compare it with the
   authored SDR reference in a common SDR domain.
3. Decode or reconstruct the full HDR rendition and compare it with the authored
   HDR reference in a common HDR domain.
4. Test thumbnails, full-screen rendering, SDR/HDR display modes, and zoom
   transitions on target devices.

Container inspection and decoded comparison answer different questions:

- `heif-info -d` establishes how HEIF items and codecs are structured;
- ExifTool establishes JPEG MPF and metadata structure;
- `jxlinfo -v` establishes JPEG XL codestream properties;
- Core Image or another gain-map-aware API exposes decoded renditions;
- ImageMagick compares already normalized image pairs;
- device testing verifies the platform's presentation behavior.

None substitutes for the others.

### Project convenience automation

This repository provides `Tools/analyze_hdr_image.sh` and `hdr-image-tool` to
automate the general process above. They are conveniences, not the source of the
model. Their outputs map directly to the container, decode, color-conversion,
and metric steps described in this document. See
[HDR image tools](../Tools/README.md) for their interface.

## Common pitfalls

### Treating implementation choices as format rules

Avoid assumptions such as:

- every gain map is spatially downsampled;
- every HEIF base is 10-bit;
- every HDR JPEG XL uses an inverse gain map;
- every three-channel gain map is stored as RGB 4:4:4;
- every adaptive HDR decoder uses the same SDR white or display weight;
- a valid gain-map container guarantees a good SDR presentation.

Inspect the file and decode both renditions.

### Comparing encoded values without color management

Do not directly compare sample values from sRGB, PQ, HLG, and linear images.
Identical scene values have different code values under different transfer
functions. Render both inputs into the same primaries, transfer function, range,
precision, geometry, and orientation before computing metrics.

### Confusing metadata headroom with measured content

Metadata headroom expresses interpretation or capacity. Measured maximum pixel
values describe the particular content. These can differ, and a dark image may
use only a small portion of its declared HDR range.

### Relying on filenames or API names

Names such as `HDR`, `10-bit`, `.heic`, or `.jxl` are not sufficient evidence of
the encoded representation. Inspect container structure and color metadata, and
perform a decode round trip.

## Authoritative references

### Standards and format documentation

- [ISO 21496-1:2025, Gain map metadata for image conversion](https://www.iso.org/standard/86775.html)
- [Adobe Gain Map documentation](https://helpx.adobe.com/camera-raw/desktop/hdr-and-advanced-output/gain-map.html)
- [Adobe Gain Map Specification 1.0 PDF](https://helpx.adobe.com/content/dam/help/en/camera-raw/using/gain-map/jcr_content/root/content/flex/items/position/position-par/table/row-3u03dx0-column-4a63daf/download_section/download-1/Gain_Map_1_0d15.pdf)
- [Android Ultra HDR image format](https://developer.android.com/media/platform/hdr-image-format)
- [CIPA DC-007 Multi-Picture Format](https://www.cipa.jp/e/std/std-sec.html)
- [ITU-R BT.2100, HDR television image parameters](https://www.itu.int/rec/R-REC-BT.2100)
- [ITU-R BT.2408, operational practices for HDR television](https://www.itu.int/rec/R-REC-BT.2408)
- [JPEG XL overview](https://jpeg.org/jpegxl/)

### Apple APIs

- [`CIImageOption.expandToHDR`](https://developer.apple.com/documentation/coreimage/ciimageoption/expandtohdr)
- [`CIImageRepresentationOption.hdrImage`](https://developer.apple.com/documentation/coreimage/ciimagerepresentationoption/hdrimage)
- [`CIImageRepresentationOption.hdrGainMapAsRGB`](https://developer.apple.com/documentation/coreimage/ciimagerepresentationoption/hdrgainmapasrgb)
- [`kCGImageDestinationEncodeToISOGainmap`](https://developer.apple.com/documentation/imageio/kcgimagedestinationencodetoisogainmap)
- [`kCGImageSourceDecodeToHDR`](https://developer.apple.com/documentation/imageio/kcgimagesourcedecodetohdr)

### Reference implementations

- [Google libultrahdr](https://github.com/google/libultrahdr)
- [libheif](https://github.com/strukturag/libheif)
- [libjxl](https://github.com/libjxl/libjxl)
