// swift-tools-version: 6.4
import Foundation
import PackageDescription

let source =
    ProcessInfo.processInfo.environment["CONTINUUMKIT_BENCHMARK_SOURCE"]
    ?? "https://github.com/emmettl/ContinuumKit.git"
let package = Package(
    name: "BombCADSharedAdiabatic", platforms: [.macOS(.v15)],
    dependencies: [.package(url: source, exact: "0.1.0-alpha.14")],
    targets: [
        .executableTarget(
            name: "AdiabaticAdapter",
            dependencies: [
                .product(name: "BenchmarkSupport", package: "continuumkit"),
                .product(name: "CompressibleFlow", package: "continuumkit"),
            ])
    ], swiftLanguageModes: [.v6])
