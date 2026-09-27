import CoreImage
import Foundation
import ImageIO
import XCTest

#if SWIFT_PACKAGE
  import ConsoleKit
  @testable import ConvertToHeic
  import HEIFEncoding
#endif

final class LRExportHEICTests: XCTestCase {
  private var temporaryDirectory: URL!
  private let context = CIContext()
  private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
  }

  #if SWIFT_PACKAGE
    func testParsesSDRInput() throws {
      var input = CommandInput(arguments: [
        "ConvertToHeic",
        "--quality", "0.75",
        "--output-bit-depth", "8",
        "--output-color-space", "DisplayP3",
        "--sdr-from", "primary.tif",
        "output.heic",
      ])

      let signature = try ExportHEICCommand.ExportHEICCommandSignature(
        from: &input)
      try signature.checkOptions()

      XCTAssertEqual(signature.sdrFrom, "primary.tif")
      XCTAssertNil(signature.hdrFrom)
      XCTAssertEqual(signature.outputFile, "output.heic")
    }

    func testParsesHDRInput() throws {
      var input = CommandInput(arguments: [
        "ConvertToHeic",
        "--quality", "0.75",
        "--output-bit-depth", "10",
        "--hdr-from", "hdr.tif",
        "output.heic",
      ])

      let signature = try ExportHEICCommand.ExportHEICCommandSignature(
        from: &input)
      try signature.checkOptions()

      XCTAssertNil(signature.sdrFrom)
      XCTAssertEqual(signature.hdrFrom, "hdr.tif")
      XCTAssertEqual(signature.outputFile, "output.heic")
    }

    func testParsesAdaptiveHDRInputs() throws {
      var input = CommandInput(arguments: [
        "ConvertToHeic",
        "--quality", "0.75",
        "--output-bit-depth", "10",
        "--output-color-space", "DisplayP3",
        "--sdr-from", "sdr.tif",
        "--hdr-from", "hdr.tif",
        "output.heic",
      ])

      let signature = try ExportHEICCommand.ExportHEICCommandSignature(
        from: &input)
      try signature.checkOptions()

      XCTAssertEqual(signature.sdrFrom, "sdr.tif")
      XCTAssertEqual(signature.hdrFrom, "hdr.tif")
      XCTAssertEqual(signature.outputColorSpaceName, "DisplayP3")
    }

    func testRejectsMissingRendition() throws {
      var input = CommandInput(arguments: [
        "ConvertToHeic",
        "--quality", "0.75",
        "output.heic",
      ])
      let signature = try ExportHEICCommand.ExportHEICCommandSignature(
        from: &input)

      XCTAssertThrowsError(try signature.checkOptions())
    }

    func testAcceptsPQOutputColorSpaceForHDRPrimary() throws {
      var input = CommandInput(arguments: [
        "ConvertToHeic",
        "--quality", "0.75",
        "--output-color-space", "DisplayP3_PQ",
        "--hdr-from", "hdr.tif",
        "output.heic",
      ])
      let signature = try ExportHEICCommand.ExportHEICCommandSignature(
        from: &input)

      try signature.checkOptions()
      XCTAssertEqual(signature.outputColorSpaceName, "DisplayP3_PQ")
    }
  #endif

  func testWritesEightBitHEIF() throws {
    let outputURL = temporaryDirectory.appendingPathComponent("sdr-8.heic")

    try writeHEIF(
      try makeRequest(outputBitDepth: .eight),
      to: outputURL,
      quality: 0.9,
      verbose: false)

    XCTAssertEqual(try primaryDepth(of: outputURL), 8)
    XCTAssertNil(try gainMapDescription(of: outputURL))
  }

  func testWritesTenBitHEIF() throws {
    let outputURL = temporaryDirectory.appendingPathComponent("sdr-10.heic")

    try writeHEIF(
      try makeRequest(outputBitDepth: .ten),
      to: outputURL,
      quality: 0.9,
      verbose: false)

    XCTAssertEqual(try primaryDepth(of: outputURL), 10)
    XCTAssertNil(try gainMapDescription(of: outputURL))
  }

  func testWritesNativeHDRHEIF() throws {
    let outputURL = temporaryDirectory.appendingPathComponent("native-hdr.heic")
    let pq = try XCTUnwrap(CGColorSpace(name: CGColorSpace.itur_2100_PQ))
    let request = HEIFEncodingRequest(
      representation: .hdr(makeHDRImage()),
      outputBitDepth: .ten,
      outputColorSpace: pq)

    try writeHEIF(
      request,
      to: outputURL,
      quality: 0.9,
      verbose: false)

    XCTAssertEqual(try primaryDepth(of: outputURL), 10)
    XCTAssertNil(try gainMapDescription(of: outputURL))
    let properties = try primaryProperties(of: outputURL)
    let profileName = try XCTUnwrap(
      properties[kCGImagePropertyProfileName] as? String)
    XCTAssertTrue(profileName.localizedCaseInsensitiveContains("PQ"))
  }

  func testWritesAdaptiveHDRWithRGBGainMap() throws {
    guard #available(macOS 15.0, *) else {
      throw XCTSkip("Adaptive HDR encoding requires macOS 15 or later")
    }
    let outputURL = temporaryDirectory.appendingPathComponent("hdr.heic")

    try writeHEIF(
      try makeRequest(
        outputBitDepth: .ten,
        hdrImage: makeHDRImage()),
      to: outputURL,
      quality: 0.9,
      verbose: false)

    XCTAssertEqual(try primaryDepth(of: outputURL), 10)
    let gainMap = try XCTUnwrap(gainMapDescription(of: outputURL))
    XCTAssertEqual(gainMap.width, 64)
    XCTAssertEqual(gainMap.height, 48)
    XCTAssertEqual(gainMap.pixelFormat, fourCC("420f"))
  }

  func testWritesEightBitAdaptiveHDR() throws {
    guard #available(macOS 15.0, *) else {
      throw XCTSkip("Adaptive HDR encoding requires macOS 15 or later")
    }
    let outputURL = temporaryDirectory.appendingPathComponent("hdr-8.heic")

    try writeHEIF(
      try makeRequest(
        outputBitDepth: .eight,
        hdrImage: makeHDRImage()),
      to: outputURL,
      quality: 0.9,
      verbose: false)

    XCTAssertEqual(try primaryDepth(of: outputURL), 8)
    XCTAssertNotNil(try gainMapDescription(of: outputURL))
  }

  func testRejectsMismatchedAdaptiveHDRGeometry() throws {
    guard #available(macOS 15.0, *) else {
      throw XCTSkip("Adaptive HDR encoding requires macOS 15 or later")
    }
    let outputURL = temporaryDirectory.appendingPathComponent("mismatch.heic")
    let sdr = CIImage(color: .red).cropped(
      to: CGRect(x: 0, y: 0, width: 64, height: 48))
    let hdr = CIImage(color: .white).cropped(
      to: CGRect(x: 0, y: 0, width: 32, height: 24))
    let request = HEIFEncodingRequest(
      representation: .adaptiveHDR(
        sdrPrimary: sdr,
        hdrAlternate: hdr),
      outputBitDepth: .ten,
      outputColorSpace: sRGB)

    XCTAssertThrowsError(
      try writeHEIF(
        request,
        to: outputURL,
        quality: 0.9,
        verbose: false))
  }

  func testSizeLimitedAdaptiveHDRPreservesEncodingMode() throws {
    guard #available(macOS 15.0, *) else {
      throw XCTSkip("Adaptive HDR encoding requires macOS 15 or later")
    }
    let outputURL = temporaryDirectory.appendingPathComponent(
      "size-limited-hdr.heic")

    try writeSizeLimitedHEIF(
      try makeRequest(
        outputBitDepth: .ten,
        hdrImage: makeHDRImage()),
      to: outputURL,
      withSizeLimit: 100_000,
      withSizeLimitAccuracy: 0.8,
      withinRange: 0.5...0.9,
      verbose: false)

    XCTAssertEqual(try primaryDepth(of: outputURL), 10)
    XCTAssertNotNil(try gainMapDescription(of: outputURL))
  }

  func testFailedEncodePreservesExistingDestination() throws {
    let outputURL = temporaryDirectory.appendingPathComponent("existing.heic")
    let originalData = Data("existing file".utf8)
    try originalData.write(to: outputURL)
    let request = HEIFEncodingRequest(
      representation: .sdr(CIImage.empty()),
      outputBitDepth: .eight,
      outputColorSpace: sRGB)

    XCTAssertThrowsError(
      try writeHEIF(
        request,
        to: outputURL,
        quality: 0.9,
        verbose: false))
    XCTAssertEqual(try Data(contentsOf: outputURL), originalData)
  }

  private func makeSixteenBitSDRImage() throws -> CIImage {
    let bounds = CGRect(x: 0, y: 0, width: 64, height: 48)
    let image = CIImage(
      color: CIColor(
        red: 0.25,
        green: 0.5,
        blue: 0.75,
        colorSpace: sRGB)!
    ).cropped(to: bounds)
    let sourceURL = temporaryDirectory.appendingPathComponent(
      "source-\(UUID().uuidString).tif")
    try context.writeTIFFRepresentation(
      of: image,
      to: sourceURL,
      format: .RGBA16,
      colorSpace: sRGB,
      options: [:])
    let source = try XCTUnwrap(CIImage(contentsOf: sourceURL))
    XCTAssertEqual(source.properties["Depth"] as? Int, 16)
    return source
  }

  private func makeHDRImage() -> CIImage {
    let linearSRGB = CGColorSpace(
      name: CGColorSpace.extendedLinearSRGB)!
    let bounds = CGRect(x: 0, y: 0, width: 64, height: 48)
    return CIImage(
      color: CIColor(
        red: 4,
        green: 2,
        blue: 1,
        colorSpace: linearSRGB)!
    ).cropped(to: bounds)
  }

  private func makeRequest(
    outputBitDepth: HEIFBitDepth,
    hdrImage: CIImage? = nil
  ) throws -> HEIFEncodingRequest {
    let sdrImage = try makeSixteenBitSDRImage()
    let representation: HEIFRepresentation
    if let hdrImage {
      representation = .adaptiveHDR(
        sdrPrimary: sdrImage,
        hdrAlternate: hdrImage)
    } else {
      representation = .sdr(sdrImage)
    }
    return HEIFEncodingRequest(
      representation: representation,
      outputBitDepth: outputBitDepth,
      outputColorSpace: sRGB)
  }

  private func primaryDepth(of url: URL) throws -> Int {
    let properties = try primaryProperties(of: url)
    return try XCTUnwrap(properties[kCGImagePropertyDepth] as? Int)
  }

  private func primaryProperties(of url: URL) throws -> [CFString: Any] {
    let source = try imageSource(for: url)
    return try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        as? [CFString: Any])
  }

  private func gainMapDescription(
    of url: URL
  ) throws -> (width: Int, height: Int, pixelFormat: UInt32)? {
    guard #available(macOS 15.0, *) else {
      return nil
    }
    let source = try imageSource(for: url)
    guard
      let auxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        source,
        0,
        kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any]
    else {
      return nil
    }
    let description = try XCTUnwrap(
      auxiliary[kCGImageAuxiliaryDataInfoDataDescription]
        as? [CFString: Any])
    return (
      width: try XCTUnwrap(description["Width" as CFString] as? Int),
      height: try XCTUnwrap(description["Height" as CFString] as? Int),
      pixelFormat: try XCTUnwrap(
        (description["PixelFormat" as CFString] as? NSNumber)?.uint32Value)
    )
  }

  private func imageSource(for url: URL) throws -> CGImageSource {
    return try XCTUnwrap(
      CGImageSourceCreateWithURL(url as CFURL, nil),
      "Could not open image at \(url.path)")
  }

  private func fourCC(_ text: String) -> UInt32 {
    return text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
  }
}
