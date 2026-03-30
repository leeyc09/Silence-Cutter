// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SilenceCutterApp",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "SilenceCutterApp",
            path: "Sources",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
