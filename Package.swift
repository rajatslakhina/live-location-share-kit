// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveLocationKit",
    // Only the platforms CI actually builds: macOS (swift build + swift test) and iOS (xcodebuild, Simulator SDK).
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LiveLocation", targets: ["LiveLocation"]),
        .library(name: "LiveLocationUI", targets: ["LiveLocationUI"]),
    ],
    targets: [
        .target(name: "LiveLocation"),
        .target(name: "LiveLocationUI", dependencies: ["LiveLocation"]),
        .testTarget(name: "LiveLocationTests", dependencies: ["LiveLocation"]),
    ]
)
