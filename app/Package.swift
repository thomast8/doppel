// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DoppelMenuBar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5"),
    ],
    targets: [
        .executableTarget(
            name: "DoppelMenuBar",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources"),
        // The parsing types live in the executable target, so the tests reach
        // them with @testable rather than the app being split into a library
        // just to be testable.
        .testTarget(name: "DoppelMenuBarTests", dependencies: ["DoppelMenuBar"], path: "Tests"),
    ]
)
