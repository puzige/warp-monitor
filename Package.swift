// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WarpMonitor",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "WarpMonitor", targets: ["WarpMonitor"]),
    ],
    targets: [
        .executableTarget(name: "WarpMonitor"),
    ]
)
