// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "raft-server-swift",
    products: [
        .library(name: "RaftConnectAuth", targets: ["RaftConnectAuth"]),
        .library(name: "RaftDaemonClient", targets: ["RaftDaemonClient"]),
        .library(name: "RaftHTTP", targets: ["RaftHTTP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
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
        .target(name: "RaftHTTP"),
        .testTarget(
            name: "RaftHTTPTests",
            dependencies: ["RaftHTTP"]
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
            dependencies: ["RaftDaemonClient", "RaftMachineSocket", "RaftConnectAuth"]
        ),
    ]
)
