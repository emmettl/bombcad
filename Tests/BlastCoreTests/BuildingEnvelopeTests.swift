import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

@Suite("Stationary building envelopes", .serialized)
struct BuildingEnvelopeTests {
    func scene() throws -> Scenario {
        var scene = Scenario(
            name: "Envelope", domainSize: SIMD3(8, 8, 6), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)))
        scene.reflectiveFaces = .all
        try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [
                Box(min: SIMD3(3, 3, 2), max: SIMD3(5, 5, 4))
            ]), name: "Cube")
        return scene
    }

    @Test("Overlapping openings retain the half-open box boundary convention")
    func openings() throws {
        let envelope = try BuildingEnvelope(
            solids: [Box(min: .zero, max: SIMD3(4, 2, 3))],
            openings: [
                Box(min: SIMD3(1, 0, 0), max: SIMD3(2, 2, 2)),
                Box(min: SIMD3(1.5, 0, 1), max: SIMD3(3, 2, 2)),
            ])
        for x in stride(from: Float(0), through: 4, by: 0.25) {
            for z in stride(from: Float(0), through: 3, by: 0.25) {
                let p = SIMD3(x, 1, z)
                #expect(envelope.occupies(p) == envelope.blocks.contains { $0.contains(p) })
            }
        }
        #expect(throws: SceneObjectError.self) {
            try BuildingEnvelope(solids: [Box(min: .zero, max: SIMD3(1, 1, 0))])
        }
        #expect(throws: SceneObjectError.self) {
            try BuildingEnvelope(
                solids: [Box(min: .zero, max: SIMD3(1, 1, 1))],
                openings: [Box(min: .zero, max: SIMD3(1, 1, 1))])
        }
    }

    @Test("Conversion and encoding preserve owner, openings and physics fingerprint semantics")
    func ownership() throws {
        var scene = try StreetInteractionStudy.make(.pair, clamped: true)
        let original = scene.structuralObjects
        for object in original { try scene.useEnvelope(id: object.id) }
        #expect(scene.structuralObjects.isEmpty)
        #expect(scene.envelopeObjects.map(\.id) == original.map(\.id))
        let reopened = try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(scene))
        #expect(reopened == scene)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.userInfo[Scenario.physicsInputEncoding] = true
        let first = try encoder.encode(scene)
        var renamed = scene
        renamed.objects[0].name = "Renamed"
        #expect(try encoder.encode(renamed) == first)
        #expect(!scene.chargeIsBlocked)
        scene.charge.position = SIMD3(16.25, 6.25, 1)
        #expect(scene.chargeIsBlocked)
    }

    @Test("Surface integrals agree with independent per-step CPU pressure, including suction")
    func integrals() throws {
        let scene = try scene()
        let device = try #require(MTLCreateSystemDefaultDevice())
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.5)
        solver.mutateState { cells in
            for index in cells.indices {
                let i = index % solver.grid.nx
                cells[index] = CellState(
                    Primitive(
                        density: 1.225,
                        pressure: 101_325 + (i < 8 ? 5000 : -2000)), gamma: 1.4)
            }
        }
        solver.restart()
        try solver.configureEnvelopeExposure(objects: scene.envelopeObjects)
        let initial = try #require(solver.envelopeExposureSnapshot()?.first)
        #expect(initial.surfaces.count == 96)
        var positive = Array(repeating: Float(0), count: initial.surfaces.count)
        var signed = positive
        var peaks = positive
        func pressure(_ face: EnvelopeSurfaceExposure) -> Float {
            let cell = solver.grid.cell(containing: face.positionM + face.normal * 0.25)
            return solver.primitive(cell.i, cell.j, cell.k).pressure - 101_325
        }
        for (index, face) in initial.surfaces.enumerated() { peaks[index] = max(0, pressure(face)) }
        for _ in 0..<8 {
            let result = solver.advance(steps: 1)
            #expect(result.isStable)
            for (index, face) in initial.surfaces.enumerated() {
                let p = pressure(face)
                peaks[index] = max(peaks[index], max(p, 0))
                positive[index] += max(p, 0) * Float(result.elapsed)
                signed[index] += p * Float(result.elapsed)
            }
        }
        let snapshot = try #require(solver.envelopeExposureSnapshot()?.first)
        for (index, face) in snapshot.surfaces.enumerated() {
            #expect(!face.invalid)
            #expect(abs(face.peakPositivePa - peaks[index]) < 0.02)
            #expect(abs(face.positiveImpulsePaS - positive[index]) < 0.0001)
            #expect(abs(face.signedImpulsePaS - signed[index]) < 0.0001)
        }
        #expect(snapshot.surfaces.contains { $0.signedImpulsePaS < 0 })
        solver.restart()
        #expect(solver.envelopeExposureSnapshot()!.first!.surfaces.allSatisfy { $0.signedImpulsePaS == 0 })
        try solver.load(scene)
        #expect(solver.envelopeExposureSnapshot() == nil)
    }

    @Test("Uniform pressure cancels over a closed cube and observes a clipped final interval")
    func cancellation() throws {
        let scene = try scene()
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.5)
        solver.fill(uniform: Primitive(density: 1.225, pressure: 103_325))
        solver.restart()
        try solver.configureEnvelopeExposure(objects: scene.envelopeObjects)
        let command = try #require(solver.encodeBatch(steps: 8, timeLimit: 0.00001))
        command.commit()
        command.waitUntilCompleted()
        _ = solver.completeBatch()
        let result = try #require(solver.envelopeExposureSnapshot()?.first)
        #expect(abs(result.elapsedS - 0.00001) < 1e-10)
        #expect(simd_length(result.forceN) < 1e-5)
        #expect(simd_length(result.signedImpulseNS) < 1e-7)
        for face in result.surfaces { #expect(abs(face.positiveImpulsePaS - 0.02) < 1e-5) }
    }

    @Test("Recording leaves coarse and refined air bit-identical", arguments: [1, 2])
    func passive(refinement: Int) throws {
        var scene = try scene()
        scene.charge.mass = 0.02
        var config = SolverConfiguration()
        config.refinement = refinement
        config.refinementMemory = 16 << 20
        let device = try #require(MTLCreateSystemDefaultDevice())
        let plain = try BlastSolver(device: device, scenario: scene, cellSize: 0.5, configuration: config)
        let observed = try BlastSolver(device: device, scenario: scene, cellSize: 0.5, configuration: config)
        try observed.configureEnvelopeExposure(objects: scene.envelopeObjects)
        _ = plain.advance(steps: 16)
        _ = observed.advance(steps: 16)
        let states = plain.withState { Array($0) }
        observed.withState { cells in
            for (a, b) in zip(states, cells) {
                #expect(
                    a.density == b.density && a.energy == b.energy && a.momentumX == b.momentumX
                        && a.momentumY == b.momentumY && a.momentumZ == b.momentumZ)
            }
        }
    }

    @Test("Moving structural references are rejected")
    func rejectMoving() throws {
        let scene = try StreetInteractionStudy.make(.isolated)
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.5)
        #expect(throws: BlastError.self) {
            try solver.configureEnvelopeExposure(objects: scene.structuralObjects)
        }
    }
}
