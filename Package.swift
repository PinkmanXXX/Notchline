// swift-tools-version: 5.9
import PackageDescription
import Foundation

/// Info.plist is also linked into the executable itself, so an unbundled run
/// (`swift build`, the end-to-end tests, `--snapshot`) is an LSUIElement app
/// from its first instant and never flashes into the Dock.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Resources/Info.plist").path

let package = Package(
    name: "NotchTape",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchTape", path: "Sources/NotchTape",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                                           "-Xlinker", "__info_plist", "-Xlinker", infoPlist])]),
        // `notch`, for scripts; shipped inside the app and put on PATH by the shell hook
        .executableTarget(name: "notch", path: "Sources/notch"),
        .testTarget(name: "NotchTapeTests", dependencies: ["NotchTape"], path: "Tests/NotchTapeTests"),
        // drives the built debug app over its socket: `make e2e`
        .testTarget(name: "NotchTapeE2ETests", path: "Tests/NotchTapeE2ETests")
    ]
)
