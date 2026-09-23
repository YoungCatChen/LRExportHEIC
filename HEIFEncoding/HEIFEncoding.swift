import CoreImage
import CoreVideo
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
  public let subsampleFactor: Int

  public init(channels: GainMapChannels, subsampleFactor: Int = 1) {
    self.channels = channels
    self.subsampleFactor = subsampleFactor
  }
}

public struct ISOGainMap {
  public let image: CIImage
  public let metadata: CGImageMetadata
  public let colorSpace: CGColorSpace

  public init(
    image: CIImage,
    metadata: CGImageMetadata,
    colorSpace: CGColorSpace
  ) {
    self.image = image
    self.metadata = metadata
    self.colorSpace = colorSpace
  }
}

public enum DynamicRangeRepresentation {
  case sdr
  case hdr
  case adaptiveHDR(alternate: HDRRendition, gainMap: GainMapOptions)
  case gainMapped(gainMap: ISOGainMap, options: GainMapOptions)
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
  case couldNotCreateDestination
  case couldNotCreateImage
  case couldNotFinalizeDestination
  case couldNotReadGeneratedGainMap
  case imageDimensionsDoNotMatch(CGSize, CGSize)
  case invalidCompressionQuality(Double)
  case invalidGainMapSubsampleFactor(Int)

  public var description: String {
    switch self {
    case .adaptiveHDRRequiresMacOS15:
      return "Adaptive HDR HEIF encoding requires macOS 15 or newer"
    case .couldNotCreateDestination:
      return "Could not create the HEIF image destination"
    case .couldNotCreateImage:
      return "Could not render an image for HEIF encoding"
    case .couldNotFinalizeDestination:
      return "Could not finalize the HEIF image destination"
    case .couldNotReadGeneratedGainMap:
      return "Could not read the generated ISO gain map"
    case .imageDimensionsDoNotMatch(let primarySize, let alternateSize):
      return "Primary and alternate image dimensions do not match: "
        + "\(primarySize.width)x\(primarySize.height) vs "
        + "\(alternateSize.width)x\(alternateSize.height)"
    case .invalidCompressionQuality(let quality):
      return "Compression quality must be between 0 and 1; received \(quality)"
    case .invalidGainMapSubsampleFactor(let factor):
      return "Gain-map subsample factor must be positive; received \(factor)"
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
  let context = CIContext()
  let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
    ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
  defer {
    try? FileManager.default.removeItem(at: temporaryURL)
  }

  switch request.dynamicRange {
  case .sdr, .hdr:
    try writeCoreImageHEIF(
      request.primary,
      to: temporaryURL,
      quality: quality,
      options: [:],
      context: context)

  case .adaptiveHDR(let alternate, let gainMapOptions):
    guard #available(macOS 15.0, *) else {
      throw HEIFEncodingError.adaptiveHDRRequiresMacOS15
    }
    guard request.primary.image.extent.size == alternate.image.extent.size else {
      throw HEIFEncodingError.imageDimensionsDoNotMatch(
        request.primary.image.extent.size,
        alternate.image.extent.size)
    }
    try validateSubsampleFactor(gainMapOptions.subsampleFactor)

    let options: [CIImageRepresentationOption: Any] = [
      .hdrImage: alternate.image,
      .hdrGainMapAsRGB: gainMapOptions.channels == .rgb,
      kCGImageDestinationEncodeRequest as CIImageRepresentationOption:
        kCGImageDestinationEncodeToISOGainmap,
    ]
    if gainMapOptions.subsampleFactor == 1 {
      try writeCoreImageHEIF(
        request.primary,
        to: temporaryURL,
        quality: quality,
        options: options,
        context: context)
    } else {
      let generatedURL = temporaryURL.deletingLastPathComponent()
        .appendingPathComponent(".\(UUID().uuidString).gain-source.heic")
      defer {
        try? FileManager.default.removeItem(at: generatedURL)
      }
      try writeCoreImageHEIF(
        request.primary,
        to: generatedURL,
        quality: quality,
        options: options,
        context: context)
      let generatedGainMap = try readISOGainMap(from: generatedURL)
      try writeGainMappedHEIF(
        request.primary,
        gainMap: generatedGainMap,
        subsampleFactor: gainMapOptions.subsampleFactor,
        to: temporaryURL,
        quality: quality,
        context: context)
    }

  case .gainMapped(let gainMap, let gainMapOptions):
    guard #available(macOS 15.0, *) else {
      throw HEIFEncodingError.adaptiveHDRRequiresMacOS15
    }
    try validateSubsampleFactor(gainMapOptions.subsampleFactor)
    try writeGainMappedHEIF(
      request.primary,
      gainMap: gainMap,
      subsampleFactor: gainMapOptions.subsampleFactor,
      to: temporaryURL,
      quality: quality,
      context: context)
  }

