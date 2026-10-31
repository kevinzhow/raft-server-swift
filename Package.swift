// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "raft-server-swift",
    products: [
        .library(name: "RaftConnectAuth", targets: ["RaftConnectAuth"]),
        .library(name: "RaftDaemonClient", targets: ["RaftDaemonClient"]),
        .library(name: "RaftHTTP", targets: ["RaftHTTP"]),
        .library(name: "RaftHTTPServer", targets: ["RaftHTTPServer"]),
        .executable(name: "RaftServer", targets: ["RaftServer"]),
        .executable(name: "RaftDaemon", targets: ["RaftDaemon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        // No tagged Vapor 5 release builds here. This main snapshot pins swift-collections to 1.6.0.
        .package(url: "https://github.com/vapor/vapor.git", revision: "0f2a8ee9f38b2589c066b604de3e3168ed54c82d"),
    ],
    targets: [
        .target(
            name: "RaftConnectAuth",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "RaftMachineSocket",
            dependencies: [
                "RaftConnectAuth",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .target(
            name: "RaftDaemonClient",
            dependencies: [
                "RaftConnectAuth",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .target(
            name: "RaftRealtime",
            dependencies: [
                "RaftConnectAuth",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .target(
            name: "RaftHTTP",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "RaftHTTPServer",
            dependencies: [
                "RaftHTTP",
                "RaftRealtime",
                .product(name: "Vapor", package: "vapor"),
            ]
        ),
        .executableTarget(
            name: "RaftServer",
            dependencies: [
                "RaftHTTP",
                "RaftHTTPServer",
                "RaftMachineSocket",
                "RaftConnectAuth",
                "RaftRealtime",
                .product(name: "Vapor", package: "vapor"),
            ]
        ),
        .executableTarget(
            name: "RaftDaemon",
            dependencies: [
                "RaftDaemonClient",
            ]
        ),
        .testTarget(
            name: "RaftHTTPTests",
            dependencies: ["RaftHTTP"]
        ),
        .testTarget(
            name: "RaftHTTPServerTests",
            dependencies: [
                "RaftHTTP",
                "RaftHTTPServer",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "VaporTesting", package: "vapor"),
            ]
        ),
        .testTarget(
            name: "RaftConnectAuthTests",
            dependencies: ["RaftConnectAuth"]
        ),
        .testTarget(
            name: "RaftMachineSocketTests",
            dependencies: ["RaftMachineSocket", "RaftConnectAuth"]
        ),
        .testTarget(
            name: "RaftDaemonClientTests",
            dependencies: [
                "RaftDaemonClient",
                "RaftMachineSocket",
                "RaftConnectAuth",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "RaftServerStartupTests",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "RaftRealtimeTests",
            dependencies: [
                "RaftRealtime",
                "RaftHTTP",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
    ]
)
