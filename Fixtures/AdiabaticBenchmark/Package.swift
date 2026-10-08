// swift-tools-version: 6.4
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let revision = try String(contentsOf: root.appendingPathComponent("core-revision.txt"), encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
let source =
    ProcessInfo.processInfo.environment["CONTINUUMKIT_BENCHMARK_SOURCE"]
    ?? "https://github.com/emmettl/ContinuumKit.git"
let package = Package(
    name: "BombCADAdiabatic", platforms: [.macOS(.v15)],
    dependencies: [.package(url: source, revision: revision)],
    targets: [
        .executableTarget(
            name: "AdiabaticAdapter",
            dependencies: [
                .product(name: "BenchmarkSupport", package: "continuumkit")
            ])
    ], swiftLanguageModes: [.v6])
