import ConsoleKit
import CoreImage
import Foundation

#if SWIFT_PACKAGE
  import HEIFEncoding
#endif

enum ExportHEICError: Error, CustomStringConvertible {
  case couldNotReadImage(String)

  var description: String {
    switch self {
    case .couldNotReadImage(let path):
      return "Could not read image file: \(path)"
    }
  }
}

struct ExportHEICCommand: Command {
  public struct ExportHEICCommandSignature: CommandSignature {
    @Option(name: "sdr-from", help: "Path to the authored SDR rendition")
    var sdrFrom: String?

    @Option(name: "hdr-from", help: "Path to the authored HDR rendition")
    var hdrFrom: String?

    @Option(
      name: "quality",
      help: "Compression quality. Cannot be used with --size-limit. Allowed range: 0.0 - 1.0",
      allowedValues: 0.0...1.0)
    var quality: Double?

    @Option(
      name: "size-limit",
      help: "Limit the size in bytes instead of specifying quality. Cannot be used with --quality",
      allowedValues: 1...Int64.max)
    var sizeLimit: Int64?

    @Option(
      name: "size-limit-accuracy",
      help: "Accept a result at least this fraction of the size limit. Default: 0.9",
      allowedValues: 0.1...1.0)
    var sizeLimitAccuracy: Double?

    @Option(
      name: "min-quality",
      help: "Minimum quality used with --size-limit. Default: 0.0",
      allowedValues: 0.0...1.0)
    var minQuality: Double?

    @Option(
      name: "max-quality",
      help: "Maximum quality used with --size-limit. Default: 1.0",
      allowedValues: 0.0...1.0)
    var maxQuality: Double?

    @Option(
      name: "output-color-space",
      help: "Output color space. Omit to infer it from the primary input",
      allowedValues: [
        CGColorSpace.sRGB,
        CGColorSpace.displayP3,
        CGColorSpace.adobeRGB1998,
        CGColorSpace.itur_2020,
        CGColorSpace.rommrgb,
        CGColorSpace.itur_709_PQ,
        CGColorSpace.displayP3_PQ,
        CGColorSpace.itur_2100_PQ,
      ].map { ($0 as String).replacingOccurrences(of: "kCGColorSpace", with: "") })
    var outputColorSpaceName: String?

    @Option(
      name: "output-bit-depth",
      help: "HEIF primary image bit depth. Omit to infer from the primary input",
      allowedValues: [8, 10])
    var outputBitDepthValue: Int?

    @Flag(name: "verbose", help: "Print encoding decisions verbosely")
    var verbose: Bool

    @Argument(name: "output-file", help: "Path to the output file")
    var outputFile: String

    var sdrFromURL: URL? {
      return sdrFrom.map(URL.init(fileURLWithPath:))
    }

    var hdrFromURL: URL? {
      return hdrFrom.map(URL.init(fileURLWithPath:))
    }

    var outputFileURL: URL {
      return URL(fileURLWithPath: outputFile)
    }

    var outputColorSpace: CGColorSpace? {
      guard let outputColorSpaceName else {
        return nil
      }
      return CGColorSpace(
        name: "kCGColorSpace\(outputColorSpaceName)" as CFString)
    }

    public init() {}
  }

  var help: String {
    return "Export authored SDR and HDR renditions as HEIC"
  }

