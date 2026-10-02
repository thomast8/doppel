// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DoppelMenuBar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5"),
        .package(url: "https://github.com/apple/swift-nio", exact: "2.103.0"),
    ],
    targets: [
        .target(name: "DoppelRemoteCore", dependencies: [
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
        ], path: "RemoteCore"),
        .executableTarget(name: "DoppelRemoteHelper", dependencies: ["DoppelRemoteCore"],
                          path: "RemoteHelper"),
        .executableTarget(
            name: "DoppelMenuBar",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources"),
        // The parsing types live in the executable target, so the tests reach
        // them with @testable rather than the app being split into a library
        // just to be testable.
        .testTarget(name: "DoppelMenuBarTests", dependencies: ["DoppelMenuBar", "DoppelRemoteCore",
            .product(name: "NIOEmbedded", package: "swift-nio")], path: "Tests"),
    ]
)
