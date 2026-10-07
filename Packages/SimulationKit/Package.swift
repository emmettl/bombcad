// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SimulationKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SceneModel", targets: ["SceneModel"]),
        .library(name: "SceneView", targets: ["SceneView"]),
    ],
    targets: [
        .target(name: "SceneModel"),
        .target(name: "SceneView", dependencies: ["SceneModel"]),
        .testTarget(name: "SimulationKitTests", dependencies: ["SceneModel", "SceneView"]),
    ],
    swiftLanguageModes: [.v6]
)
