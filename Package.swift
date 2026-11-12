// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Maccar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MaccarKit", targets: ["MaccarKit"]),
        .executable(name: "maccar", targets: ["MaccarApp"])
    ],
    targets: [
        .target(
            name: "CMaccarBridge",
            dependencies: [],
            publicHeadersPath: "include"
        ),
        .target(
            name: "MaccarKit",
            dependencies: ["CMaccarBridge"]
        ),
        .executableTarget(
            name: "MaccarApp",
            dependencies: ["MaccarKit"]
        ),
        .testTarget(
            name: "MaccarKitTests",
            dependencies: ["MaccarKit"]
        )
    ]
)
