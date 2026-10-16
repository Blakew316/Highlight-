// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Highlight",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Highlight", path: "Sources/Highlight"),
        .testTarget(name: "HighlightTests", dependencies: ["Highlight"], path: "Tests/HighlightTests"),
    ]
)
