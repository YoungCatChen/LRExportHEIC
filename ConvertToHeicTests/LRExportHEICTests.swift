import CoreImage
import Foundation
import ImageIO
import XCTest

#if SWIFT_PACKAGE
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

  func testWritesEightBitHEIF() throws {
    let outputURL = temporaryDirectory.appendingPathComponent("sdr-8.heic")

    try writeHEIF(
      makeRequest(outputBitDepth: .eight),
      to: outputURL,
      quality: 0.9,
      verbose: false)

    XCTAssertEqual(try primaryDepth(of: outputURL), 8)
    XCTAssertNil(try gainMapDescription(of: outputURL))
  }

  func testWritesTenBitHEIF() throws {
    let outputURL = temporaryDirectory.appendingPathComponent("sdr-10.heic")

    try writeHEIF(
      makeRequest(outputBitDepth: .ten),
      to: outputURL,
      quality: 0.9,
      verbose: false)

    XCTAssertEqual(try primaryDepth(of: outputURL), 10)
    XCTAssertNil(try gainMapDescription(of: outputURL))
  }

  func testWritesAdaptiveHDRWithRGBGainMap() throws {
    guard #available(macOS 15.0, *) else {
      throw XCTSkip("Adaptive HDR encoding requires macOS 15 or later")
    }
    let outputURL = temporaryDirectory.appendingPathComponent("hdr.heic")

    try writeHEIF(
      makeRequest(
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

  func testWritesEightBitAdaptiveHDRWithMonochromeGainMap() throws {
    guard #available(macOS 15.0, *) else {
      throw XCTSkip("Adaptive HDR encoding requires macOS 15 or later")
    }
    let outputURL = temporaryDirectory.appendingPathComponent(
      "hdr-8-mono.heic")

    try writeHEIF(
      makeRequest(
        outputBitDepth: .eight,
        hdrImage: makeHDRImage(),
        gainMapChannels: .monochrome),
      to: outputURL,
      quality: 0.9,
      verbose: false)

    XCTAssertEqual(try primaryDepth(of: outputURL), 8)
    let gainMap = try XCTUnwrap(gainMapDescription(of: outputURL))
    XCTAssertEqual(gainMap.width, 64)
    XCTAssertEqual(gainMap.height, 48)
    XCTAssertEqual(gainMap.pixelFormat, fourCC("L008"))
  }

  func testSizeLimitedAdaptiveHDRPreservesEncodingMode() throws {
    guard #available(macOS 15.0, *) else {
      throw XCTSkip("Adaptive HDR encoding requires macOS 15 or later")
    }
    let outputURL = temporaryDirectory.appendingPathComponent(
      "size-limited-hdr.heic")

    try writeSizeLimitedHEIF(
      makeRequest(
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

    XCTAssertThrowsError(
      try writeHEIF(
        HEIFEncodingRequest(
          primary: PrimaryRendition(
            image: CIImage.empty(),
            outputBitDepth: .eight,
            outputColorSpace: sRGB),
          dynamicRange: .sdr),
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
    hdrImage: CIImage? = nil,
    gainMapChannels: GainMapChannels = .rgb
  ) throws -> HEIFEncodingRequest {
    let dynamicRange: DynamicRangeRepresentation
    if let hdrImage {
      dynamicRange = .adaptiveHDR(
        alternate: HDRRendition(image: hdrImage),
        gainMap: GainMapOptions(channels: gainMapChannels))
    } else {
      dynamicRange = .sdr
    }
    return HEIFEncodingRequest(
      primary: PrimaryRendition(
        image: try makeSixteenBitSDRImage(),
        outputBitDepth: outputBitDepth,
        outputColorSpace: sRGB),
      dynamicRange: dynamicRange)
  }

  private func primaryDepth(of url: URL) throws -> Int {
    let source = try imageSource(for: url)
    let properties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        as? [CFString: Any])
    return try XCTUnwrap(properties[kCGImagePropertyDepth] as? Int)
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
