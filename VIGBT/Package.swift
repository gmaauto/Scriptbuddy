// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VIGBT",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VIGBTCore", targets: ["VIGBTCore"])
    ],
    targets: [
        // Pure-Swift, Foundation-only core: no AVFoundation/ARKit/Vision imports,
        // so every algorithm here is unit-testable on macOS, iOS Simulator and Linux.
        .target(name: "VIGBTCore"),
        .testTarget(name: "VIGBTCoreTests", dependencies: ["VIGBTCore"])
    ]
)