  /// Executes one CLI export from authored inputs through final HEIF encoding.
  ///
  /// Input paths determine the representation: SDR only, HDR only, or an SDR
  /// primary plus an HDR alternate when both paths are supplied.
  func run(
    using context: CommandContext,
    signature: ExportHEICCommandSignature
  ) throws {
    try signature.enhanceOptions()
    try signature.checkOptions()

    let sdrImage = try signature.sdrFromURL.map {
      try requireImage(Self.readSDRImage(from: $0), at: $0)
    }
    let hdrImage = try signature.hdrFromURL.map {
      try requireImage(Self.readHDRImage(from: $0), at: $0)
    }

    let primaryImage = sdrImage ?? hdrImage!
    let sourceBitDepth = primaryImage.properties["Depth"] as? Int ?? 8
    let outputBitDepth = HEIFBitDepth(
      rawValue: signature.outputBitDepthValue
        ?? (sourceBitDepth > 8 ? 10 : 8))!

    let representation: HEIFRepresentation
    let outputColorSpace: CGColorSpace
    let representationName: String
    switch (sdrImage, hdrImage) {
    case (.some(let sdr), .none):
      representation = .sdr(sdr)
      outputColorSpace =
        signature.outputColorSpace
        ?? sdr.colorSpace
        ?? CGColorSpace(name: CGColorSpace.sRGB)!
      representationName = "SDR primary"
    case (.none, .some(let hdr)):
      representation = .hdr(hdr)
      outputColorSpace =
        signature.outputColorSpace
        ?? hdr.colorSpace
        .flatMap(Self.hdrOutputColorSpace)
        ?? CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
      representationName = "HDR primary"
    case (.some(let sdr), .some(let hdr)):
      representation = .adaptiveHDR(
        sdrPrimary: sdr,
        hdrAlternate: hdr)
      outputColorSpace =
        signature.outputColorSpace
        ?? sdr.colorSpace
        ?? CGColorSpace(name: CGColorSpace.sRGB)!
      representationName = "SDR primary + HDR gain map"
    case (.none, .none):
      preconditionFailure("Input validation accepted no rendition")
    }

    let request = HEIFEncodingRequest(
      representation: representation,
      outputBitDepth: outputBitDepth,
      outputColorSpace: outputColorSpace)
    if signature.verbose {
      context.console.print("Output representation: \(representationName)")
      context.console.print("Source primary bit depth: \(sourceBitDepth)")
      context.console.print(
        "Source primary color space: "
          + String(describing: primaryImage.colorSpace))
    }

    if let quality = signature.quality {
      try writeHEIF(
        request,
        to: signature.outputFileURL,
        quality: quality,
        verbose: signature.verbose)
    } else {
      try writeSizeLimitedHEIF(
        request,
        to: signature.outputFileURL,
        withSizeLimit: signature.sizeLimit!,
        withSizeLimitAccuracy: signature.sizeLimitAccuracy ?? 0.9,
        withinRange: (signature.minQuality ?? 0)...(signature.maxQuality ?? 1),
        verbose: signature.verbose)
    }
  }

  private static func readSDRImage(from url: URL) -> CIImage? {
    return CIImage(contentsOf: url)
  }

  private static func readHDRImage(from url: URL) -> CIImage? {
    if #available(macOS 14.0, *) {
      return CIImage(
        contentsOf: url,
        options: [
          .expandToHDR: true,
          .toneMapHDRtoSDR: false,
        ])
    }
    return CIImage(contentsOf: url)
  }

  private static func hdrOutputColorSpace(
    for inputColorSpace: CGColorSpace
  ) -> CGColorSpace? {
    let name = String(describing: inputColorSpace.name).lowercased()
    if name.contains("display p3") || name.contains("p3") {
      return CGColorSpace(name: CGColorSpace.displayP3_PQ)
    }
    if name.contains("srgb") || name.contains("709") {
      return CGColorSpace(name: CGColorSpace.itur_709_PQ)
    }
    return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
  }

  private func requireImage(_ image: CIImage?, at url: URL) throws -> CIImage {
    guard let image else {
      throw ExportHEICError.couldNotReadImage(url.path)
    }
    return image
  }
}

extension ExportHEICCommand.ExportHEICCommandSignature {
  enum ValidationError: Error, CustomStringConvertible {
    case argumentNotAllowed(String, String)
    case coexistencyNotAllowed(String, String)
    case missingEitherArgument([String])

    var description: String {
      switch self {
      case .argumentNotAllowed(let label, let input):
        return "`--\(label)` is not allowed with \(input)"
      case .coexistencyNotAllowed(let label, let other):
        return "`--\(label)` cannot be used with `--\(other)`"
      case .missingEitherArgument(let labels):
        return "One of "
          + labels.map { "--" + $0 }.joined(separator: ", ")
          + " must be specified"
      }
    }
  }

  func checkOptions() throws {
    try validateQualityOptions()
    if sdrFrom == nil && hdrFrom == nil {
      throw ValidationError.missingEitherArgument(["sdr-from", "hdr-from"])
    }
  }

  private func validateQualityOptions() throws {
    if quality != nil {
      if sizeLimit != nil {
        throw ValidationError.coexistencyNotAllowed("quality", "size-limit")
      }
      if minQuality != nil {
        throw ValidationError.coexistencyNotAllowed("quality", "min-quality")
      }
      if maxQuality != nil {
        throw ValidationError.coexistencyNotAllowed("quality", "max-quality")
      }
      if sizeLimitAccuracy != nil {
        throw ValidationError.coexistencyNotAllowed(
          "quality", "size-limit-accuracy")
      }
    } else if sizeLimit == nil {
      throw ValidationError.missingEitherArgument(["quality", "size-limit"])
    }
  }
}
