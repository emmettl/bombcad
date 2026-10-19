import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

@Suite("Stationary building envelopes", .serialized, .gpuThreads)
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

    @Test("A face in still air reads the still air: the same bits as its cell, ambient or not")
    func stillTiles() throws {
        var scene = Scenario(
            name: "Two walls", domainSize: SIMD3(24, 8, 6), boxes: [],
            charge: Charge(mass: 0.05, position: SIMD3(2, 4, 1)))
        for x: Float in [5, 19] {
            try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [Box(min: SIMD3(x, 2, 0), max: SIMD3(x + 0.5, 6, 3))]),
                name: "Wall \(x)")
        }
        let device = try #require(MTLCreateSystemDefaultDevice())
        // At ambient, and in air filled above it, where the still air's overpressure is not zero.
        for filled in [false, true] {
            func surfaces(skipping: Bool) throws -> [EnvelopeSurfaceExposure] {
                let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.25)
                if filled {
                    solver.fill(uniform: Primitive(density: 1.225, pressure: 103_325))
                    solver.restart()
                }
                try solver.configureEnvelopeExposure(objects: scene.envelopeObjects)
                solver.envelopeExposure?.skipStillTiles = skipping
                _ = solver.advance(steps: 40)
                return try #require(solver.envelopeExposureSnapshot()).flatMap(\.surfaces)
            }
            let skipped = try surfaces(skipping: true)
            let read = try surfaces(skipping: false)
            #expect(skipped.count == read.count)
            for (a, b) in zip(skipped, read) {
                #expect(
                    [a.overpressurePa, a.peakPositivePa, a.positiveImpulsePaS, a.signedImpulsePaS].map(
                        \.bitPattern)
                        == [b.overpressurePa, b.peakPositivePa, b.positiveImpulsePaS, b.signedImpulsePaS].map(
                            \.bitPattern)
                        && a.invalid == b.invalid, "filled \(filled)")
            }
        }
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

    @Test(
        "Solid references retain matching door and roof boundaries on all study grids",
        arguments: [Float(0.5), 0.25, 0.125])
    func resolvedOpenings(dx: Float) throws {
        var model = StructureModel(
            solids: [
                Box(min: SIMD3(3, 2, 0), max: SIMD3(3.5, 6, 4)),
                Box(min: SIMD3(3, 2, 4), max: SIMD3(7, 6, 4.5)),
            ], elementSize: 0.5)
        model.openings = [
            Box(min: SIMD3(2.5, 3, 0), max: SIMD3(4, 4, 2.5)),
            Box(min: SIMD3(4, 3, 3.5), max: SIMD3(5, 4, 5)),
        ]
        model.supports = [Box(min: model.bounds.min - 0.01, max: model.bounds.max + 0.01)]
        let reference = Scenario(
            name: "Openings", domainSize: SIMD3(8, 8, 6), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)), structure: model)
        var envelope = reference
        let id = try #require(reference.structuralObject?.id)
        try envelope.useEnvelope(id: id)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let a = try BlastSolver(device: device, scenario: reference, cellSize: dx)
        let b = try BlastSolver(device: device, scenario: envelope, cellSize: dx)
        var differing = 0
        for k in 0..<a.grid.nz {
            for j in 0..<a.grid.ny {
                for i in 0..<a.grid.nx { if a.isSolid(i, j, k) != b.isSolid(i, j, k) { differing += 1 } }
            }
        }
        #expect(differing == 0)
        try a.configureEnvelopeExposure(objects: reference.structuralObjects)
        try b.configureEnvelopeExposure(objects: envelope.envelopeObjects)
        #expect(
            a.envelopeExposureSnapshot()?.first?.surfaces.count
                == b.envelopeExposureSnapshot()?.first?.surfaces.count)
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
