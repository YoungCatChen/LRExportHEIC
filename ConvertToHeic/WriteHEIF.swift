import CoreImage
import ImageIO

func writeHEIF(
  of image: CIImage,
  to url: URL,
  in colorSpace: CGColorSpace,
  withQuality quality: Double,
  shouldUseHEIF10: Bool,
  hdrImage: CIImage?,
  verbose: Bool
) throws {
  var opts =
    [
      kCGImageDestinationLossyCompressionQuality: quality
    ] as [CIImageRepresentationOption: Any]
  let ctx = CIContext()
  let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
    ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
  defer {
    try? FileManager.default.removeItem(at: temporaryURL)
  }

  if verbose {
    print("Output URL: \(url)")
    print("Output Quality: \(quality)")
    print("Output Colorspace: \(colorSpace)")
    print("Output Bitdepth: \(hdrImage != nil || shouldUseHEIF10 ? 10 : 8)")
    print("Output HDR: \(hdrImage != nil)")
  }

  if let hdrImage = hdrImage {
    guard #available(macOS 15.0, *) else {
      throw ExportHEICError.hdrOutputRequiresMacOS15
    }

    opts[.hdrImage] = hdrImage
    opts[.hdrGainMapAsRGB] = true
    opts[kCGImageDestinationEncodeRequest as CIImageRepresentationOption] =
      kCGImageDestinationEncodeToISOGainmap

    try ctx.writeHEIF10Representation(
      of: image,
      to: temporaryURL,
      colorSpace: colorSpace,
      options: opts
    )
  } else if shouldUseHEIF10 {
    try ctx.writeHEIF10Representation(
      of: image,
      to: temporaryURL,
      colorSpace: colorSpace,
      options: opts
    )
  } else {
    try ctx.writeHEIFRepresentation(
      of: image,
      to: temporaryURL,
      format: .RGBA8,
      colorSpace: colorSpace,
      options: opts
    )
  }

  try replaceItem(at: url, withItemAt: temporaryURL)
}

func replaceItem(at destinationURL: URL, withItemAt sourceURL: URL) throws {
  let fileManager = FileManager.default
  if fileManager.fileExists(atPath: destinationURL.path) {
    _ = try fileManager.replaceItemAt(destinationURL, withItemAt: sourceURL)
  } else {
    try fileManager.moveItem(at: sourceURL, to: destinationURL)
  }
}
