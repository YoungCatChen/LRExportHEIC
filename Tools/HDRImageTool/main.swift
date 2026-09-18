import CoreGraphics
import CoreImage
import Foundation
import ImageIO

private enum ToolError: Error, CustomStringConvertible {
  case invalidArguments(String)
  case cannotReadImage(String)
  case cannotWriteImage(String)
  case incompatibleImages(String)
  case unsupported(String)

  var description: String {
    switch self {
    case .invalidArguments(let message), .cannotReadImage(let message),
      .cannotWriteImage(let message), .incompatibleImages(let message),
      .unsupported(let message):
      return message
    }
  }
}

private enum ImageKind: String, Codable {
  case sdr = "SDR"
  case nativeHDR = "Native HDR"
  case adaptiveHDR = "Adaptive HDR"
}

private enum Rendition: String, Codable {
  case sdr
  case hdr
}

private enum RenditionChoice: String {
  case auto
  case sdr
  case hdr
  case both
}

private struct PixelStatistics: Codable {
  let meanRGB: Double
  let minimumRGB: Double
  let maximumRGB: Double
  let lumaAtLeast90Percent: Double
  let lumaAtLeast95Percent: Double
  let lumaAtLeast98Percent: Double
  let lumaAtLeast99Percent: Double
}

private struct Inspection: Codable {
  let path: String
  let fileType: String
  let kind: ImageKind
  let width: Int
  let height: Int
  let sourceDepth: Int?
  let sourceProfile: String?
  let baseHeadroom: Double
  let hdrHeadroom: Double?
  let hasSDRRendition: Bool
  let hasHDRRendition: Bool
  let hasGainMap: Bool
  let gainMapChannels: Int?
  let gainMapWidth: Int?
  let gainMapHeight: Int?
  let sdrStatistics: PixelStatistics?
}

private struct ComparisonMetrics: Codable {
  let rendition: Rendition
  let domain: String
  let width: Int
  let height: Int
  let sampleCount: Int
  let normalizedRMSE: Double
  let psnrDB: Double?
}

private struct ComparisonReport: Codable {
  let inputA: String
  let inputB: String
  let requestedRendition: String
  let comparisons: [ComparisonMetrics]
  let skippedReason: String?
}

private struct VerifyReport: Codable {
  let output: Inspection
  let sdrComparison: ComparisonMetrics
  let hdrComparison: ComparisonMetrics
}

private struct ParsedArguments {
  var flags: Set<String> = []
  var options: [String: String] = [:]
  var positionals: [String] = []
}

private struct ImageDocument {
  let url: URL
  let kind: ImageKind
  let base: CIImage
  let sdr: CIImage?
  let hdr: CIImage?
  let gainMap: CIImage?
}

private final class HDRImageAnalyzer {
  private let context = CIContext()
  private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
  private let linearSRGB = CGColorSpace(
    name: CGColorSpace.extendedLinearSRGB)!
  private let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!

  func load(_ path: String) throws -> ImageDocument {
    let url = expandedURL(path)
    let options: [CIImageOption: Any] = [.applyOrientationProperty: true]
    guard let base = CIImage(contentsOf: url, options: options) else {
      throw ToolError.cannotReadImage("Could not read image: \(url.path)")
    }

    let gainOptions: [CIImageOption: Any] = [
      .applyOrientationProperty: true,
      .auxiliaryHDRGainMap: true,
    ]
    let gainMap = CIImage(contentsOf: url, options: gainOptions)
    if let gainMap {
      guard #available(macOS 14.0, *) else {
        throw ToolError.unsupported(
          "Adaptive HDR expansion requires macOS 14 or later")
      }
      let hdrOptions: [CIImageOption: Any] = [
        .applyOrientationProperty: true,
        .expandToHDR: true,
      ]
      guard let hdr = CIImage(contentsOf: url, options: hdrOptions) else {
        throw ToolError.cannotReadImage(
          "Could not expand adaptive HDR image: \(url.path)")
      }
      return ImageDocument(
        url: url,
        kind: .adaptiveHDR,
        base: base,
        sdr: base,
        hdr: hdr,
        gainMap: gainMap)
    }

