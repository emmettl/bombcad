// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RoomCAD",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AcousticCore", targets: ["AcousticCore"]),
        .library(name: "ImpulseResponseKit", targets: ["ImpulseResponseKit"]),
        .executable(name: "acousticbench", targets: ["acousticbench"]),
    ],
    targets: [
        .target(name: "ImpulseResponseKit"),
        .target(name: "AcousticCore", dependencies: ["ImpulseResponseKit"]),
        .executableTarget(name: "acousticbench", dependencies: ["AcousticCore", "ImpulseResponseKit"]),
        .testTarget(name: "ImpulseResponseKitTests", dependencies: ["ImpulseResponseKit"]),
        .testTarget(name: "AcousticCoreTests", dependencies: ["AcousticCore", "ImpulseResponseKit"]),
    ],
    swiftLanguageModes: [.v6]
)
