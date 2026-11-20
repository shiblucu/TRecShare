// swift-tools-version:5.10
// ScrCapKit – a screen recorder for macOS.
// Build the app with ./scripts/build-app.sh; run tests with `swift test`.
import PackageDescription

let package = Package(
    name: "ScrCapKit",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "ScrCapKit",
            path: "Sources/ScrCapKit"
        ),
        .testTarget(
            name: "ScrCapKitTests",
            dependencies: ["ScrCapKit"],
            path: "Tests/ScrCapKitTests"
        ),
    ]
)
