import CoreGraphics
import CoreImage
import Foundation
import ImageIO

#if SWIFT_PACKAGE
  import HEIFEncoding
#endif

enum LightroomHDRTIFFError: Error, CustomStringConvertible {
  case invalid(String)

  var description: String {
    switch self {
    case .invalid(let message):
      return "Unsupported Lightroom HDR TIFF: \(message)"
    }
  }
}

enum LightroomHDRTIFF {
  static func readGainMap(from url: URL) throws -> ISOGainMap {
    let tiff = try TIFFDocument(data: Data(contentsOf: url))
    let gainMapIFDOffset = try tiff.firstSubIFDOffset()
    let metadataData = try tiff.data(
      forTag: 52557,
      inIFDAt: gainMapIFDOffset)
    let metadata = try makeAppleGainMapMetadata(
      fromLightroomTag: metadataData)
    let gainMapData = try tiff.dataByPromotingGainMapIFD(
      at: gainMapIFDOffset)
    guard
      let gainMap = CIImage(
        data: gainMapData,
        options: [
          .applyOrientationProperty: true,
          .colorSpace: NSNull(),
        ]),
      let gainMapColorSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
    else {
      throw LightroomHDRTIFFError.invalid(
        "ImageIO could not decode the gain-map SubIFD")
    }
    return ISOGainMap(
      image: gainMap,
      metadata: metadata,
      colorSpace: gainMapColorSpace)
  }
}

private struct TIFFEntry {
  let type: UInt16
  let count: UInt32
  let valueOrOffset: UInt32
  let valueFieldOffset: Int
}

private struct TIFFDocument {
  private enum ByteOrder {
    case littleEndian
    case bigEndian
  }

  private let data: Data
  private let byteOrder: ByteOrder
  private var firstIFDOffset = 0

  init(data: Data) throws {
    guard data.count >= 8 else {
      throw LightroomHDRTIFFError.invalid("truncated TIFF header")
    }
    switch (data[0], data[1]) {
    case (0x49, 0x49):
      byteOrder = .littleEndian
    case (0x4d, 0x4d):
      byteOrder = .bigEndian
    default:
      throw LightroomHDRTIFFError.invalid("unknown byte order")
    }
    self.data = data
    guard try readUInt16(at: 2) == 42 else {
      throw LightroomHDRTIFFError.invalid("BigTIFF is not supported")
    }
    firstIFDOffset = Int(try readUInt32(at: 4))
    _ = try entries(inIFDAt: firstIFDOffset)
  }

  func firstSubIFDOffset() throws -> Int {
    let entry = try requiredEntry(tag: 330, inIFDAt: firstIFDOffset)
    guard let value = try unsignedValues(for: entry).first else {
      throw LightroomHDRTIFFError.invalid("empty SubIFDs tag")
    }
    let offset = Int(value)
    _ = try entries(inIFDAt: offset)
    return offset
  }

  func data(forTag tag: UInt16, inIFDAt offset: Int) throws -> Data {
    return try fieldData(for: requiredEntry(tag: tag, inIFDAt: offset))
  }

  func dataByPromotingGainMapIFD(at offset: Int) throws -> Data {
    let entries = try entries(inIFDAt: offset)
    guard let photometric = entries[262] else {
      throw LightroomHDRTIFFError.invalid(
        "gain-map SubIFD has no photometric interpretation")
    }
    guard photometric.type == 3, photometric.count == 1 else {
      throw LightroomHDRTIFFError.invalid(
        "unexpected gain-map photometric tag type")
    }
    guard try unsignedValues(for: photometric).first == 52553 else {
      throw LightroomHDRTIFFError.invalid(
        "gain-map photometric interpretation is not 52553")
    }

    var result = data
    writeUInt32(UInt32(offset), at: 4, in: &result)
    writeUInt16(2, at: photometric.valueFieldOffset, in: &result)
    return result
  }

  private func entries(inIFDAt offset: Int) throws -> [UInt16: TIFFEntry] {
    let count = Int(try readUInt16(at: offset))
    let byteCount = try checkedMultiply(count, 12)
    try requireRange(offset + 2, count: byteCount + 4)
    var result: [UInt16: TIFFEntry] = [:]
    for index in 0..<count {
      let entryOffset = offset + 2 + index * 12
      let tag = try readUInt16(at: entryOffset)
      result[tag] = TIFFEntry(
        type: try readUInt16(at: entryOffset + 2),
        count: try readUInt32(at: entryOffset + 4),
        valueOrOffset: try readUInt32(at: entryOffset + 8),
        valueFieldOffset: entryOffset + 8)
    }
    return result
  }

  private func requiredEntry(
    tag: UInt16,
    inIFDAt offset: Int
  ) throws -> TIFFEntry {
    guard let entry = try entries(inIFDAt: offset)[tag] else {
      throw LightroomHDRTIFFError.invalid("missing TIFF tag \(tag)")
    }
    return entry
  }

