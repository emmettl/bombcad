// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RoomCAD",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AcousticCore", targets: ["AcousticCore"]),
        .library(name: "ImpulseResponseKit", targets: ["ImpulseResponseKit"]),
        .library(name: "RoomDocument", targets: ["RoomDocument"]),
        .library(name: "Audition", targets: ["Audition"]),
        .executable(name: "RoomCAD", targets: ["RoomCAD"]),
        .executable(name: "acousticbench", targets: ["acousticbench"]),
    ],
    dependencies: [.package(path: "../Packages/SimulationKit")],
    targets: [
        .target(name: "ImpulseResponseKit"),
        .target(name: "AcousticCore", dependencies: ["ImpulseResponseKit"]),
        .target(
            name: "RoomDocument",
            dependencies: [
                "AcousticCore", "ImpulseResponseKit", .product(name: "DocumentKit", package: "SimulationKit"),
            ]),
        // Bundled dry recordings are listed, with their credits, in Clips/clips.json.
        .target(
            name: "Audition", dependencies: ["AcousticCore", "ImpulseResponseKit"],
            resources: [.copy("Clips")]),
        .executableTarget(
            name: "RoomCAD",
            dependencies: [
                "AcousticCore", "ImpulseResponseKit", "RoomDocument", "Audition",
                .product(name: "DocumentKit", package: "SimulationKit"),
                .product(name: "SceneModel", package: "SimulationKit"),
                .product(name: "SceneView", package: "SimulationKit"),
                .product(name: "SceneRender", package: "SimulationKit"),
                .product(name: "GeometryImport", package: "SimulationKit"),
            ]),
        .executableTarget(
            name: "acousticbench", dependencies: ["AcousticCore", "ImpulseResponseKit", "Audition"]),
        .testTarget(name: "ImpulseResponseKitTests", dependencies: ["ImpulseResponseKit"]),
        .testTarget(name: "AcousticCoreTests", dependencies: ["AcousticCore", "ImpulseResponseKit"]),
        .testTarget(
            name: "RoomDocumentTests",
            dependencies: [
                "RoomDocument", "AcousticCore", "ImpulseResponseKit",
                .product(name: "DocumentKit", package: "SimulationKit"),
            ]),
        .testTarget(name: "AuditionTests", dependencies: ["Audition", "AcousticCore", "ImpulseResponseKit"]),
        .testTarget(
            name: "RoomCADTests",
            dependencies: [
                "RoomCAD", "RoomDocument", "AcousticCore",
                .product(name: "SceneRender", package: "SimulationKit"),
                .product(name: "SceneView", package: "SimulationKit"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
