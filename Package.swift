// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CarelessWhisper",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", from: "1.1.0"),
        .package(url: "https://github.com/soffes/HotKey.git", from: "0.2.1"),
    ],
    targets: [
        .executableTarget(
            name: "CarelessWhisper",
            dependencies: [
                "SwiftWhisper",
                "HotKey",
            ],
            path: "Sources/CarelessWhisper",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "CarelessWhisperTests",
            dependencies: ["CarelessWhisper"],
            path: "Tests/CarelessWhisperTests"
        ),
    ]
)