  private func fieldData(for entry: TIFFEntry) throws -> Data {
    let typeSize: Int
    switch entry.type {
    case 1, 2, 6, 7:
      typeSize = 1
    case 3, 8:
      typeSize = 2
    case 4, 9, 11, 13:
      typeSize = 4
    case 5, 10, 12:
      typeSize = 8
    default:
      throw LightroomHDRTIFFError.invalid(
        "unsupported TIFF field type \(entry.type)")
    }
    let count = try checkedMultiply(Int(entry.count), typeSize)
    let offset = count <= 4 ? entry.valueFieldOffset : Int(entry.valueOrOffset)
    try requireRange(offset, count: count)
    return data.subdata(in: offset..<(offset + count))
  }

  private func unsignedValues(for entry: TIFFEntry) throws -> [UInt32] {
    let bytes = try fieldData(for: entry)
    switch entry.type {
    case 3:
      return try stride(from: 0, to: bytes.count, by: 2).map {
        try readUInt16(in: bytes, at: $0).asUInt32
      }
    case 4, 13:
      return try stride(from: 0, to: bytes.count, by: 4).map {
        try readUInt32(in: bytes, at: $0)
      }
    default:
      throw LightroomHDRTIFFError.invalid(
        "TIFF tag does not contain integer offsets")
    }
  }

  private func readUInt16(at offset: Int) throws -> UInt16 {
    return try readUInt16(in: data, at: offset)
  }

  private func readUInt16(in source: Data, at offset: Int) throws -> UInt16 {
    try requireRange(offset, count: 2, in: source)
    let first = UInt16(source[offset])
    let second = UInt16(source[offset + 1])
    switch byteOrder {
    case .littleEndian:
      return first | second << 8
    case .bigEndian:
      return first << 8 | second
    }
  }

  private func readUInt32(at offset: Int) throws -> UInt32 {
    return try readUInt32(in: data, at: offset)
  }

  private func readUInt32(in source: Data, at offset: Int) throws -> UInt32 {
    try requireRange(offset, count: 4, in: source)
    switch byteOrder {
    case .littleEndian:
      return UInt32(source[offset])
        | UInt32(source[offset + 1]) << 8
        | UInt32(source[offset + 2]) << 16
        | UInt32(source[offset + 3]) << 24
    case .bigEndian:
      return UInt32(source[offset]) << 24
        | UInt32(source[offset + 1]) << 16
        | UInt32(source[offset + 2]) << 8
        | UInt32(source[offset + 3])
    }
  }

  private func writeUInt16(
    _ value: UInt16,
    at offset: Int,
    in destination: inout Data
  ) {
    switch byteOrder {
    case .littleEndian:
      destination[offset] = UInt8(value & 0xff)
      destination[offset + 1] = UInt8(value >> 8)
    case .bigEndian:
      destination[offset] = UInt8(value >> 8)
      destination[offset + 1] = UInt8(value & 0xff)
    }
  }

  private func writeUInt32(
    _ value: UInt32,
    at offset: Int,
    in destination: inout Data
  ) {
    let shifts: [UInt32]
    switch byteOrder {
    case .littleEndian:
      shifts = [0, 8, 16, 24]
    case .bigEndian:
      shifts = [24, 16, 8, 0]
    }
    for (index, shift) in shifts.enumerated() {
      destination[offset + index] = UInt8((value >> shift) & 0xff)
    }
  }

  private func requireRange(
    _ offset: Int,
    count: Int,
    in source: Data? = nil
  ) throws {
    let source = source ?? data
    guard offset >= 0, count >= 0, offset <= source.count - count else {
      throw LightroomHDRTIFFError.invalid("TIFF offset is out of bounds")
    }
  }

  private func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
    let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflow else {
      throw LightroomHDRTIFFError.invalid("TIFF field size overflow")
    }
    return result
  }
}

private struct Fraction {
  let numerator: Int64
  let denominator: UInt32

  var value: Double {
    Double(numerator) / Double(denominator)
  }
}

private struct ChannelMetadata {
  let minimum: Fraction
  let maximum: Fraction
  let gamma: Fraction
  let baseOffset: Fraction
  let alternateOffset: Fraction
}

private struct GainMapMetadata {
  let useBaseColorSpace: Bool
  let baseHeadroom: Fraction
  let alternateHeadroom: Fraction
  let channels: [ChannelMetadata]
}

