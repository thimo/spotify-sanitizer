// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpotifySanitizer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpotifySanitizer", targets: ["SpotifySanitizer"]),
        .executable(name: "sanitizer-verify", targets: ["sanitizer-verify"])
    ],
    targets: [
        // The engine: auth, API client, library, analyzer. No UI.
        .target(name: "SanitizerKit"),
        // The SwiftUI app — a thin front-end over SanitizerKit.
        .executableTarget(
            name: "SpotifySanitizer",
            dependencies: ["SanitizerKit"]
        ),
        // Headless runner: --selftest runs the analyzer self-tests, otherwise a
        // live scan to verify the engine against the API. (XCTest needs full
        // Xcode, absent here, so tests live inside the Kit instead.)
        .executableTarget(
            name: "sanitizer-verify",
            dependencies: ["SanitizerKit"]
        )
    ]
)
