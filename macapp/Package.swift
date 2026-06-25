// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpotifySanitizer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpotifySanitizer", targets: ["SpotifySanitizer"])
    ],
    targets: [
        .executableTarget(
            name: "SpotifySanitizer",
            path: "Sources/SpotifySanitizer"
        )
    ]
)
