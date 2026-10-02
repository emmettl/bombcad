// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "BombCAD",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BlastCore", targets: ["BlastCore"]),
        .library(name: "BlastRender", targets: ["BlastRender"]),
        .executable(name: "BombCAD", targets: ["BombCAD"]),
        .executable(name: "blastbench", targets: ["blastbench"]),
    ],
    targets: [
        // Shaders are copied verbatim and compiled at runtime so that `swift build`,
        // `swift test` and Xcode all behave identically.
        .target(name: "BlastCore", resources: [.copy("Shaders")]),
        .target(name: "BlastRender", dependencies: ["BlastCore"], resources: [.copy("Shaders")]),
        .executableTarget(name: "BombCAD", dependencies: ["BlastCore", "BlastRender"]),
        .executableTarget(name: "blastbench", dependencies: ["BlastCore", "BlastRender"]),
        .testTarget(name: "BlastCoreTests", dependencies: ["BlastCore"]),
        .testTarget(name: "BombCADTests", dependencies: ["BombCAD", "BlastCore"]),
    ],
    swiftLanguageModes: [.v6]
)
