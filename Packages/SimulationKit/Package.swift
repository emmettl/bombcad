// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SimulationKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SceneModel", targets: ["SceneModel"]),
        .library(name: "SceneView", targets: ["SceneView"]),
        .library(name: "DocumentKit", targets: ["DocumentKit"]),
    ],
    targets: [
        .target(name: "SceneModel"),
        .target(name: "SceneView", dependencies: ["SceneModel"]),
        .target(name: "DocumentKit"),
        .testTarget(name: "SimulationKitTests", dependencies: ["SceneModel", "SceneView", "DocumentKit"]),
    ],
    swiftLanguageModes: [.v6]
)
