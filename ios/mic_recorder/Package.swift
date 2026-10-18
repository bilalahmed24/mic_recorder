// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "mic_recorder",
    platforms: [.iOS(.v15)],
    products: [
        // This is the product that will be used by the host application.
        .library(name: "mic_recorder", targets: ["mic_recorder"]),
    ],
    targets: [
        .target(
            name: "mic_recorder",
            path: "Sources/mic_recorder"
        )
    ]
)
