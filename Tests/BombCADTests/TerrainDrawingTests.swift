import BlastCore
import BlastRender
import Foundation
import Metal
import SceneView
import Testing
import simd

@testable import BombCAD

/// What the app draws over a terrain: the thermal radiation's paint on its surface, and objects
/// set on it.
@MainActor @Suite("Drawing on the terrain")
struct TerrainDrawingTests {
    private var scene: Scenario {
        var scene = Scenario(
            name: "Hill", domainSize: SIMD3(40, 40, 20), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(8, 20, 0.5)))
        scene.terrain = .hill(
            domain: scene.domainSize, spacing: 0.5, centre: SIMD2(24, 20), height: 6, radius: 5)
        return scene
    }

    /// The colour at the middle of a view straight down onto the hill's top, red and blue from 0
    /// to 1, with every ground receiver painted `shade`.
    private func hilltop(shade: Float?) throws -> (red: Float, blue: Float) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let scene = scene
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 1)
        let renderer = try SceneRenderer(device: device)
        renderer.setScene(scene, solver: solver)
        if let shade {
            let grids = ThermalExposure.surfaceGrids(scene: FragmentScene(scene), spec: ThermalSpec())
            let count = grids.reduce(0) { $0 + $1.receivers.count }
            renderer.settings.thermal = .fluence
            renderer.setSurfacePaint(
                SurfacePaint(grids: grids, shades: [Float](repeating: shade, count: count)))
        }
        let camera = OrbitCamera(target: SIMD3(24, 20, 6), distance: 12, azimuth: 0.3, elevation: 1.45)
        let frame = try #require(
            renderer.snapshot(commandQueue: queue, width: 64, height: 64, camera: camera))
        let data = try #require(frame.image.dataProvider?.data) as Data
        let row = frame.image.bytesPerRow
        let pixel = 32 * row + 32 * 4
        // Blue, green, red, alpha.
        return (Float(data[pixel + 2]) / 255, Float(data[pixel]) / 255)
    }

    @Test("The thermal radiation is painted on the terrain's surface, not on the floor under it")
    func paintOnTheHill() throws {
        let plain = try hilltop(shade: nil)
        let cold = try hilltop(shade: 0)
        let hot = try hilltop(shade: 1)
        // Unpainted ground is grey; painted hot, the hill's top glows pale yellow, as the ground's
        // patch would on flat ground.
        #expect(abs(plain.red - plain.blue) < 0.08 && abs(cold.red - cold.blue) < 0.08, "\(plain), \(cold)")
        #expect(hot.red > cold.red + 0.2 && hot.red - hot.blue > 0.1, "\(hot) against \(cold)")
    }

    @Test("Objects and cars added over a terrain stand on it")
    func objectsOnTheHill() throws {
        let model = SimulationModel()
        var scene = scene
        scene.charge.position = SIMD3(24, 15, 6)
        model.settings.scenario = scene
        model.addFreestandingBox()
        model.addCars()
        let terrain = try #require(scene.terrain)
        let world = try RigidBodyWorldProbe(model.settings.scenario)
        #expect(world.count == 2)
        for lowest in world.lowestClearances { #expect(abs(lowest) < 1e-4, "\(lowest)") }
        #expect(world.highestGround(terrain) > 0.5)
    }
}

/// The freestanding objects' lowest points over the ground, through the scene's own definitions.
private struct RigidBodyWorldProbe {
    let points: [[SIMD3<Double>]]
    let terrain: Terrain

    init(_ scenario: Scenario) throws {
        terrain = try #require(scenario.terrain)
        var points: [[SIMD3<Double>]] = []
        for object in scenario.rigidObjects ?? [] {
            guard case .box(let size) = object.shape else { continue }
            let pose = simd_quatd(vector: object.orientation)
            points.append(
                (0..<8).map { corner in
                    let local = SIMD3<Double>(
                        corner & 1 == 0 ? -0.5 : 0.5, corner & 2 == 0 ? -0.5 : 0.5,
                        corner & 4 == 0 ? -0.5 : 0.5)
                    return object.position + pose.act(local * size)
                })
        }
        for car in scenario.rigidCars ?? [] {
            // The tyres' contact points lie on the footprint's plane, a car's position; its shell
            // stands its clearance above.
            let pose = simd_quatd(vector: car.orientation)
            let half = SIMD2<Double>(car.wheelbase / 2, car.track / 2)
            let tyres = [SIMD2<Double>(1, 1), SIMD2(1, -1), SIMD2(-1, 1), SIMD2(-1, -1)].map {
                car.position + pose.act(SIMD3(half.x * $0.x, half.y * $0.y, 0))
            }
            let shell = (0..<4).map { corner in
                car.position
                    + pose.act(
                        SIMD3(
                            (corner & 1 == 0 ? -0.5 : 0.5) * car.shellSize.x,
                            (corner & 2 == 0 ? -0.5 : 0.5) * car.shellSize.y, car.groundClearance))
            }
            points.append(tyres + shell)
        }
        self.points = points
    }

    var count: Int { points.count }

    var lowestClearances: [Double] {
        points.map { set in set.map { $0.z - Double(terrain.height(at: SIMD3<Float>($0))) }.min()! }
    }

    func highestGround(_ terrain: Terrain) -> Double {
        points.flatMap { $0 }.map { Double(terrain.height(at: SIMD3<Float>($0))) }.max() ?? 0
    }
}