    if contentHeadroom(base) > 1.0001 || maximumLinearComponent(base) > 1.0001 {
      return ImageDocument(
        url: url,
        kind: .nativeHDR,
        base: base,
        sdr: nil,
        hdr: base,
        gainMap: nil)
    }

    return ImageDocument(
      url: url,
      kind: .sdr,
      base: base,
      sdr: base,
      hdr: nil,
      gainMap: nil)
  }

  func inspect(_ document: ImageDocument) throws -> Inspection {
    let properties = document.base.properties
    let depth = properties["Depth"] as? Int
    let profile = properties["ProfileName"] as? String
    let gainMapChannels = document.gainMap.flatMap(gainMapChannelCount)
    let sdrStatistics = try document.sdr.map(pixelStatistics)

    return Inspection(
      path: document.url.path,
      fileType: fileType(document.url),
      kind: document.kind,
      width: Int(document.base.extent.width.rounded()),
      height: Int(document.base.extent.height.rounded()),
      sourceDepth: depth,
      sourceProfile: profile ?? document.base.colorSpace?.name as? String,
      baseHeadroom: Double(contentHeadroom(document.base)),
      hdrHeadroom: document.hdr.map { Double(contentHeadroom($0)) },
      hasSDRRendition: document.sdr != nil,
      hasHDRRendition: document.hdr != nil,
      hasGainMap: document.gainMap != nil,
      gainMapChannels: gainMapChannels,
      gainMapWidth: document.gainMap.map {
        Int($0.extent.width.rounded())
      },
      gainMapHeight: document.gainMap.map {
        Int($0.extent.height.rounded())
      },
      sdrStatistics: sdrStatistics)
  }

  func compare(
    _ first: ImageDocument,
    _ second: ImageDocument,
    choice: RenditionChoice
  ) throws -> ComparisonReport {
    var metrics: [ComparisonMetrics] = []
    let wantsSDR = choice == .auto || choice == .sdr || choice == .both
    let wantsHDR = choice == .auto || choice == .hdr || choice == .both

    if wantsSDR, let firstSDR = first.sdr, let secondSDR = second.sdr {
      metrics.append(
        try comparisonMetrics(
          firstSDR,
          secondSDR,
          rendition: .sdr,
          colorSpace: sRGB,
          domain: "sRGB encoded RGB, UInt16 normalized [0,1]"))
    } else if choice == .sdr || choice == .both {
      throw ToolError.incompatibleImages(
        "Both inputs must expose an SDR rendition")
    }

    if wantsHDR, let firstHDR = first.hdr, let secondHDR = second.hdr {
      metrics.append(
        try comparisonMetrics(
          firstHDR,
          secondHDR,
          rendition: .hdr,
          colorSpace: pq,
          domain:
            "ITU-R BT.2100 PQ RGB, UInt16 normalized [0,1]"))
    } else if choice == .hdr || choice == .both {
      throw ToolError.incompatibleImages(
        "Both inputs must expose an HDR rendition")
    }

    let skippedReason: String?
    if metrics.isEmpty {
      skippedReason =
        "No common rendition is available; no implicit tone mapping was used"
    } else {
      skippedReason = nil
    }

    return ComparisonReport(
      inputA: first.url.path,
      inputB: second.url.path,
      requestedRendition: choice.rawValue,
      comparisons: metrics,
      skippedReason: skippedReason)
  }

  func extract(
    _ document: ImageDocument,
    outputDirectory: URL,
    force: Bool
  ) throws {
    try FileManager.default.createDirectory(
      at: outputDirectory,
      withIntermediateDirectories: true)

    if let sdr = document.sdr {
      try writePNG(
        sdr,
        to: outputDirectory.appendingPathComponent("primary-sdr.png"),
        format: .RGBA8,
        colorSpace: sRGB,
        force: force)
    }
    if let gainMap = document.gainMap {
      try writePNG(
        gainMap,
        to: outputDirectory.appendingPathComponent("gain-map.png"),
        format: .RGBA8,
        colorSpace: sRGB,
        force: force)
    }
    if let hdr = document.hdr {
      try writePNG(
        hdr,
        to: outputDirectory.appendingPathComponent("hdr-pq.png"),
        format: .RGBA16,
        colorSpace: pq,
        force: force)
    }
  }

  func encodeHEIC(
    sdrPath: String,
    hdrPath: String,
    outputPath: String,
    rgbGainMap: Bool,
    quality: Double,
    force: Bool
  ) throws {
    guard #available(macOS 15.0, *) else {
      throw ToolError.unsupported(
        "Explicit adaptive HDR encoding requires macOS 15 or later")
    }
    guard (0...1).contains(quality) else {
      throw ToolError.invalidArguments("Quality must be between 0 and 1")
    }

    let sdrDocument = try load(sdrPath)
    let hdrDocument = try load(hdrPath)
    guard let sdr = sdrDocument.sdr else {
      throw ToolError.incompatibleImages(
        "SDR input does not expose an SDR rendition")
    }
    guard let hdr = hdrDocument.hdr else {
      throw ToolError.incompatibleImages(
        "HDR input does not expose an HDR rendition")
    }
    try requireMatchingGeometry(sdr, hdr)

    let outputURL = expandedURL(outputPath)
    try refuseOverwrite(outputURL, force: force)
    var options: [CIImageRepresentationOption: Any] = [
      kCGImageDestinationLossyCompressionQuality
        as CIImageRepresentationOption: quality,
      .hdrImage: hdr,
      .hdrGainMapAsRGB: rgbGainMap,
    ]
    options[kCGImageDestinationEncodeRequest as CIImageRepresentationOption] =
      kCGImageDestinationEncodeToISOGainmap

    do {
      try context.writeHEIFRepresentation(
        of: sdr,
        to: outputURL,
        format: .RGBA8,
        colorSpace: sRGB,
        options: options)
    } catch {
      throw ToolError.cannotWriteImage(
        "Could not write HEIC: \(error.localizedDescription)")
    }

    let output = try load(outputURL.path)
    guard output.kind == .adaptiveHDR else {
      try? FileManager.default.removeItem(at: outputURL)
      throw ToolError.cannotWriteImage(
        "Encoder output did not contain an adaptive HDR gain map")
    }
  }

  func verify(
    outputPath: String,
    sdrReferencePath: String,
    hdrReferencePath: String
  ) throws -> VerifyReport {
    let output = try load(outputPath)
    guard let outputSDR = output.sdr, let outputHDR = output.hdr,
      output.kind == .adaptiveHDR
    else {
      throw ToolError.incompatibleImages(
        "Output is not an adaptive HDR image")
    }

    let sdrReference = try load(sdrReferencePath)
    let hdrReference = try load(hdrReferencePath)
    guard let expectedSDR = sdrReference.sdr else {
      throw ToolError.incompatibleImages(
        "SDR reference does not expose an SDR rendition")
    }
    guard let expectedHDR = hdrReference.hdr else {
      throw ToolError.incompatibleImages(
        "HDR reference does not expose an HDR rendition")
    }

    return VerifyReport(
      output: try inspect(output),
      sdrComparison: try comparisonMetrics(
        outputSDR,
        expectedSDR,
        rendition: .sdr,
        colorSpace: sRGB,
        domain: "sRGB encoded RGB, UInt16 normalized [0,1]"),
      hdrComparison: try comparisonMetrics(
        outputHDR,
        expectedHDR,
        rendition: .hdr,
        colorSpace: pq,
        domain: "ITU-R BT.2100 PQ RGB, UInt16 normalized [0,1]"))
  }

  private func maximumLinearComponent(_ image: CIImage) -> Float {
    guard
      let filter = CIFilter(
        name: "CIAreaMaximum",
        parameters: [
          kCIInputImageKey: image,
          kCIInputExtentKey: CIVector(cgRect: image.extent),
        ]),
      let output = filter.outputImage
    else {
      return 0
    }

    var pixel = [Float](repeating: 0, count: 4)
    context.render(
      output,
      toBitmap: &pixel,
      rowBytes: MemoryLayout<Float>.size * 4,
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBAf,
      colorSpace: linearSRGB)
    return max(pixel[0], pixel[1], pixel[2])
  }

  private func contentHeadroom(_ image: CIImage) -> Float {
    if #available(macOS 15.0, *) {
      return image.contentHeadroom
    }
    if let value = image.properties["Headroom"] as? NSNumber {
      return value.floatValue
    }
    return 1
  }

  private func gainMapChannelCount(_ gainMap: CIImage) -> Int? {
    let key = kCGImageAuxiliaryDataInfoMetadata as String
    guard let metadata = gainMap.properties[key] else {
      return nil
    }
    let description = String(describing: metadata)
    let count = description.components(separatedBy: "GainMapMax =").count - 1
    if count >= 3 { return 3 }
    if count == 1 { return 1 }
    return nil
  }

  private func pixelStatistics(_ image: CIImage) throws -> PixelStatistics {
    let rendered = try render(image, colorSpace: sRGB, format: .RGBA8)
    let bytes = [UInt8](rendered.data)
    let pixelCount = rendered.width * rendered.height
    var sum = 0.0
    var minimum = 1.0
    var maximum = 0.0
    var thresholdCounts = [0, 0, 0, 0]
    let thresholds = [0.90, 0.95, 0.98, 0.99]

    for offset in stride(from: 0, to: bytes.count, by: 4) {
      let red = Double(bytes[offset]) / 255
      let green = Double(bytes[offset + 1]) / 255
      let blue = Double(bytes[offset + 2]) / 255
      sum += red + green + blue
      minimum = min(minimum, red, green, blue)
      maximum = max(maximum, red, green, blue)
      let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
      for index in thresholds.indices where luma >= thresholds[index] {
        thresholdCounts[index] += 1
      }
    }

    func percentage(_ count: Int) -> Double {
      100 * Double(count) / Double(pixelCount)
    }
    return PixelStatistics(
      meanRGB: sum / Double(pixelCount * 3),
      minimumRGB: minimum,
      maximumRGB: maximum,
      lumaAtLeast90Percent: percentage(thresholdCounts[0]),
      lumaAtLeast95Percent: percentage(thresholdCounts[1]),
      lumaAtLeast98Percent: percentage(thresholdCounts[2]),
      lumaAtLeast99Percent: percentage(thresholdCounts[3]))
  }

  private func comparisonMetrics(
    _ first: CIImage,
    _ second: CIImage,
    rendition: Rendition,
    colorSpace: CGColorSpace,
    domain: String
  ) throws -> ComparisonMetrics {
    try requireMatchingGeometry(first, second)
    let firstPixels = try render(
      first,
      colorSpace: colorSpace,
      format: .RGBA16)
    let secondPixels = try render(
      second,
      colorSpace: colorSpace,
      format: .RGBA16)

    let firstValues = firstPixels.data.withUnsafeBytes {
      Array($0.bindMemory(to: UInt16.self))
    }
    let secondValues = secondPixels.data.withUnsafeBytes {
      Array($0.bindMemory(to: UInt16.self))
    }
    var squaredError = 0.0
    var sampleCount = 0
    for offset in stride(from: 0, to: firstValues.count, by: 4) {
      for channel in 0..<3 {
        let firstValue = Double(firstValues[offset + channel]) / 65535
        let secondValue = Double(secondValues[offset + channel]) / 65535
        let difference = firstValue - secondValue
        squaredError += difference * difference
        sampleCount += 1
      }
    }

    let rmse = sqrt(squaredError / Double(sampleCount))
    let psnr = rmse == 0 ? nil : 20 * log10(1 / rmse)
    return ComparisonMetrics(
      rendition: rendition,
      domain: domain,
      width: firstPixels.width,
      height: firstPixels.height,
      sampleCount: sampleCount,
      normalizedRMSE: rmse,
      psnrDB: psnr)
  }

  private func render(
    _ image: CIImage,
    colorSpace: CGColorSpace,
    format: CIFormat
  ) throws -> (data: Data, width: Int, height: Int) {
    let width = Int(image.extent.width.rounded())
    let height = Int(image.extent.height.rounded())
    guard width > 0, height > 0 else {
      throw ToolError.cannotReadImage("Image has an empty extent")
    }
    let bytesPerComponent = format == .RGBA8 ? 1 : 2
    let rowBytes = width * 4 * bytesPerComponent
    var data = Data(count: rowBytes * height)
    data.withUnsafeMutableBytes { buffer in
      context.render(
        image,
        toBitmap: buffer.baseAddress!,
        rowBytes: rowBytes,
        bounds: image.extent,
        format: format,
        colorSpace: colorSpace)
    }
    return (data, width, height)
  }

  private func writePNG(
    _ image: CIImage,
    to url: URL,
    format: CIFormat,
    colorSpace: CGColorSpace,
    force: Bool
  ) throws {
    try refuseOverwrite(url, force: force)
    do {
      try context.writePNGRepresentation(
        of: image,
        to: url,
        format: format,
        colorSpace: colorSpace,
        options: [:])
    } catch {
      throw ToolError.cannotWriteImage(
        "Could not write \(url.path): \(error.localizedDescription)")
    }
  }

  private func requireMatchingGeometry(
    _ first: CIImage,
    _ second: CIImage
  ) throws {
    let firstSize = first.extent.size
    let secondSize = second.extent.size
    guard firstSize == secondSize else {
      throw ToolError.incompatibleImages(
        "Image dimensions differ: "
          + "\(Int(firstSize.width))x\(Int(firstSize.height)) vs "
          + "\(Int(secondSize.width))x\(Int(secondSize.height)); "
          + "no implicit resize was used")
    }
  }

  private func refuseOverwrite(_ url: URL, force: Bool) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else {
      if force {
        try FileManager.default.removeItem(at: url)
        return
      }
      throw ToolError.cannotWriteImage(
        "Refusing to overwrite existing file: \(url.path)")
    }
  }

  private func fileType(_ url: URL) -> String {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let type = CGImageSourceGetType(source)
    else {
      return url.pathExtension.lowercased()
    }
    return type as String
  }
}

