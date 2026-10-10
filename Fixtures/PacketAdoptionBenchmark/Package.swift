// swift-tools-version: 6.4
import Foundation
import PackageDescription

let application = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let package = Package(
    name: "BombCADPacketAdoption", platforms: [.macOS(.v15)],
    dependencies: [.package(path: application.path)],
    targets: [
        .executableTarget(
            name: "PacketAdoptionAdapter",
            dependencies: [
                .product(name: "BlastCore", package: application.lastPathComponent)
            ])
    ], swiftLanguageModes: [.v6])
