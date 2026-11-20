// swift-tools-version:5.10
// TRecShare – a screen recorder for macOS.
// Build the app with ./scripts/build-app.sh; run tests with `swift test`.
import PackageDescription

let package = Package(
    name: "TRecShare",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "TRecShare",
            path: "Sources/TRecShare"
        ),
        .testTarget(
            name: "TRecShareTests",
            dependencies: ["TRecShare"],
            path: "Tests/TRecShareTests"
        ),
    ]
)