private func expandedURL(_ path: String) -> URL {
  let expanded = (path as NSString).expandingTildeInPath
  return URL(fileURLWithPath: expanded).standardizedFileURL
}

private func parseArguments(
  _ values: [String],
  valueOptions: Set<String>,
  allowedFlags: Set<String>
) throws -> ParsedArguments {
  var result = ParsedArguments()
  var index = 0
  while index < values.count {
    let value = values[index]
    if value.hasPrefix("--") {
      let nameAndValue = value.dropFirst(2).split(
        separator: "=", maxSplits: 1
      ).map(String.init)
      let name = nameAndValue[0]
      if valueOptions.contains(name) {
        let optionValue: String
        if nameAndValue.count == 2 {
          optionValue = nameAndValue[1]
        } else {
          index += 1
          guard index < values.count else {
            throw ToolError.invalidArguments(
              "Missing value for --\(name)")
          }
          optionValue = values[index]
        }
        result.options[name] = optionValue
      } else if allowedFlags.contains(name), nameAndValue.count == 1 {
        result.flags.insert(name)
      } else {
        throw ToolError.invalidArguments("Unknown option: \(value)")
      }
    } else {
      result.positionals.append(value)
    }
    index += 1
  }
  return result
}

private func printJSON<T: Encodable>(_ value: T) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  let data = try encoder.encode(value)
  print(String(decoding: data, as: UTF8.self))
}

