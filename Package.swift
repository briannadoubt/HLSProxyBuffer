// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HLSProxyBuffer",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .macCatalyst(.v17),
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
        .executable(
            name: "HLSProxyFeedDemo",
            targets: ["HLSProxyFeedDemo"]
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
        .executableTarget(
            name: "HLSProxyBenchmarks",
            dependencies: [
                "HLSCore",
                "LocalProxy",
                "ProxyPlayerKit",
            ],
            path: "Benchmarks/HLSProxyBenchmarks"
        ),
        .executableTarget(
            name: "HLSProxyFeedDemo",
            dependencies: [
                "HLSCore",
                "LocalProxy",
                "ProxyPlayerKit",
            ],
            path: "Demo/HLSProxyFeedDemo",
            exclude: ["Tests", "UITests", "project.yml", "HLSProxyFeedDemoApp.xcodeproj"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "HLSCoreTests",
            dependencies: ["HLSCore"],
            resources: [.copy("Fixtures")]
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
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "HLSProxyFeedDemoTests",
            dependencies: [
                "HLSProxyFeedDemo",
                "ProxyPlayerKit",
            ],
            path: "Demo/HLSProxyFeedDemo/Tests"
        ),
    ]
)
