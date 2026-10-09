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
        .executable(name: "scenebench", targets: ["SceneBench"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/emmettl/ContinuumKit.git",
            exact: "0.1.0-alpha.5")
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
        .executableTarget(name: "SceneBench", dependencies: ["BlastCore", "BlastRender"]),
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
