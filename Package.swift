// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "raft-server-swift",
    products: [
        .library(name: "RaftConnectAuth", targets: ["RaftConnectAuth"]),
        .library(name: "RaftShared", targets: ["RaftShared"]),
        .library(name: "RaftDaemonClient", targets: ["RaftDaemonClient"]),
        .library(name: "RaftHTTP", targets: ["RaftHTTP"]),
        .library(name: "RaftHTTPServer", targets: ["RaftHTTPServer"]),
        .executable(name: "RaftServer", targets: ["RaftServer"]),
        .executable(name: "RaftDaemon", targets: ["RaftDaemon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", revision: "1025d0a10ea9f5dd110f13e9b62aa42dc4358841"),
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
                .product(name: "Crypto", package: "swift-crypto"),
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
            name: "RaftShared"
        ),
        .target(
            name: "RaftHTTP",
            dependencies: [
                "RaftShared",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
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
        .target(
            name: "TestSupport",
            dependencies: ["RaftHTTP", "RaftShared"],
            path: "Tests/TestSupport"
        ),
        .testTarget(
            name: "RaftHTTPTests",
            dependencies: ["RaftHTTP", "RaftShared", "TestSupport"]
        ),
        .testTarget(
            name: "RaftHTTPServerTests",
            dependencies: [
                "RaftHTTP",
                "RaftHTTPServer",
                "RaftRealtime",
                "TestSupport",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
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
                "TestSupport",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
    ]
)
