// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "mic_recorder",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        // The product name must be the plugin's pub name with underscores
        // replaced by hyphens: the Flutter tooling links the plugin into the
        // generated registrant package by that sanitized name, so with the
        // underscore spelling SwiftPM resolution fails with
        // "product 'mic-recorder' ... not found in package 'mic_recorder'".
        // The target (module) name stays "mic_recorder" — that is what the
        // generated registrant imports.
        .library(name: "mic-recorder", targets: ["mic_recorder"])
    ],
    dependencies: [
        // Vendored by the Flutter tooling next to the copied plugin when the
        // host app builds; declaring it explicitly (instead of letting the
        // tool inject it) matches the `flutter create --template=plugin`
        // manifest and keeps example builds free of the
        // "missing a dependency on FlutterFramework" tooling warning.
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "mic_recorder",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                // Swift Package Manager counterpart of the podspec's
                // mic_recorder_privacy resource bundle: bundles the privacy
                // manifest with the plugin when it is integrated via SPM.
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
