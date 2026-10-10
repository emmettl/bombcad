// swift-tools-version: 6.4
import Foundation
import PackageDescription

let application = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let package = Package(
    name: "BombCADEulerAdoption", platforms: [.macOS(.v15)],
    dependencies: [.package(path: application.path)],
    targets: [
        .executableTarget(
            name: "EulerAdoptionAdapter",
            dependencies: [
                .product(name: "BlastCore", package: application.lastPathComponent)
            ])
    ], swiftLanguageModes: [.v6])