private func makeAppleGainMapMetadata(
  fromLightroomTag data: Data
) throws -> CGImageMetadata {
  let values = try parseGainMapMetadata(data)
  let namespace = "http://ns.apple.com/HDRToneMap/1.0/" as CFString
  let prefix = "HDRToneMap" as CFString
  let metadata = CGImageMetadataCreateMutable()
  var error: Unmanaged<CFError>?
  guard
    CGImageMetadataRegisterNamespaceForPrefix(
      metadata,
      namespace,
      prefix,
      &error)
  else {
    throw error?.takeRetainedValue()
      ?? LightroomHDRTIFFError.invalid("could not register metadata namespace")
  }

  func makeTag(_ name: String, _ value: String) throws -> CGImageMetadataTag {
    guard
      let tag = CGImageMetadataTagCreate(
        namespace,
        prefix,
        name as CFString,
        .string,
        value as CFString)
    else {
      throw LightroomHDRTIFFError.invalid(
        "could not create metadata tag \(name)")
    }
    return tag
  }

  func format(_ value: Double) -> String {
    return String(
      format: "%.12f",
      locale: Locale(identifier: "en_US_POSIX"),
      value)
  }

  func set(_ name: String, _ value: String) throws {
    guard
      CGImageMetadataSetTagWithPath(
        metadata,
        nil,
        "HDRToneMap:\(name)" as CFString,
        try makeTag(name, value))
    else {
      throw LightroomHDRTIFFError.invalid(
        "could not set metadata tag \(name)")
    }
  }

  try set("Version", "1")
  try set("BaseHeadroom", format(values.baseHeadroom.value))
  try set("AlternateHeadroom", format(values.alternateHeadroom.value))
  try set(
    "BaseColorIsWorkingColor",
    values.useBaseColorSpace ? "True" : "False")

  let channelTags = try values.channels.enumerated().map { index, channel in
    let fields: [String: CGImageMetadataTag] = [
      "GainMapMin": try makeTag(
        "GainMapMin", format(channel.minimum.value)),
      "GainMapMax": try makeTag(
        "GainMapMax", format(channel.maximum.value)),
      "Gamma": try makeTag("Gamma", format(channel.gamma.value)),
      "BaseOffset": try makeTag(
        "BaseOffset", format(channel.baseOffset.value)),
      "AlternateOffset": try makeTag(
        "AlternateOffset", format(channel.alternateOffset.value)),
    ]
    guard
      let tag = CGImageMetadataTagCreate(
        namespace,
        prefix,
        "[\(index)]" as CFString,
        .structure,
        fields as CFDictionary)
    else {
      throw LightroomHDRTIFFError.invalid(
        "could not create channel metadata")
    }
    return tag
  }
  guard
    let channels = CGImageMetadataTagCreate(
      namespace,
      prefix,
      "ChannelMetadata" as CFString,
      .arrayOrdered,
      channelTags as CFArray),
    CGImageMetadataSetTagWithPath(
      metadata,
      nil,
      "HDRToneMap:ChannelMetadata" as CFString,
      channels)
  else {
    throw LightroomHDRTIFFError.invalid(
      "could not set channel metadata")
  }
  return metadata
}

private func parseGainMapMetadata(_ data: Data) throws -> GainMapMetadata {
  guard data.count >= 9 else {
    throw LightroomHDRTIFFError.invalid("gain-map metadata is too short")
  }
  var offset = 8
  let flags = data[offset]
  offset += 1
  guard flags & 0x3f == 0 else {
    throw LightroomHDRTIFFError.invalid(
      "gain-map metadata has reserved flags")
  }
  let channelCount = flags & 0x80 == 0 ? 1 : 3
  let useBaseColorSpace = flags & 0x40 != 0

  func readBigEndianUInt32() throws -> UInt32 {
    guard offset <= data.count - 4 else {
      throw LightroomHDRTIFFError.invalid(
        "gain-map metadata is truncated")
    }
    defer { offset += 4 }
    return UInt32(data[offset]) << 24
      | UInt32(data[offset + 1]) << 16
      | UInt32(data[offset + 2]) << 8
      | UInt32(data[offset + 3])
  }

  func readFraction(signed: Bool = false) throws -> Fraction {
    let numerator = try readBigEndianUInt32()
    let denominator = try readBigEndianUInt32()
    guard denominator != 0 else {
      throw LightroomHDRTIFFError.invalid(
        "gain-map metadata has a zero denominator")
    }
    return Fraction(
      numerator: signed
        ? Int64(Int32(bitPattern: numerator))
        : Int64(numerator),
      denominator: denominator)
  }

  let baseHeadroom = try readFraction()
  let alternateHeadroom = try readFraction()
  var channels: [ChannelMetadata] = []
  for _ in 0..<channelCount {
    channels.append(
      ChannelMetadata(
        minimum: try readFraction(signed: true),
        maximum: try readFraction(signed: true),
        gamma: try readFraction(),
        baseOffset: try readFraction(signed: true),
        alternateOffset: try readFraction(signed: true)))
  }
  guard offset == data.count else {
    throw LightroomHDRTIFFError.invalid(
      "gain-map metadata has \(data.count - offset) trailing bytes")
  }
  if channelCount == 1 {
    channels = [channels[0], channels[0], channels[0]]
  }
  return GainMapMetadata(
    useBaseColorSpace: useBaseColorSpace,
    baseHeadroom: baseHeadroom,
    alternateHeadroom: alternateHeadroom,
    channels: channels)
}

extension UInt16 {
  fileprivate var asUInt32: UInt32 { UInt32(self) }
}
