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
    // Candidate pin for shared spatial-query integration; replace with a verified release before merging.
    dependencies: [
        .package(
            url: "https://github.com/emmettl/ContinuumKit.git",
            revision: "d3c7367ba43940155f7e33da738e6f5058723fd5")
    ],
    targets: [
        // Shaders are copied verbatim and compiled at runtime so that `swift build`,
        // `swift test` and Xcode all behave identically.
        .target(
            name: "BlastCore",
            dependencies: [
                .product(name: "SceneModel", package: "continuumkit"),
                .product(name: "GeometryImport", package: "continuumkit"),
            ], resources: [.copy("Shaders")]),
        .target(
            name: "BlastRender",
            dependencies: [
                "BlastCore",
                .product(name: "SceneView", package: "continuumkit"),
            ], resources: [.copy("Shaders")]),
        .executableTarget(
            name: "BombCAD",
            dependencies: [
                "BlastCore", "BlastRender", .product(name: "DocumentKit", package: "continuumkit"),
                .product(name: "SceneRender", package: "continuumkit"),
            ]),
        .executableTarget(name: "blastbench", dependencies: ["BlastCore", "BlastRender"]),
        .executableTarget(
            name: "RigidBoxDemo", dependencies: ["BlastCore"], resources: [.copy("viewer.html")]),
        .testTarget(name: "BlastCoreTests", dependencies: ["BlastCore"]),
        .testTarget(
            name: "BombCADTests",
            dependencies: [
                "BombCAD", "BlastCore", "BlastRender", .product(name: "DocumentKit", package: "continuumkit"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
