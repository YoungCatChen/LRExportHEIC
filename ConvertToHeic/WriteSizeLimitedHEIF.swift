import Foundation

#if SWIFT_PACKAGE
  import HEIFEncoding
#endif

func writeSizeLimitedHEIF(
  _ request: HEIFEncodingRequest,
  to destinationURL: URL,
  withSizeLimit size: Int64,
  withSizeLimitAccuracy sizeAccuracy: Double,
  withinRange qualityRange: ClosedRange<Double>,
  verbose: Bool
) throws {
  let temporaryDirectoryURL = URL(
    fileURLWithPath: NSTemporaryDirectory(),
    isDirectory: true)

  // Prefix the temporary filename to avoid conflicts between processes.
  let temporaryBaseName =
    UUID().uuidString + "-"
    + destinationURL.deletingPathExtension().lastPathComponent

  var candidateURLsByQuality = [Double: URL]()
  defer {
    for url in candidateURLsByQuality.values {
      try? FileManager.default.removeItem(at: url)
    }
  }

  func writeTempHEIFAndGetSize(_ quality: Double) -> Int64 {
    let candidateURL = temporaryDirectoryURL.appendingPathComponent(
      "\(temporaryBaseName)-\(quality).heif")
    do {
      try writeHEIF(
        request,
        to: candidateURL,
        quality: quality,
        verbose: verbose)
      candidateURLsByQuality[quality] = candidateURL
      let resources = try candidateURL.resourceValues(forKeys: [.fileSizeKey])
      let fileSize = resources.fileSize!
      if verbose {
        print("Output File Size: \(fileSize)")
      }
      return Int64(fileSize)
    } catch let error {
      fatalError("Cannot write temp HEIF image and get file size: \(error.localizedDescription)")
    }
  }

  // In multiple attempts, generate the images and try to find the fittest quality.
  let quality = qualitySearch(
    byTargetFileSize: size,
    withAccuracy: sizeAccuracy,
    withinRange: qualityRange,
    getFileSizeByQualityFn: writeTempHEIFAndGetSize)

  if verbose {
    print("Chosen Output Quality: \(quality)")
  }

  let chosenURL = candidateURLsByQuality[quality]

  if let chosenURL {
    // We have generated an image with given quality.
    if verbose {
      print("Moving \(chosenURL) to \(destinationURL)")
    }
    // Move the right file from the temp directory to the final directory.
    try replaceItem(at: destinationURL, withItemAt: chosenURL)

  } else {
    // We have NOT generated an image with given quality. (qualitySearch may have returned early.)
    try writeHEIF(
      request,
      to: destinationURL,
      quality: quality,
      verbose: verbose)
  }
}

private func replaceItem(
  at destinationURL: URL,
  withItemAt sourceURL: URL
) throws {
  let fileManager = FileManager.default
  if fileManager.fileExists(atPath: destinationURL.path) {
    _ = try fileManager.replaceItemAt(
      destinationURL,
      withItemAt: sourceURL)
  } else {
    try fileManager.moveItem(at: sourceURL, to: destinationURL)
  }
}
