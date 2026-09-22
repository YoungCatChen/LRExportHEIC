// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "LRExportHEIC",
  platforms: [.macOS(.v12)],
  products: [
    .executable(name: "ConvertToHeic", targets: ["ConvertToHeic"]),
    .executable(name: "hdr-image-tool", targets: ["HDRImageTool"]),
  ],
  dependencies: [
    .package(url: "https://github.com/vapor/console-kit.git", from: "4.2.7")
  ],
  targets: [
    .executableTarget(
      name: "ConvertToHeic",
      dependencies: [
        "HEIFEncoding",
        .product(name: "ConsoleKit", package: "console-kit"),
      ],
      path: "ConvertToHeic"
    ),
    .executableTarget(
      name: "HDRImageTool",
      dependencies: ["HEIFEncoding"],
      path: "Tools/HDRImageTool"
    ),
    .target(
      name: "HEIFEncoding",
      path: "HEIFEncoding"
    ),
    .testTarget(
      name: "ConvertToHeicTests",
      dependencies: ["ConvertToHeic", "HEIFEncoding"],
      path: "ConvertToHeicTests"
    ),
  ]
)