private func printInspection(_ value: Inspection) {
  print("Path: \(value.path)")
  print("File type: \(value.fileType)")
  print("Kind: \(value.kind.rawValue)")
  print("Geometry: \(value.width)x\(value.height)")
  print("Source depth: \(value.sourceDepth.map(String.init) ?? "unknown")")
  print("Source profile: \(value.sourceProfile ?? "unknown")")
  print(String(format: "Base headroom: %.6fx", value.baseHeadroom))
  if let hdrHeadroom = value.hdrHeadroom {
    print(String(format: "HDR headroom: %.6fx", hdrHeadroom))
  }
  print("SDR rendition: \(value.hasSDRRendition ? "yes" : "no")")
  print("HDR rendition: \(value.hasHDRRendition ? "yes" : "no")")
  print("Gain map: \(value.hasGainMap ? "yes" : "no")")
  if let channels = value.gainMapChannels {
    print("Gain map channels: \(channels)")
  }
  if let width = value.gainMapWidth, let height = value.gainMapHeight {
    print("Gain map geometry: \(width)x\(height)")
  }
  if let statistics = value.sdrStatistics {
    print("SDR statistics (sRGB encoded RGB):")
    print(String(format: "  Mean RGB: %.8f", statistics.meanRGB))
    print(String(format: "  Minimum RGB: %.8f", statistics.minimumRGB))
    print(String(format: "  Maximum RGB: %.8f", statistics.maximumRGB))
    print(
      String(
        format: "  Luma >= 90%%: %.6f%%",
        statistics.lumaAtLeast90Percent))
    print(
      String(
        format: "  Luma >= 95%%: %.6f%%",
        statistics.lumaAtLeast95Percent))
    print(
      String(
        format: "  Luma >= 98%%: %.6f%%",
        statistics.lumaAtLeast98Percent))
    print(
      String(
        format: "  Luma >= 99%%: %.6f%%",
        statistics.lumaAtLeast99Percent))
  }
}

