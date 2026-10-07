// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RoomCAD",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AcousticCore", targets: ["AcousticCore"]),
        .library(name: "ImpulseResponseKit", targets: ["ImpulseResponseKit"]),
        .library(name: "RoomDocument", targets: ["RoomDocument"]),
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
        .executableTarget(
            name: "RoomCAD",
            dependencies: [
                "AcousticCore", "ImpulseResponseKit", "RoomDocument",
                .product(name: "DocumentKit", package: "SimulationKit"),
            ]),
        .executableTarget(name: "acousticbench", dependencies: ["AcousticCore", "ImpulseResponseKit"]),
        .testTarget(name: "ImpulseResponseKitTests", dependencies: ["ImpulseResponseKit"]),
        .testTarget(name: "AcousticCoreTests", dependencies: ["AcousticCore", "ImpulseResponseKit"]),
        .testTarget(
            name: "RoomDocumentTests",
            dependencies: [
                "RoomDocument", "AcousticCore", "ImpulseResponseKit",
                .product(name: "DocumentKit", package: "SimulationKit"),
            ]),
        .testTarget(name: "RoomCADTests", dependencies: ["RoomCAD", "RoomDocument", "AcousticCore"]),
    ],
    swiftLanguageModes: [.v6]
)
