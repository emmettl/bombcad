// swift-tools-version: 6.4
import Foundation
import PackageDescription

let environment = ProcessInfo.processInfo.environment
let original = environment["BOMBCAD_QR_VARIANT"] == "original"
let version = original ? "0.1.0-alpha.16" : "0.1.0-alpha.19"
let package = Package(
    name: "ReconstructionCapture", platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/emmettl/ContinuumKit.git", exact: Version(version)!)],
    targets: [
        .executableTarget(
            name: "ReconstructionCapture",
            dependencies: original
                ? [.product(name: "CompressibleFlow", package: "continuumkit")]
                : [
                    .product(name: "CompressibleFlow", package: "continuumkit"),
                    .product(name: "Numerics", package: "continuumkit"),
                ],
            swiftSettings: original ? [.define("ORIGINAL_QR")] : [])
    ], swiftLanguageModes: [.v6])
