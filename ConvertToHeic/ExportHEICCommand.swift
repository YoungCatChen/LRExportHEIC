import ConsoleKit
import CoreImage
import Foundation

enum ExportHEICError: Error, CustomStringConvertible {
  var description: String {
    switch self {
    case .couldNotReadImage(let path):
      return "Could not read image file: \(path)"
    case .hdrOutputRequiresMacOS15:
      return "HDR HEIC output requires macOS 15 or newer"
    case .imageDimensionsDoNotMatch(let sdrSize, let hdrSize):
      return "SDR and HDR image dimensions do not match: "
        + "\(sdrSize.width)x\(sdrSize.height) vs "
        + "\(hdrSize.width)x\(hdrSize.height)"
    }
  }

  case couldNotReadImage(String)
  case hdrOutputRequiresMacOS15
  case imageDimensionsDoNotMatch(CGSize, CGSize)
}

struct ExportHEICCommand: Command {
  public struct ExportHEICCommandSignature: CommandSignature {
    @Option(
      name: "input-file",
      help: "Path to input image file; the SDR primary with --hdr-output",
      required: true)
    var inputFile: String!

    @Option(
      name: "hdr-input-file",
      help: "Path to the Lightroom-rendered HDR image used with --hdr-output")
    var hdrInputFile: String?

    @Option(
      name: "quality", help: "Compression quality. Cannot be used with --size-limit. Allowed range: 0.0 - 1.0",
      allowedValues: 0.0...1.0)
    var quality: Double?

    @Option(
      name: "size-limit",
      help: "Limit the size in bytes of the resulting image file, instead of specifying a "
        + "quality directly. Cannot be used with --quality",
      allowedValues: 1...Int64.max)
    var sizeLimit: Int64?

    @Option(
      name: "size-limit-accuracy",
      help: "When this program tries multiple times to find the satisfying quality, it can stop early to save time "
        + "if the file's size satisfies `size limit * accuracy <= actual size <= size limit`. "
        + "Allowed range: 0.1 - 1.0. Default: 0.9",
      allowedValues: 0.1...1.0)
    var sizeLimitAccuracy: Double?

    @Option(
      name: "min-quality",
      help: "Minimal allowed compression quality, if --size-limit is used. Allowed range: 0.0 - 1.0. Default: 0.0",
      allowedValues: 0.0...1.0)
    var minQuality: Double?

    @Option(
      name: "max-quality",
      help: "Maximal allowed compression quality, if --size-limit is used. Allowed range: 0.0 - 1.0. Default: 1.0",
      allowedValues: 0.0...1.0)
    var maxQuality: Double?

    @Option(
      name: "color-space",
      help: "Name of the output color space. Omit to use input image color space",
      allowedValues: [
        CGColorSpace.sRGB,
        CGColorSpace.displayP3,
        CGColorSpace.adobeRGB1998,
      ].map { ($0 as String).replacingOccurrences(of: "kCGColorSpace", with: "") })
    var colorSpaceName: String?

    @Argument(name: "output-file", help: "Path to where the output file will be placed")
    var outputFile: String

    @Flag(name: "verbose", help: "Print the decision making process verbosely")
    var verbose: Bool

    @Flag(name: "hdr-output", help: "Write HDR HEIC with a gain map. Requires macOS 15 or newer")
    var hdrOutput: Bool

    var inputFileURL: URL! {
      guard let inputFile = self.inputFile else {
        fatalError("Missing inputFile")
      }

      return URL(fileURLWithPath: inputFile)
    }

    var outputFileURL: URL {
      return URL(fileURLWithPath: outputFile)
    }

    var hdrInputFileURL: URL? {
      return hdrInputFile.map { URL(fileURLWithPath: $0) }
    }

    var colorSpace: CGColorSpace? {
      guard let colorSpaceName = self.colorSpaceName else {
        return nil
      }

      return CGColorSpace(name: "kCGColorSpace\(colorSpaceName)" as CFString)
    }

    public init() {}
  }

  var help: String {
    return "Export input image file as HEIC"
  }

