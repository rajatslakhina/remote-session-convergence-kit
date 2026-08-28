// swift-tools-version: 6.0
import PackageDescription

// Platforms are deliberately limited to the two that CI actually compiles:
//   * macOS — `swift build` / `swift test` on the macos-15 job
//   * iOS   — `xcodebuild build -destination 'generic/platform=iOS Simulator'`
//             in the companion demo-app repo, which consumes this package remotely.
// Declaring watchOS/tvOS here would be an unverified claim, so they are omitted.
let package = Package(
    name: "RemoteSessionConvergenceKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "RemoteSessionConvergenceKit",
            targets: ["RemoteSessionConvergenceKit"]
        )
    ],
    targets: [
        .target(
            name: "RemoteSessionConvergenceKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RemoteSessionConvergenceKitTests",
            dependencies: ["RemoteSessionConvergenceKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
