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
        .executable(name: "blastmodel", targets: ["BlastModelCLI"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/emmettl/ContinuumKit.git",
            exact: "0.1.0-alpha.30")
    ],
    targets: [
        // The fine one-dimensional start of a blast (`SphericalBlast`), optimised in debug builds
        // too: unoptimised, its millions of cell steps hold every test that starts a run for many
        // minutes.
        .target(
            name: "RadialBlast",
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        // The model without the GPU: scenarios, structures, materials and the calculations
        // that run on the CPU. It imports no Metal, so it also builds and is tested on Linux
        // (Scripts/split/, .github/workflows/linux-blastmodel.yml).
        .target(
            name: "BlastModel",
            dependencies: [
                "RadialBlast",
                .product(name: "CompressibleFlow", package: "continuumkit"),
                .product(name: "GeometryImport", package: "continuumkit"),
                .product(name: "Numerics", package: "continuumkit"),
                .product(name: "SceneModel", package: "continuumkit"),
            ]),
        // Shaders are copied verbatim and compiled at runtime so that `swift build`,
        // `swift test` and Xcode all behave identically.
        .target(
            name: "BlastCore",
            dependencies: [
                "BlastModel", "RadialBlast",
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
        .executableTarget(name: "BlastModelCLI", dependencies: ["BlastModel"]),
        .executableTarget(
            name: "RigidBoxDemo", dependencies: ["BlastCore"], resources: [.copy("viewer.html")]),
        .testTarget(
            name: "BlastModelTests",
            dependencies: [
                "BlastModel", "RadialBlast", .product(name: "SolidMechanics", package: "continuumkit"),
            ]),
        // ContinuumKit's SolidMechanics is the reference the shells' timber law is checked against.
        .testTarget(
            name: "BlastCoreTests",
            dependencies: [
                "BlastCore", "BlastModel", "RadialBlast",
                .product(name: "SolidMechanics", package: "continuumkit"),
            ]),
        .testTarget(
            name: "BombCADTests",
            dependencies: [
                "BombCAD", "BlastCore", "BlastModel", "BlastRender",
                .product(name: "DocumentKit", package: "continuumkit"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)

// Metal, AppKit and SwiftUI do not exist on Linux, and ContinuumKit leaves its Metal and
// AppKit products out there, so on Linux the package is BlastModel, its tests and
// RadialBlast. The Mac builds everything as before. (RadialBlast imports simd only where there
// is Apple's, and has its two functions of it itself on Linux.)
#if os(Linux)
    let linuxTargets: Set<String> = ["RadialBlast", "BlastModel", "BlastModelCLI", "BlastModelTests"]
    package.targets.removeAll { !linuxTargets.contains($0.name) }
    package.products.removeAll { $0.name != "blastmodel" }
#endif
