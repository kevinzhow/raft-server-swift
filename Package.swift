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
        .executable(name: "RaftInfrastructureCheck", targets: ["RaftInfrastructureCheck"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/RediStack.git", exact: "1.6.3"),
        .package(url: "https://github.com/vapor/jwt-kit.git", exact: "5.8.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.8.0"),
        .package(url: "https://github.com/vapor/multipart-kit.git", exact: "5.0.0-beta.2"),
        .package(url: "https://github.com/soto-project/soto.git", exact: "7.17.0"),
        .package(url: "https://github.com/soto-project/soto-core.git", exact: "7.17.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.30.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5"),
        .package(url: "https://github.com/vapor/postgres-nio.git", revision: "1025d0a10ea9f5dd110f13e9b62aa42dc4358841"),
        // No tagged Vapor 5 release builds here. This main snapshot pins swift-collections to 1.6.0.
        .package(url: "https://github.com/vapor/vapor.git", revision: "0f2a8ee9f38b2589c066b604de3e3168ed54c82d"),
    ],
    targets: [
        .executableTarget(
            name: "RaftInfrastructureCheck",
            dependencies: ["RaftPersistence", "RaftRedis"],
            path: "Tests/InfrastructureCheck"
        ),
        .target(
            name: "RaftPersistence",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .target(
            name: "RaftRedis",
            dependencies: [
                .product(name: "RediStack", package: "RediStack"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
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
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .target(
            name: "RaftDaemonClient",
            dependencies: [
                "RaftConnectAuth",
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "RaftRealtime",
            dependencies: [
                "RaftConnectAuth",
                "RaftShared",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .target(
            name: "RaftShared"
        ),
        .target(
            name: "CArgon2",
            exclude: ["LICENSE", "PROVENANCE.json"],
            sources: [
                "src/argon2.c", "src/core.c", "src/encoding.c", "src/ref.c",
                "src/thread.c", "src/blake2/blake2b.c",
            ],
            publicHeadersPath: "include",
            cSettings: [.define("ARGON2_NO_THREADS")]
        ),
        .target(
            name: "CRaftMarkdown",
            exclude: ["vendor/LICENSE.md", "vendor/PROVENANCE.json", "vendor/README.md", "vendor/UPSTREAM.patch"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "RaftObjectStorage",
            dependencies: [
                .product(name: "SotoS3", package: "soto"),
                .product(name: "SotoCore", package: "soto-core"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "RaftObjectStorageTests",
            dependencies: [
                "RaftObjectStorage",
                .product(name: "SotoTestUtils", package: "soto-core"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .target(
            name: "RaftHTTP",
            dependencies: [
                "RaftShared",
                "RaftObjectStorage",
                "CArgon2",
                "CRaftMarkdown",
                .product(name: "JWTKit", package: "jwt-kit"),
                "RaftPersistence",
                "RaftRedis",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ],
            resources: [
                .copy("Resources/owner-opener-team-mode.html"),
                .copy("Resources/MD4C.LICENSE.txt"),
            ]
        ),
        .target(
            name: "RaftHTTPServer",
            dependencies: [
                .product(name: "MultipartKit", package: "multipart-kit"),
                "RaftHTTP",
                "RaftRealtime",
                .product(name: "Vapor", package: "vapor"),
            ]
        ),
        .executableTarget(
            name: "RaftServer",
            dependencies: [
                "RaftHTTP",
                "RaftObjectStorage",
                "RaftShared",
                "RaftPersistence",
                "RaftRedis",
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
            dependencies: ["RaftHTTP", "RaftShared", .product(name: "JWTKit", package: "jwt-kit")],
            path: "Tests/TestSupport"
        ),
        .testTarget(
            name: "RaftHTTPTests",
            dependencies: [
                "RaftHTTP", "RaftObjectStorage", "RaftShared", "TestSupport",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "RaftHTTPServerTests",
            dependencies: [
                "RaftHTTP",
                "RaftHTTPServer",
                "RaftRealtime",
                "RaftObjectStorage",
                "TestSupport",
                .product(name: "SotoTestUtils", package: "soto-core"),
                .product(name: "JWTKit", package: "jwt-kit"),
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
            dependencies: [
                "RaftMachineSocket", "RaftConnectAuth",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
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
                "RaftServer", "RaftHTTP", "RaftMachineSocket", "RaftConnectAuth", "RaftPersistence",
                "RaftRealtime", "RaftHTTPServer", "RaftShared", "TestSupport", "RaftObjectStorage",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
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
