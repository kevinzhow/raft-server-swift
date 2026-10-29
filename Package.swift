// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "raft-server-swift",
    products: [
        .library(name: "RaftConnectAuth", targets: ["RaftConnectAuth"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
    ],
    targets: [
        .target(
            name: "RaftConnectAuth",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "RaftConnectAuthTests",
            dependencies: ["RaftConnectAuth"]
        ),
    ]
)
