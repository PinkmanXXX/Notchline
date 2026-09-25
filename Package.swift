// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchTape",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "NotchTape", path: "Sources/NotchTape"),
        // `notch`, for scripts; shipped inside the app and put on PATH by the shell hook
        .executableTarget(name: "notch", path: "Sources/notch"),
        .testTarget(name: "NotchTapeTests", dependencies: ["NotchTape"], path: "Tests/NotchTapeTests"),
        // drives the built debug app over its socket: `make e2e`
        .testTarget(name: "NotchTapeE2ETests", path: "Tests/NotchTapeE2ETests")
    ]
)
