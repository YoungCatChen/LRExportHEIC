import CoreImage
import Foundation
import ImageIO

public enum HEIFBitDepth: Int {
  case eight = 8
  case ten = 10
}

public enum GainMapChannels: Equatable {
  case monochrome
  case rgb
}

public struct PrimaryRendition {
  public let image: CIImage
  public let outputBitDepth: HEIFBitDepth
  public let outputColorSpace: CGColorSpace

  public init(
    image: CIImage,
    outputBitDepth: HEIFBitDepth,
    outputColorSpace: CGColorSpace
  ) {
    self.image = image
    self.outputBitDepth = outputBitDepth
    self.outputColorSpace = outputColorSpace
  }
}

public struct HDRRendition {
  public let image: CIImage

  public init(image: CIImage) {
    self.image = image
  }
}

public struct GainMapOptions {
  public let channels: GainMapChannels

  public init(channels: GainMapChannels) {
    self.channels = channels
  }
}

public enum DynamicRangeRepresentation {
  case sdr
  case adaptiveHDR(alternate: HDRRendition, gainMap: GainMapOptions)
}

public struct HEIFEncodingRequest {
  public let primary: PrimaryRendition
  public let dynamicRange: DynamicRangeRepresentation

  public init(
    primary: PrimaryRendition,
    dynamicRange: DynamicRangeRepresentation
  ) {
    self.primary = primary
    self.dynamicRange = dynamicRange
  }
}

public enum HEIFEncodingError: Error, CustomStringConvertible {
  case adaptiveHDRRequiresMacOS15
  case imageDimensionsDoNotMatch(CGSize, CGSize)
  case invalidCompressionQuality(Double)

  public var description: String {
    switch self {
    case .adaptiveHDRRequiresMacOS15:
      return "Adaptive HDR HEIF encoding requires macOS 15 or newer"
    case .imageDimensionsDoNotMatch(let primarySize, let alternateSize):
      return "Primary and alternate image dimensions do not match: "
        + "\(primarySize.width)x\(primarySize.height) vs "
        + "\(alternateSize.width)x\(alternateSize.height)"
    case .invalidCompressionQuality(let quality):
      return "Compression quality must be between 0 and 1; received \(quality)"
    }
  }
}

public func writeHEIF(
  _ request: HEIFEncodingRequest,
  to url: URL,
  quality: Double,
  verbose: Bool
) throws {
  guard (0...1).contains(quality) else {
    throw HEIFEncodingError.invalidCompressionQuality(quality)
  }
  var options: [CIImageRepresentationOption: Any] = [
    kCGImageDestinationLossyCompressionQuality
      as CIImageRepresentationOption: quality
  ]
  let context = CIContext()
  let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
    ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
  defer {
    try? FileManager.default.removeItem(at: temporaryURL)
  }

  switch request.dynamicRange {
  case .sdr:
    break
  case .adaptiveHDR(let alternate, let gainMap):
    guard #available(macOS 15.0, *) else {
      throw HEIFEncodingError.adaptiveHDRRequiresMacOS15
    }
    guard request.primary.image.extent.size == alternate.image.extent.size else {
      throw HEIFEncodingError.imageDimensionsDoNotMatch(
        request.primary.image.extent.size,
        alternate.image.extent.size)
    }
    options[.hdrImage] = alternate.image
    options[.hdrGainMapAsRGB] = gainMap.channels == .rgb
    options[
      kCGImageDestinationEncodeRequest as CIImageRepresentationOption
    ] = kCGImageDestinationEncodeToISOGainmap
  }

  if verbose {
    print("Output URL: \(url)")
    print("Output Quality: \(quality)")
    print("Output color space: \(request.primary.outputColorSpace)")
    print("Output bit depth: \(request.primary.outputBitDepth.rawValue)")
    print("Output HDR: \(request.dynamicRange.isHDR)")
  }

  switch request.primary.outputBitDepth {
  case .eight:
    try context.writeHEIFRepresentation(
      of: request.primary.image,
      to: temporaryURL,
      format: .RGBA8,
      colorSpace: request.primary.outputColorSpace,
      options: options)
  case .ten:
    try context.writeHEIF10Representation(
      of: request.primary.image,
      to: temporaryURL,
      colorSpace: request.primary.outputColorSpace,
      options: options)
  }

  try replaceItem(at: url, withItemAt: temporaryURL)
}

extension DynamicRangeRepresentation {
  fileprivate var isHDR: Bool {
    switch self {
    case .sdr:
      return false
    case .adaptiveHDR:
      return true
    }
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
