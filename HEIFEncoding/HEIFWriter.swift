import CoreImage
import Foundation
import ImageIO

/// Encodes a supported SDR, native-HDR, or adaptive-HDR representation.
///
/// Adaptive HDR is authored in one high-level ImageIO operation. ImageIO
/// derives and compresses the RGB gain map while writing the final file, so the
/// requested quality participates in both primary and gain-map encoding.
public func writeHEIF(
  _ request: HEIFEncodingRequest,
  to url: URL,
  quality: Double,
  verbose: Bool
) throws {
  guard (0...1).contains(quality) else {
    throw HEIFEncodingError.invalidCompressionQuality(quality)
  }

  let context = CIContext()
  let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
    ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
  defer { try? FileManager.default.removeItem(at: temporaryURL) }

  let primaryImage: CIImage
  let isHDR: Bool
  var options: [CIImageRepresentationOption: Any] = [:]
  switch request.representation {
  case .sdr(let image):
    primaryImage = image
    isHDR = false
  case .hdr(let image):
    primaryImage = image
    isHDR = true
  case .adaptiveHDR(let sdrPrimary, let hdrAlternate):
    guard #available(macOS 15.0, *) else {
      throw HEIFEncodingError.adaptiveHDRRequiresMacOS15
    }
    guard sdrPrimary.extent.size == hdrAlternate.extent.size else {
      throw HEIFEncodingError.imageDimensionsDoNotMatch(
        sdrPrimary.extent.size,
        hdrAlternate.extent.size)
    }
    primaryImage = sdrPrimary
    isHDR = true
    options = [
      .hdrImage: hdrAlternate,
      .hdrGainMapAsRGB: true,
      kCGImageDestinationEncodeRequest as CIImageRepresentationOption:
        kCGImageDestinationEncodeToISOGainmap,
    ]
  }

  try writeCoreImageHEIF(
    primaryImage,
    to: temporaryURL,
    outputBitDepth: request.outputBitDepth,
    outputColorSpace: request.outputColorSpace,
    quality: quality,
    options: options,
    context: context)

  if verbose {
    print("Output URL: \(url)")
    print("Output Quality: \(quality)")
    print("Output color space: \(request.outputColorSpace)")
    print("Output bit depth: \(request.outputBitDepth.rawValue)")
    print("Output HDR: \(isHDR)")
  }
  try replaceItem(at: url, withItemAt: temporaryURL)
}

private func writeCoreImageHEIF(
  _ image: CIImage,
  to url: URL,
  outputBitDepth: HEIFBitDepth,
  outputColorSpace: CGColorSpace,
  quality: Double,
  options additionalOptions: [CIImageRepresentationOption: Any],
  context: CIContext
) throws {
  var options = additionalOptions
  options[
    kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption
  ] = quality

  switch outputBitDepth {
  case .eight:
    try context.writeHEIFRepresentation(
      of: image,
      to: url,
      format: .RGBA8,
      colorSpace: outputColorSpace,
      options: options)
  case .ten:
    try context.writeHEIF10Representation(
      of: image,
      to: url,
      colorSpace: outputColorSpace,
      options: options)
  }
}

private func replaceItem(
  at destinationURL: URL,
  withItemAt sourceURL: URL
) throws {
  let fileManager = FileManager.default
  if fileManager.fileExists(atPath: destinationURL.path) {
    _ = try fileManager.replaceItemAt(
      destinationURL,
      withItemAt: sourceURL)
  } else {
    try fileManager.moveItem(at: sourceURL, to: destinationURL)
  }
}
