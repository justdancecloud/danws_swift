// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DanWebSocket",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(
            name: "DanWebSocket",
            targets: ["DanWebSocket"]
        ),
    ],
    targets: [
        .target(
            name: "DanWebSocket",
            path: "Sources/DanWebSocket"
        ),
        .testTarget(
            name: "DanWebSocketTests",
            dependencies: ["DanWebSocket"],
            path: "Tests/DanWebSocketTests"
        ),
    ]
)
