// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FileManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FileManagerApp", targets: ["FileManagerApp"]),
        .library(name: "FileCore", targets: ["FileCore"]),
    ],
    targets: [
        // File system logic with no UI dependencies.
        .target(name: "FileCore"),
        // The macOS app (SwiftUI + AppKit).
        .executableTarget(name: "FileManagerApp", dependencies: ["FileCore"]),
        .testTarget(name: "FileCoreTests", dependencies: ["FileCore"]),
        // End-to-end tests: real windows with the app's views on a folder of test files.
        .testTarget(name: "FileManagerAppTests", dependencies: ["FileManagerApp", "FileCore"]),
    ]
)
