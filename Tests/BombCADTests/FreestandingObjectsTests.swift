import BlastCore
import BlastRender
import Metal
import SceneRender
import Testing
import simd

@testable import BombCAD

@MainActor
@Suite("Freestanding objects in the app", .serialized)
struct FreestandingObjectsTests {
    @Test("Cars and boxes are added, duplicated with their own identity, edited and removed")
    func editing() throws {
        let model = SimulationModel()
        model.addCars(4)
        model.addFreestandingBox()
        let cars = try #require(model.settings.scenario.rigidCars)
        #expect(cars.count == 4 && model.settings.scenario.rigidObjects?.count == 1)
        // Side by side in 2.4 m bays.
        #expect(abs(cars[1].position.y - cars[0].position.y - 2.4) < 1e-9)
        model.duplicateFreestanding(id: cars[3].id)
        let copy = try #require(model.settings.scenario.rigidCars?.last)
        #expect(copy.id != cars[3].id && abs(copy.position.y - cars[3].position.y - 2.4) < 1e-9)
        let box = try #require(model.settings.scenario.rigidObjects?.first)
        let edited = try box.edited(mass: 400, size: SIMD3(2, 1, 0.5))
        #expect(edited.id == box.id && edited.mass == 400)
        #expect(throws: (any Error).self) { try box.edited(staticFriction: 0.1, slidingFriction: 0.5) }
        model.removeFreestanding(id: box.id)
        #expect(model.settings.scenario.rigidObjects == nil)
        let drawn = model.freestandingBoxes()
        #expect(drawn.count == 5 && drawn.allSatisfy(\.isCar))
        // A shell's centre sits its clearance and half its height above the ground.
        #expect(abs(drawn[0].centre.z - Float(0.15 + 1.3 / 2)) < 1e-5)
    }

    @Test("The 3D view draws freestanding objects")
    func rendering() throws {
        var scene = ScenarioPreset.openGround.scenario
        scene.rigidCars = [try .saloon(position: SIMD3<Double>(scene.charge.position) + SIMD3(0, 4, 0))]
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 1)
        let renderer = try SceneRenderer(device: device)
        renderer.setScene(scene, solver: solver)
        var camera = OrbitCamera.framing(scene)
        camera.target = scene.charge.position
        camera.distance = 25
        let without = try #require(
            renderer.snapshot(commandQueue: queue, width: 240, height: 160, camera: camera))
        let model = SimulationModel()
        model.settings.scenario = scene
        renderer.setFreestanding(model.freestandingBoxes())
        let with = try #require(
            renderer.snapshot(commandQueue: queue, width: 240, height: 160, camera: camera))
        let a = try #require(without.image.dataProvider?.data)
        let b = try #require(with.image.dataProvider?.data)
        #expect(a as Data != b as Data)
    }
}
