// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VirtualMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VirtualMonitor", targets: ["VirtualMonitor"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.22.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/stasel/WebRTC.git", from: "125.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "VirtualMonitor",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            path: "Sources/VirtualMonitor",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