  if verbose {
    print("Output URL: \(url)")
    print("Output Quality: \(quality)")
    print("Output color space: \(request.primary.outputColorSpace)")
    print("Output bit depth: \(request.primary.outputBitDepth.rawValue)")
    print("Output HDR: \(request.dynamicRange.isHDR)")
  }

  try replaceItem(at: url, withItemAt: temporaryURL)
}

private func validateSubsampleFactor(_ factor: Int) throws {
  guard factor > 0 else {
    throw HEIFEncodingError.invalidGainMapSubsampleFactor(factor)
  }
}

private func writeCoreImageHEIF(
  _ primary: PrimaryRendition,
  to url: URL,
  quality: Double,
  options additionalOptions: [CIImageRepresentationOption: Any],
  context: CIContext
) throws {
  var options = additionalOptions
  options[
    kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption
  ] = quality

  switch primary.outputBitDepth {
  case .eight:
    try context.writeHEIFRepresentation(
      of: primary.image,
      to: url,
      format: .RGBA8,
      colorSpace: primary.outputColorSpace,
      options: options)
  case .ten:
    try context.writeHEIF10Representation(
      of: primary.image,
      to: url,
      colorSpace: primary.outputColorSpace,
      options: options)
  }
}

@available(macOS 15.0, *)
private func readISOGainMap(from url: URL) throws -> ISOGainMap {
  guard
    let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let auxiliaryInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
      source,
      0,
      kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any],
    let metadataValue = auxiliaryInfo[kCGImageAuxiliaryDataInfoMetadata],
    let colorSpaceValue = auxiliaryInfo[kCGImageAuxiliaryDataInfoColorSpace],
    let image = CIImage(
      contentsOf: url,
      options: [.auxiliaryHDRGainMap: true])
  else {
    throw HEIFEncodingError.couldNotReadGeneratedGainMap
  }
  let metadata = metadataValue as! CGImageMetadata
  let colorSpace = colorSpaceValue as! CGColorSpace
  return ISOGainMap(
    image: image,
    metadata: metadata,
    colorSpace: colorSpace)
}

@available(macOS 15.0, *)
private func writeGainMappedHEIF(
  _ primary: PrimaryRendition,
  gainMap: ISOGainMap,
  subsampleFactor: Int,
  to url: URL,
  quality: Double,
  context: CIContext
) throws {
  let primaryFormat: CIFormat =
    primary.outputBitDepth == .eight ? .RGBA8 : .RGBA16
  guard
    let primaryImage = context.createCGImage(
      primary.image,
      from: primary.image.extent,
      format: primaryFormat,
      colorSpace: primary.outputColorSpace)
  else {
    throw HEIFEncodingError.couldNotCreateImage
  }

  let width = Int(
    ceil(gainMap.image.extent.width / CGFloat(subsampleFactor)))
  let height = Int(
    ceil(gainMap.image.extent.height / CGFloat(subsampleFactor)))
  let translated = gainMap.image.transformed(
    by: CGAffineTransform(
      translationX: -gainMap.image.extent.minX,
      y: -gainMap.image.extent.minY))
  let resized =
    translated
    .transformed(
      by: CGAffineTransform(
        scaleX: CGFloat(width) / gainMap.image.extent.width,
        y: CGFloat(height) / gainMap.image.extent.height)
    )
    .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
  let bytesPerRow = width * 8
  var data = Data(count: bytesPerRow * height)
  data.withUnsafeMutableBytes { buffer in
    context.render(
      resized,
      toBitmap: buffer.baseAddress!,
      rowBytes: bytesPerRow,
      bounds: resized.extent,
      format: .RGBA16,
      colorSpace: nil)
  }

  guard
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL,
      "public.heic" as CFString,
      1,
      nil)
  else {
    throw HEIFEncodingError.couldNotCreateDestination
  }
  CGImageDestinationAddImage(
    destination,
    primaryImage,
    [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
  let description: [CFString: Any] = [
    kCGImagePropertyWidth: width,
    kCGImagePropertyHeight: height,
    kCGImagePropertyBytesPerRow: bytesPerRow,
    kCGImagePropertyPixelFormat: NSNumber(
      value: kCVPixelFormatType_64RGBALE),
  ]
  let auxiliaryInfo: [CFString: Any] = [
    kCGImageAuxiliaryDataInfoData: data,
    kCGImageAuxiliaryDataInfoDataDescription: description,
    kCGImageAuxiliaryDataInfoMetadata: gainMap.metadata,
    kCGImageAuxiliaryDataInfoColorSpace: gainMap.colorSpace,
  ]
  CGImageDestinationAddAuxiliaryDataInfo(
    destination,
    kCGImageAuxiliaryDataTypeISOGainMap,
    auxiliaryInfo as CFDictionary)
  guard CGImageDestinationFinalize(destination) else {
    throw HEIFEncodingError.couldNotFinalizeDestination
  }
}

extension DynamicRangeRepresentation {
  fileprivate var isHDR: Bool {
    switch self {
    case .sdr:
      return false
    case .hdr, .adaptiveHDR, .gainMapped:
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