  func run(using context: CommandContext, signature: ExportHEICCommandSignature) throws {
    try signature.enhanceOptions()
    try signature.checkOptions()

    guard let inputImage = CIImage(contentsOf: signature.inputFileURL) else {
      throw ExportHEICError.couldNotReadImage(signature.inputFileURL.path)
    }

    let hdrImage: CIImage?
    if let hdrInputFileURL = signature.hdrInputFileURL {
      hdrImage = Self.readHDRImage(from: hdrInputFileURL)
      guard hdrImage != nil else {
        throw ExportHEICError.couldNotReadImage(hdrInputFileURL.path)
      }
    } else {
      hdrImage = nil
    }

    if let hdrImage = hdrImage,
      inputImage.extent.size != hdrImage.extent.size
    {
      throw ExportHEICError.imageDimensionsDoNotMatch(
        inputImage.extent.size,
        hdrImage.extent.size)
    }

    let bitDepth = inputImage.properties["Depth"] as? Int ?? 8
    let colorSpace =
      signature.hdrOutput
      ? CGColorSpace(name: CGColorSpace.sRGB)!
      : signature.colorSpace ?? inputImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    let shouldUseHEIF10 = bitDepth > 8

    if signature.verbose {
      context.console.print("Input URL: \(signature.inputFileURL!)")
      context.console.print(
        "Input Colorspace: \(String(describing: inputImage.colorSpace))")
      context.console.print("Input Bitdepth: \(bitDepth)")
      context.console.print("HDR Output: \(signature.hdrOutput)")
      if let hdrInputFileURL = signature.hdrInputFileURL,
        let hdrImage = hdrImage
      {
        context.console.print("HDR Input URL: \(hdrInputFileURL)")
        context.console.print(
          "HDR Input Colorspace: \(String(describing: hdrImage.colorSpace))")
      }
    }

    if signature.quality != nil {
      try writeHEIF(
        of: inputImage,
        to: signature.outputFileURL,
        in: colorSpace,
        withQuality: signature.quality!,
        shouldUseHEIF10: shouldUseHEIF10,
        hdrImage: hdrImage,
        verbose: signature.verbose)
    } else {
      try writeSizeLimitedHEIF(
        of: inputImage,
        to: signature.outputFileURL,
        in: colorSpace,
        withSizeLimit: signature.sizeLimit!,
        withSizeLimitAccuracy: signature.sizeLimitAccuracy ?? 0.9,
        withinRange: (signature.minQuality ?? 0)...(signature.maxQuality ?? 1),
        shouldUseHEIF10: shouldUseHEIF10,
        hdrImage: hdrImage,
        verbose: signature.verbose)
    }
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
}

extension ExportHEICCommand.ExportHEICCommandSignature {
  enum MyError: Error, CustomStringConvertible {
    var description: String {
      switch self {
      case .coexistencyNotAllowed(let label, let anotherArgumentLabel):
        return "`--\(label)` cannot be used with `--\(anotherArgumentLabel)`"
      case .missingEitherArgument(let labels):
        let flags = labels.map({ s in "--" + s }).joined(separator: ", ")
        return "One of \(flags) must be specified"
      case .requiredArgument(let label, let requiringLabel):
        return "`--\(label)` is required with `--\(requiringLabel)`"
      case .argumentRequiresFlag(let label, let flagLabel):
        return "`--\(label)` requires `--\(flagLabel)`"
      }
    }

    case coexistencyNotAllowed(_ label: String, _ anotherArgumentLabel: String)
    case missingEitherArgument(_ labels: [String])
    case requiredArgument(_ label: String, _ requiringLabel: String)
    case argumentRequiresFlag(_ label: String, _ flagLabel: String)
  }

  func checkOptions() throws {
    if quality != nil {
      if sizeLimit != nil { throw MyError.coexistencyNotAllowed("quality", "size-limit") }
      if minQuality != nil { throw MyError.coexistencyNotAllowed("quality", "min-quality") }
      if maxQuality != nil { throw MyError.coexistencyNotAllowed("quality", "max-quality") }
    } else {
      if sizeLimit == nil { throw MyError.missingEitherArgument(["quality", "size-limit"]) }
    }
    if hdrOutput && hdrInputFile == nil {
      throw MyError.requiredArgument("hdr-input-file", "hdr-output")
    }
    if !hdrOutput && hdrInputFile != nil {
      throw MyError.argumentRequiresFlag("hdr-input-file", "hdr-output")
    }
  }
}
