import BlastCore
import BlastRender
import DocumentKit
import Foundation
import Metal
import Testing

@testable import BombCAD

/// A watched run's scene view: sent as `SceneViewCodec` writes it, its field coarsened on the GPU,
/// and drawn here by the app's own renderer.
@MainActor @Suite("A watched run's scene view", .serialized, .hangLimit)
struct SceneViewCodecTests {
    /// Two solid walls and a glass pane as shells, after a few steps of a blast.
    private func solver() throws -> (BlastSolver, Scenario) {
        var scene = try MultiBodyFixture.scene()
        var pane = StructureModel(
            solids: [Box(min: SIMD3(6.5, 2, 0.5), max: SIMD3(6.506, 3, 1.5))], material: .annealedGlass,
            elementSize: 0.125, fixedBase: false)
        pane.elementKind = .shell
        pane.supports = [Box(min: SIMD3(6, 1.5, 0), max: SIMD3(7, 2.01, 3))]
        try scene.addStructureObject(pane, name: "Pane")
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.5)
        solver.advance(steps: 40)
        return (solver, scene)
    }

    @Test("The setup and a frame come back exactly as sent, and malformed bytes are refused")
    func roundTrip() throws {
        let (solver, _) = try solver()
        let setup = ViewSetup(solver: solver, fieldStride: 2)
        #expect(try SceneViewCodec.decodeSetup(SceneViewCodec.encode(setup)) == setup)
        // The materials' colours travel with it: concrete walls, a glass pane.
        let walls = try #require(setup.bodies.first?.solids)
        #expect(walls.materialIndex.count == walls.instances.count)
        #expect(walls.palette.first == MaterialAppearance.concrete.colour)
        let pane = try #require(setup.bodies.compactMap(\.shells).first)
        #expect(pane.palette.first == MaterialAppearance.glass.colour)
        // A setup from a sender before the colours reads, drawn in the first colour.
        var plain = setup
        for n in plain.bodies.indices {
            plain.bodies[n].solids?.materialIndex = []
            plain.bodies[n].solids?.palette = []
            plain.bodies[n].shells?.palette = []
        }
        var older = SceneViewCodec.encode(plain)
        let tail = plain.bodies.reduce(0) { sum, body in
            sum + (body.solids != nil ? 16 : 0) + (body.shells != nil ? 8 : 0)
        }
        older.removeLast(tail)
        #expect(try SceneViewCodec.decodeSetup(older) == plain)
        let frame = try ViewFrame(solver: solver)
        let bytes = SceneViewCodec.encode(frame)
        #expect(SceneViewCodec.size(frame) == bytes.count)
        #expect(try SceneViewCodec.decodeFrame(bytes) == frame)
        #expect(throws: ProjectFileError.self) { try SceneViewCodec.decodeFrame(bytes.dropLast(3)) }
        #expect(throws: ProjectFileError.self) { try SceneViewCodec.decodeFrame(bytes + Data([0])) }
        // A slice of a larger buffer, as a frame's payload is, reads the same.
        let padded = Data([1, 2, 3]) + bytes
        #expect(try SceneViewCodec.decodeFrame(padded.dropFirst(3)) == frame)
    }

    @Test("The field read whole is the solver's; coarser, each texel keeps its block's extremes")
    func coarseField() throws {
        let (solver, _) = try solver()
        let fine = try solver.viewField(stride: 1)
        #expect(fine == (try ViewFrame(solver: solver)).field)
        let grid = solver.grid
        let fineValues = fine.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        for stride in [2, 3] {
            let coarse = try solver.viewField(stride: stride)
            let size = solver.viewFieldSize(stride: stride)
            #expect(coarse.count == size.x * size.y * size.z * 8)
            let values = coarse.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
            var expected = [Float16](repeating: 0, count: values.count)
            for z in 0..<size.z {
                for y in 0..<size.y {
                    for x in 0..<size.x {
                        var best = SIMD4<Float>.zero
                        var strongest: Float = -1
                        for k in 0..<stride {
                            for j in 0..<stride {
                                for i in 0..<stride {
                                    let p = SIMD3(x * stride + i, y * stride + j, z * stride + k)
                                    guard p.x < grid.nx, p.y < grid.ny, p.z < grid.nz else { continue }
                                    let n = 4 * (p.x + grid.nx * (p.y + grid.ny * p.z))
                                    let v = SIMD4((0..<4).map { Float(fineValues[n + $0]) })
                                    if abs(v.x) > strongest {
                                        strongest = abs(v.x)
                                        best.x = v.x
                                    }
                                    for c in 1..<4 { best[c] = max(best[c], v[c]) }
                                }
                            }
                        }
                        let n = 4 * (x + size.x * (y + size.y * z))
                        for c in 0..<4 { expected[n + c] = Float16(best[c]) }
                    }
                }
            }
            #expect(values == expected)
            #expect(values.contains { $0 != 0 })
        }
    }

    @Test("A watched run's scene view arrives set up first, and every frame of it is drawn here")
    func watched() async throws {
        var scene = try MultiBodyFixture.scene()
        scene.charge.mass = 0.05
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.003
        let (worker, server) = localWorker()
        _ = try await worker.start()
        let job = WatchJob(
            id: UUID(), name: "Drawn", project: SweepWorkerArchive(try document.makeArchive()),
            view: ViewSpec(window: 1, compression: .lz4, sceneStride: 2))
        let folder = FileManager.default.temporaryDirectory.appending(path: "scene-view-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let watcher = try SceneWatcher(scenario: scene, render: folder, every: 2)
        var setups = 0
        var frames: [Int] = []
        let result = try await worker.watch(
            job,
            setup: { payload in
                setups += 1
                #expect(frames.isEmpty)
                try? watcher.start(decompressing: payload, .lz4)
            },
            frame: { header, payload in
                frames.append(header.frame)
                let decoded = try? WatchFrame.decode(header, payload: payload)
                #expect(decoded?.scene != nil)
                if let bytes = decoded?.scene { watcher.take(bytes, frame: header.frame) }
                worker.writer.enqueue(.viewAck(job.id, header.frame))
            })
        watcher.finish()
        #expect(watcher.failure == nil)
        #expect(setups == 1 && watcher.frames == frames.count && !frames.isEmpty)
        let drawn = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(drawn.first == "frame-0000.png" && drawn.count == watcher.rendered && drawn.count >= 2)
        #expect(result.stats?.sent == frames.count)
        worker.close()
        await server.value
    }
}
