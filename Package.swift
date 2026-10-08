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
        .executable(name: "rigidboxdemo", targets: ["RigidBoxDemo"]),
    ],
    dependencies: [.package(path: "Packages/SimulationKit")],
    targets: [
        // Shaders are copied verbatim and compiled at runtime so that `swift build`,
        // `swift test` and Xcode all behave identically.
        .target(
            name: "BlastCore",
            dependencies: [
                .product(name: "SceneModel", package: "SimulationKit")
            ], resources: [.copy("Shaders")]),
        .target(
            name: "BlastRender",
            dependencies: [
                "BlastCore",
                .product(name: "SceneView", package: "SimulationKit"),
            ], resources: [.copy("Shaders")]),
        .executableTarget(
            name: "BombCAD",
            dependencies: [
                "BlastCore", "BlastRender", .product(name: "DocumentKit", package: "SimulationKit"),
                .product(name: "SceneRender", package: "SimulationKit"),
            ]),
        .executableTarget(name: "blastbench", dependencies: ["BlastCore", "BlastRender"]),
        .executableTarget(
            name: "RigidBoxDemo", dependencies: ["BlastCore"], resources: [.copy("viewer.html")]),
        .testTarget(name: "BlastCoreTests", dependencies: ["BlastCore"]),
        .testTarget(
            name: "BombCADTests",
            dependencies: [
                "BombCAD", "BlastCore", .product(name: "DocumentKit", package: "SimulationKit"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