private func printMetrics(_ value: ComparisonMetrics) {
  print("Rendition: \(value.rendition.rawValue.uppercased())")
  print("Domain: \(value.domain)")
  print("Geometry: \(value.width)x\(value.height)")
  print("Alpha: ignored")
  print("Resampling: none")
  print(String(format: "Normalized RMSE: %.10f", value.normalizedRMSE))
  if let psnr = value.psnrDB {
    print(String(format: "PSNR: %.6f dB", psnr))
  } else {
    print("PSNR: infinity")
  }
}

private func printComparison(_ value: ComparisonReport) {
  print("Input A: \(value.inputA)")
  print("Input B: \(value.inputB)")
  print("Requested rendition: \(value.requestedRendition)")
  if let reason = value.skippedReason {
    print("Comparison skipped: \(reason)")
  }
  for (_, metrics) in value.comparisons.enumerated() {
    print("")
    printMetrics(metrics)
  }
}

private func usage() -> String {
  """
  Usage:
    hdr-image-tool inspect [--json] IMAGE
    hdr-image-tool extract [--force] --output-dir DIR IMAGE
    hdr-image-tool compare [--json] [--rendition auto|sdr|hdr|both] IMAGE_A IMAGE_B
    hdr-image-tool encode-heic [--force] --sdr IMAGE --hdr IMAGE --output FILE [--gain-map mono|rgb] [--quality 0.0...1.0]
    hdr-image-tool verify-heic [--json] --sdr-reference IMAGE --hdr-reference IMAGE OUTPUT

  Comparisons never resize, crop, or implicitly tone-map an image.
  """
}

