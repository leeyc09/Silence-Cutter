// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SilenciApp",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "SilenciApp",
            path: "Sources",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
