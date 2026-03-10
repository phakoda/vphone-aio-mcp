// swift-tools-version:5.10

import PackageDescription

let package = Package(
    name: "vphone-cli",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.1"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.6.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.10.0"),
    ],
    targets: [
        // ObjC module: wraps private Virtualization.framework APIs
        .target(
            name: "VPhoneObjC",
            path: "Sources/VPhoneObjC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
        // Swift executable
        .executableTarget(
            name: "vphone-cli",
            dependencies: [
                "VPhoneObjC",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
            ],
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "vphone-mcp",
            dependencies: [
                "VPhoneObjC",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
            ],
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
