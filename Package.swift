// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HLSProxyBuffer",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "HLSProxyBuffer",
            targets: ["ProxyPlayerKit"]
        ),
        .library(
            name: "HLSCore",
            targets: ["HLSCore"]
        ),
        .library(
            name: "LocalProxy",
            targets: ["LocalProxy"]
        ),
    ],
    targets: [
        .target(
            name: "HLSCore"
        ),
        .target(
            name: "LocalProxy",
            dependencies: [
                "HLSCore",
            ]
        ),
        .target(
            name: "ProxyPlayerKit",
            dependencies: [
                "HLSCore",
                "LocalProxy",
            ]
        ),
        .testTarget(
            name: "HLSCoreTests",
            dependencies: ["HLSCore"]
        ),
        .testTarget(
            name: "LocalProxyTests",
            dependencies: [
                "LocalProxy",
                "HLSCore",
            ]
        ),
        .testTarget(
            name: "ProxyPlayerKitTests",
            dependencies: [
                "ProxyPlayerKit",
                "HLSCore",
            ]
        ),
    ]
)
