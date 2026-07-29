// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DoppelMenuBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "DoppelMenuBar", path: "Sources")
    ]
)
