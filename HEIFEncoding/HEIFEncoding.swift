import CoreImage
import Foundation

public enum HEIFBitDepth: Int {
  case eight = 8
  case ten = 10
}

/// The complete pixel representation requested for one HEIF file.
///
/// Adaptive HDR always uses an SDR primary and an HDR alternate. Keeping the
/// three supported forms in one enum prevents unsupported primary/alternate
/// combinations from reaching the writer.
public enum HEIFRepresentation {
  case sdr(CIImage)
  case hdr(CIImage)
  case adaptiveHDR(sdrPrimary: CIImage, hdrAlternate: CIImage)
}

public struct HEIFEncodingRequest {
  public let representation: HEIFRepresentation
  public let outputBitDepth: HEIFBitDepth
  public let outputColorSpace: CGColorSpace

  public init(
    representation: HEIFRepresentation,
    outputBitDepth: HEIFBitDepth,
    outputColorSpace: CGColorSpace
  ) {
    self.representation = representation
    self.outputBitDepth = outputBitDepth
    self.outputColorSpace = outputColorSpace
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
