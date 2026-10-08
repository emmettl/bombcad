// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RoomCAD",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AcousticCore", targets: ["AcousticCore"]),
        .library(name: "RoomDocument", targets: ["RoomDocument"]),
        .library(name: "Audition", targets: ["Audition"]),
        .executable(name: "RoomCAD", targets: ["RoomCAD"]),
        .executable(name: "acousticbench", targets: ["acousticbench"]),
    ],
    dependencies: [.package(url: "https://github.com/emmettl/ContinuumKit.git", exact: "0.1.0-alpha.2")],
    targets: [
        .target(
            name: "AcousticCore",
            dependencies: [.product(name: "ImpulseResponseKit", package: "continuumkit")]),
        .target(
            name: "RoomDocument",
            dependencies: [
                "AcousticCore", .product(name: "ImpulseResponseKit", package: "continuumkit"),
                .product(name: "DocumentKit", package: "continuumkit"),
            ]),
        // Bundled dry recordings are listed, with their credits, in Clips/clips.json.
        .target(
            name: "Audition",
            dependencies: ["AcousticCore", .product(name: "ImpulseResponseKit", package: "continuumkit")],
            resources: [.copy("Clips")]),
        .executableTarget(
            name: "RoomCAD",
            dependencies: [
                "AcousticCore", .product(name: "ImpulseResponseKit", package: "continuumkit"), "RoomDocument",
                "Audition",
                .product(name: "DocumentKit", package: "continuumkit"),
                .product(name: "SceneModel", package: "continuumkit"),
                .product(name: "SceneView", package: "continuumkit"),
                .product(name: "SceneRender", package: "continuumkit"),
                .product(name: "GeometryImport", package: "continuumkit"),
            ]),
        .executableTarget(
            name: "acousticbench",
            dependencies: [
                "AcousticCore", .product(name: "ImpulseResponseKit", package: "continuumkit"), "Audition",
            ]),
        .testTarget(
            name: "AcousticCoreTests",
            dependencies: ["AcousticCore", .product(name: "ImpulseResponseKit", package: "continuumkit")]),
        .testTarget(
            name: "RoomDocumentTests",
            dependencies: [
                "RoomDocument", "AcousticCore", .product(name: "ImpulseResponseKit", package: "continuumkit"),
                .product(name: "DocumentKit", package: "continuumkit"),
            ]),
        .testTarget(
            name: "AuditionTests",
            dependencies: [
                "Audition", "AcousticCore", .product(name: "ImpulseResponseKit", package: "continuumkit"),
            ]),
        .testTarget(
            name: "RoomCADTests",
            dependencies: [
                "RoomCAD", "RoomDocument", "AcousticCore",
                .product(name: "SceneRender", package: "continuumkit"),
                .product(name: "SceneView", package: "continuumkit"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
