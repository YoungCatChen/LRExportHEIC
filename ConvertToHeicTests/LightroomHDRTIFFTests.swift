import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest

#if SWIFT_PACKAGE
  @testable import ConvertToHeic
  import HEIFEncoding
#endif

final class LightroomHDRTIFFTests: XCTestCase {
  func testReadsPrivateGainMapSubIFD() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).tif")
    defer { try? FileManager.default.removeItem(at: url) }
    try makeFixture().write(to: url)

    let gainMap = try LightroomHDRTIFF.readGainMap(from: url)

    XCTAssertEqual(gainMap.image.extent.width, 2)
    XCTAssertEqual(gainMap.image.extent.height, 1)
    let baseHeadroom = try XCTUnwrap(
      CGImageMetadataCopyTagWithPath(
        gainMap.metadata,
        nil,
        "HDRToneMap:BaseHeadroom" as CFString))
    XCTAssertEqual(
      CGImageMetadataTagCopyValue(baseHeadroom) as? String,
      "0.000000000000")
  }

  func testEncodesParsedGainMap() throws {
    guard #available(macOS 15.0, *) else {
      throw XCTSkip("ISO gain-map encoding requires macOS 15 or later")
    }
    let inputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).tif")
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).heic")
    defer {
      try? FileManager.default.removeItem(at: inputURL)
      try? FileManager.default.removeItem(at: outputURL)
    }
    try makeFixture().write(to: inputURL)
    let gainMap = try LightroomHDRTIFF.readGainMap(from: inputURL)
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let primary = CIImage(
      color: try XCTUnwrap(
        CIColor(
          red: 0.25,
          green: 0.5,
          blue: 0.75,
          colorSpace: colorSpace))
    ).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 1))

    try writeHEIF(
      HEIFEncodingRequest(
        primary: PrimaryRendition(
          image: primary,
          outputBitDepth: .ten,
          outputColorSpace: colorSpace),
        dynamicRange: .gainMapped(
          gainMap: gainMap,
          options: GainMapOptions(channels: .rgb))),
      to: outputURL,
      quality: 0.9,
      verbose: false)

    let source = try XCTUnwrap(
      CGImageSourceCreateWithURL(outputURL as CFURL, nil))
    let auxiliary = try XCTUnwrap(
      CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        source,
        0,
        kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any])
    let description = try XCTUnwrap(
      auxiliary[kCGImageAuxiliaryDataInfoDataDescription]
        as? [CFString: Any])
    XCTAssertEqual(description[kCGImagePropertyWidth] as? Int, 2)
    XCTAssertEqual(description[kCGImagePropertyHeight] as? Int, 1)
  }

  private func makeFixture() -> Data {
    let firstIFDOffset: UInt32 = 8
    let firstIFDSize: UInt32 = 2 + 12 + 4
    let gainIFDOffset = firstIFDOffset + firstIFDSize
    let gainEntryCount: UInt16 = 11
    let gainIFDSize = UInt32(2 + Int(gainEntryCount) * 12 + 4)
    let bitsOffset = gainIFDOffset + gainIFDSize
    let metadataOffset = bitsOffset + 6
    let metadata = makeMetadata()
    let pixelsOffset = metadataOffset + UInt32(metadata.count)

    var data = Data()
    data.append(contentsOf: [0x49, 0x49])
    appendUInt16(42, to: &data)
    appendUInt32(firstIFDOffset, to: &data)

    appendUInt16(1, to: &data)
    appendEntry(tag: 330, type: 4, count: 1, value: gainIFDOffset, to: &data)
    appendUInt32(0, to: &data)

    appendUInt16(gainEntryCount, to: &data)
    appendEntry(tag: 256, type: 4, count: 1, value: 2, to: &data)
    appendEntry(tag: 257, type: 4, count: 1, value: 1, to: &data)
    appendEntry(tag: 258, type: 3, count: 3, value: bitsOffset, to: &data)
    appendEntry(tag: 259, type: 3, count: 1, value: 1, to: &data)
    appendEntry(tag: 262, type: 3, count: 1, value: 52553, to: &data)
    appendEntry(tag: 273, type: 4, count: 1, value: pixelsOffset, to: &data)
    appendEntry(tag: 277, type: 3, count: 1, value: 3, to: &data)
    appendEntry(tag: 278, type: 4, count: 1, value: 1, to: &data)
    appendEntry(tag: 279, type: 4, count: 1, value: 12, to: &data)
    appendEntry(tag: 284, type: 3, count: 1, value: 1, to: &data)
    appendEntry(
      tag: 52557,
      type: 7,
      count: UInt32(metadata.count),
      value: metadataOffset,
      to: &data)
    appendUInt32(0, to: &data)

    appendUInt16(16, to: &data)
    appendUInt16(16, to: &data)
    appendUInt16(16, to: &data)
    data.append(metadata)
    for sample: UInt16 in [0, 32768, 65535, 65535, 32768, 0] {
      appendUInt16(sample, to: &data)
    }
    return data
  }

  private func makeMetadata() -> Data {
    var data = Data(repeating: 0, count: 8)
    data.append(0xc0)
    appendFraction(0, 1, to: &data)
    appendFraction(2, 1, to: &data)
    for _ in 0..<3 {
      appendFraction(0, 1, to: &data)
      appendFraction(2, 1, to: &data)
      appendFraction(1, 1, to: &data)
      appendFraction(1, 64, to: &data)
      appendFraction(1, 64, to: &data)
    }
    XCTAssertEqual(data.count, 145)
    return data
  }

  private func appendEntry(
    tag: UInt16,
    type: UInt16,
    count: UInt32,
    value: UInt32,
    to data: inout Data
  ) {
    appendUInt16(tag, to: &data)
    appendUInt16(type, to: &data)
    appendUInt32(count, to: &data)
    appendUInt32(value, to: &data)
  }

  private func appendFraction(
    _ numerator: Int32,
    _ denominator: UInt32,
    to data: inout Data
  ) {
    appendUInt32(UInt32(bitPattern: numerator), to: &data)
    appendUInt32(denominator, to: &data)
  }

  private func appendUInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8(value >> 8))
  }

  private func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8(value >> 24))
  }
}
