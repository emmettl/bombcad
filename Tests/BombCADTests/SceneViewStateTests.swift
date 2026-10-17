import BlastCore
import BlastRender
import Foundation
import Metal
import Testing

/// A run drawn from a view sent from elsewhere looks as it does drawn from its own solver.
@Suite("Scene view state", .serialized, .hangLimit)
struct SceneViewStateTests {
    /// Two solid walls of different element sizes and a 6 mm glass pane between them, as shells.
    private func scene() throws -> Scenario {
        var scene = try MultiBodyFixture.scene()
        var pane = StructureModel(
            solids: [Box(min: SIMD3(6.5, 2, 0.5), max: SIMD3(6.506, 3, 1.5))], material: .annealedGlass,
            elementSize: 0.125, fixedBase: false)
        pane.elementKind = .shell
        pane.supports = [Box(min: SIMD3(6, 1.5, 0), max: SIMD3(7, 2.01, 3))]
        try scene.addStructureObject(pane, name: "Pane")
        return scene
    }

    private func pixels(_ renderer: SceneRenderer, _ queue: MTLCommandQueue, _ scene: Scenario) throws -> Data
    {
        let frame = try #require(
            renderer.snapshot(commandQueue: queue, width: 320, height: 200, camera: .framing(scene)))
        return try #require(frame.image.dataProvider?.data) as Data
    }

    @Test("A view uploaded from a run's setup and frame draws the same pixels as its solver")
    func uploadMatchesSolver() throws {
        let scene = try scene()
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let queue = try #require(device.makeCommandQueue())
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.5)
        solver.advance(steps: 40)

        let setup = ViewSetup(solver: solver)
        #expect(setup.bodies.count == 3)
        #expect(setup.bodies.contains { $0.shells.map { $0.transparentMaterials != 0 } ?? false })
        let frame = try ViewFrame(solver: solver)
        #expect(frame.time == solver.time)
        #expect(frame.field.contains { $0 != 0 })

        let renderer = try SceneRenderer(device: device)
        renderer.setScene(scene, solver: solver)
        let local = try pixels(renderer, queue, scene)

        let upload = try ViewUpload(device: device, setup: setup)
        try upload.apply(frame)
        renderer.setScene(scene, view: upload.view)
        #expect(try pixels(renderer, queue, scene) == local)
    }

    @Test("A frame whose parts are not the sizes its setup says is refused and changes nothing")
    func mismatchedFrame() throws {
        let scene = try scene()
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.5)
        let upload = try ViewUpload(device: device, setup: ViewSetup(solver: solver))
        let good = try ViewFrame(solver: solver)
        try upload.apply(good)

        var short = good
        short.time = 1
        short.bodies[0].solids?.flags.removeLast()
        #expect(throws: ViewUploadError.mismatched("solids")) { try upload.apply(short) }
        var field = good
        field.time = 1
        field.field.removeLast(8)
        #expect(throws: ViewUploadError.mismatched("field")) { try upload.apply(field) }
        var bodies = good
        bodies.time = 1
        bodies.bodies.removeLast()
        #expect(throws: ViewUploadError.mismatched("bodies")) { try upload.apply(bodies) }
        #expect(upload.time == good.time)
    }
}