private func run() throws {
  var arguments = Array(CommandLine.arguments.dropFirst())
  guard let command = arguments.first else {
    throw ToolError.invalidArguments(usage())
  }
  arguments.removeFirst()
  if command == "help" || command == "--help" || command == "-h" {
    print(usage())
    return
  }

  let analyzer = HDRImageAnalyzer()
  switch command {
  case "inspect":
    let parsed = try parseArguments(
      arguments,
      valueOptions: [],
      allowedFlags: ["json"])
    guard parsed.positionals.count == 1 else {
      throw ToolError.invalidArguments("inspect requires exactly one image")
    }
    let inspection = try analyzer.inspect(
      analyzer.load(parsed.positionals[0]))
    if parsed.flags.contains("json") {
      try printJSON(inspection)
    } else {
      printInspection(inspection)
    }

  case "compare":
    let parsed = try parseArguments(
      arguments,
      valueOptions: ["rendition"],
      allowedFlags: ["json"])
    guard parsed.positionals.count == 2 else {
      throw ToolError.invalidArguments("compare requires exactly two images")
    }
    let choiceName = parsed.options["rendition"] ?? "auto"
    guard let choice = RenditionChoice(rawValue: choiceName) else {
      throw ToolError.invalidArguments(
        "Invalid rendition: \(choiceName)")
    }
    let report = try analyzer.compare(
      analyzer.load(parsed.positionals[0]),
      analyzer.load(parsed.positionals[1]),
      choice: choice)
    if parsed.flags.contains("json") {
      try printJSON(report)
    } else {
      printComparison(report)
    }

  case "extract":
    let parsed = try parseArguments(
      arguments,
      valueOptions: ["output-dir"],
      allowedFlags: ["force"])
    guard parsed.positionals.count == 1,
      let outputPath = parsed.options["output-dir"]
    else {
      throw ToolError.invalidArguments(
        "extract requires IMAGE and --output-dir DIR")
    }
    let outputURL = expandedURL(outputPath)
    try analyzer.extract(
      analyzer.load(parsed.positionals[0]),
      outputDirectory: outputURL,
      force: parsed.flags.contains("force"))
    print("Extracted renditions to: \(outputURL.path)")

  case "encode-heic":
    let parsed = try parseArguments(
      arguments,
      valueOptions: ["sdr", "hdr", "output", "gain-map", "quality"],
      allowedFlags: ["force"])
    guard parsed.positionals.isEmpty,
      let sdr = parsed.options["sdr"],
      let hdr = parsed.options["hdr"],
      let output = parsed.options["output"]
    else {
      throw ToolError.invalidArguments(
        "encode-heic requires --sdr, --hdr, and --output")
    }
    let gainMap = parsed.options["gain-map"] ?? "rgb"
    guard gainMap == "rgb" || gainMap == "mono" else {
      throw ToolError.invalidArguments("Gain map must be mono or rgb")
    }
    let qualityText = parsed.options["quality"] ?? "0.9"
    guard let quality = Double(qualityText) else {
      throw ToolError.invalidArguments("Invalid quality: \(qualityText)")
    }
    try analyzer.encodeHEIC(
      sdrPath: sdr,
      hdrPath: hdr,
      outputPath: output,
      rgbGainMap: gainMap == "rgb",
      quality: quality,
      force: parsed.flags.contains("force"))
    print("Wrote adaptive HDR HEIC: \(expandedURL(output).path)")

  case "verify-heic":
    let parsed = try parseArguments(
      arguments,
      valueOptions: ["sdr-reference", "hdr-reference"],
      allowedFlags: ["json"])
    guard parsed.positionals.count == 1,
      let sdrReference = parsed.options["sdr-reference"],
      let hdrReference = parsed.options["hdr-reference"]
    else {
      throw ToolError.invalidArguments(
        "verify-heic requires OUTPUT, --sdr-reference, and --hdr-reference")
    }
    let report = try analyzer.verify(
      outputPath: parsed.positionals[0],
      sdrReferencePath: sdrReference,
      hdrReferencePath: hdrReference)
    if parsed.flags.contains("json") {
      try printJSON(report)
    } else {
      print("Output")
      printInspection(report.output)
      print("\nSDR comparison")
      printMetrics(report.sdrComparison)
      print("\nHDR comparison")
      printMetrics(report.hdrComparison)
    }

  default:
    throw ToolError.invalidArguments(
      "Unknown command: \(command)\n\n\(usage())")
  }
}

do {
  try run()
} catch {
  FileHandle.standardError.write(
    Data("error: \(error)\n".utf8))
  exit(1)
}
