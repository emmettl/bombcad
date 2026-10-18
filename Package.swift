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
            exact: "0.1.0-alpha.28")
    ],
    targets: [
        // The fine one-dimensional start of a blast (`SphericalBlast`), optimised in debug builds
        // too: unoptimised, its millions of cell steps hold every test that starts a run for many
        // minutes.
        .target(
            name: "RadialBlast",
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        // Shaders are copied verbatim and compiled at runtime so that `swift build`,
        // `swift test` and Xcode all behave identically.
        .target(
            name: "BlastCore",
            dependencies: [
                "RadialBlast",
                .product(name: "SceneModel", package: "continuumkit"),
                .product(name: "GeometryImport", package: "continuumkit"),
                .product(name: "CompressibleFlow", package: "continuumkit"),
                .product(name: "Numerics", package: "continuumkit"),
                .product(name: "ContactSearchMetal", package: "continuumkit"),
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
        .executableTarget(name: "blastbench", dependencies: ["BlastCore", "BlastRender", "RadialBlast"]),
        .executableTarget(name: "SceneBench", dependencies: ["BlastCore", "BlastRender"]),
        .executableTarget(
            name: "RigidBoxDemo", dependencies: ["BlastCore"], resources: [.copy("viewer.html")]),
        // ContinuumKit's SolidMechanics is the reference the shells' timber law is checked against.
        .testTarget(
            name: "BlastCoreTests",
            dependencies: [
                "BlastCore", "RadialBlast", .product(name: "SolidMechanics", package: "continuumkit"),
            ]),
        .testTarget(
            name: "BombCADTests",
            dependencies: [
                "BombCAD", "BlastCore", "BlastRender", .product(name: "DocumentKit", package: "continuumkit"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
