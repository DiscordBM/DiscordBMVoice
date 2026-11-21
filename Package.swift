// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DiscordBMVoice",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(
            name: "DiscordBMVoice",
            targets: ["DiscordBMVoice"]
        ),
        .library(
            name: "DiscordVoice",
            targets: ["DiscordVoice"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.105.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.1.2"),
        .package(url: "https://github.com/hummingbird-project/swift-websocket.git", from: "1.6.2"),
        .package(url: "https://github.com/DiscordBM/DiscordAudioKit.git", from: "0.2.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.17.2"),
        .package(url: "https://github.com/DiscordBM/DiscordBM.git", from: "1.16.2"),
    ],
    targets: [
        .target(
            name: "DiscordBMVoice",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "WSClient", package: "swift-websocket"),
                .product(name: "DiscordAudioKit", package: "DiscordAudioKit"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/DiscordBMVoice"
        ),
        .target(
            name: "DiscordVoice",
            dependencies: [
                "DiscordBMVoice",
                .product(name: "DiscordGateway", package: "DiscordBM"),
                .product(name: "DiscordModels", package: "DiscordBM"),
                .product(name: "DiscordCore", package: "DiscordBM"),
            ],
            path: "Sources/DiscordVoice"
        ),
        .testTarget(
            name: "DiscordBMVoiceTests",
            dependencies: [
                .target(name: "DiscordBMVoice"),
                .target(name: "DiscordVoice"),
                .product(name: "DiscordGateway", package: "DiscordBM"),
                .product(name: "DiscordModels", package: "DiscordBM"),
                .product(name: "DiscordCore", package: "DiscordBM"),
            ],
            path: "Tests"
        ),
    ]
)
