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
  var opts = [kCGImageDestinationLossyCompressionQuality: quality] as [CIImageRepresentationOption: Any]
  let ctx = CIContext()

  try? FileManager.default.removeItem(at: url)

  if verbose {
    print("Output URL: \(url)")
    print("Output Quality: \(quality)")
    print("Output Colorspace: \(colorSpace)")
    print("Output Bitdepth: \(hdrImage == nil && shouldUseHEIF10 ? 10 : 8)")
    print("Output HDR: \(hdrImage != nil)")
  }

  if let hdrImage = hdrImage {
    guard #available(macOS 15.0, *) else {
      throw ExportHEICError.hdrOutputRequiresMacOS15
    }

    opts[.hdrImage] = hdrImage
    opts[kCGImageDestinationEncodeRequest as CIImageRepresentationOption] =
      kCGImageDestinationEncodeToISOHDR

    try ctx.writeHEIFRepresentation(
      of: image,
      to: url,
      format: .RGBA8,
      colorSpace: colorSpace,
      options: opts
    )
  } else if shouldUseHEIF10 {
    try ctx.writeHEIF10Representation(
      of: image,
      to: url,
      colorSpace: colorSpace,
      options: opts
    )
  } else {
    try ctx.writeHEIFRepresentation(
      of: image,
      to: url,
      format: .RGBA8,
      colorSpace: colorSpace,
      options: opts
    )
  }
}
