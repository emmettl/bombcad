// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SimulationKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SceneModel", targets: ["SceneModel"]),
        .library(name: "SceneView", targets: ["SceneView"]),
        .library(name: "SceneRender", targets: ["SceneRender"]),
        .library(name: "DocumentKit", targets: ["DocumentKit"]),
    ],
    targets: [
        .target(name: "SceneModel"),
        .target(name: "SceneView", dependencies: ["SceneModel"]),
        // The shader is compiled when the renderer is made, from the copied source.
        .target(
            name: "SceneRender", dependencies: ["SceneModel", "SceneView"], resources: [.copy("Shaders")]),
        .target(name: "DocumentKit"),
        .testTarget(
            name: "SimulationKitTests",
            dependencies: ["SceneModel", "SceneView", "SceneRender", "DocumentKit"]),
    ],
    swiftLanguageModes: [.v6]
)
