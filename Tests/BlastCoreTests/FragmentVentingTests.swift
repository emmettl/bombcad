import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Panes holed by a cased charge's fragments opening in the air, with glazing vented.
@Suite("Fragments holing vented panes", .serialized, .gpuThreads)
struct FragmentVentingTests {
    /// A cased kilogram 5 m in front of a building's glazed window (`EnvelopeVentingTests`' scene),
    /// its casing a cylinder standing upright, so its fragments fly level.
    func scene() throws -> (Scenario, FragmentSpec) {
        var scene = Scenario(
            name: "Glazed", domainSize: SIMD3(16, 20, 6), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(7, 2, 1.6)))
        try scene.addEnvelopeObject(
            EnvelopeVentingTests().building(origin: SIMD3(4, 7, 0), cutOpening: true), name: "Building")
        var spec = FragmentSpec()
        spec.casingMass = 1
        spec.count = 4_000
        spec.tracers = 0
        spec.axis = SIMD3(0, 0, 1)
        return (scene, spec)
    }

    func vented(_ scene: Scenario, holes: [String: Double]) throws -> BlastSolver {
        var config = SolverConfiguration.recommended
        config.airSleepThreshold = 0
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.25,
            configuration: config)
        try solver.configureEnvelopeComponents(
            objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.03))
        let construction = EnvelopeConstruction.assumed(objectID: scene.envelopeObjects[0].id)
        try solver.configureEnvelopeVenting(objects: scene.envelopeObjects) { _ in construction }
        solver.setEnvelopePaneHoles(holes)
        return solver
    }

    /// Advances to `end` in batches of `batch` steps (as `BatchTimingTests` cuts a run), noting when
    /// the room's peak first passes 1 kPa, or in one call.
    func run(_ solver: BlastSolver, to end: Double, batch: Int?) -> Double? {
        guard let batch else {
            _ = solver.advance(until: end)
            return nil
        }
        var rose: Double?
        while solver.time < end {
            _ = solver.advance(steps: batch, timeLimit: end)
            if rose == nil, (solver.envelopeVentingSnapshot()?.rooms.first?.peakPa ?? 0) > 1_000 {
                rose = solver.time
            }
        }
        return rose
    }

    @Test("A pane holed before the blast opens then, the room fills earlier, however the run is batched")
    func holedPaneOpensFirst() throws {
        let (scene, spec) = try scene()
        let holes = FragmentCloud.paneHoles(
            spec: spec, scene: FragmentScene(scene), density: scene.atmosphere.density,
            pressure: scene.atmosphere.pressure, until: 0.03)
        let hole = try #require(holes.values.first)
        // Some 2 km/s over the 5 m: before the blast, which takes several milliseconds.
        #expect(holes.count == 1 && hole > 0.002 && hole < 0.004)

        let holed = try vented(scene, holes: holes)
        let roseHoled = run(holed, to: 0.02, batch: 7)
        let opened = try #require(holed.envelopeVentingSnapshot()?.panes.first?.brokenAtS)
        // On the step the run's clock reaches the hole: within a step of it, never before.
        #expect(
            opened >= Double(Float(hole)) - 1e-7 && opened < hole + 2e-4, "opened \(opened), holed \(hole)")

        let whole = try vented(scene, holes: [:])
        let roseWhole = run(whole, to: 0.02, batch: 7)
        let broke = whole.envelopeVentingSnapshot()?.panes.first?.brokenAtS
        #expect(
            broke.map { $0 > opened + 0.001 } ?? true,
            "the blast alone broke it at \(String(describing: broke))")
        let early = try #require(roseHoled)
        #expect(
            roseWhole.map { early < $0 } ?? true,
            "holed rose at \(early), whole at \(String(describing: roseWhole))")

        // The same in one call to the bit.
        let again = try vented(scene, holes: holes)
        _ = run(again, to: 0.02, batch: nil)
        let first = try #require(holed.envelopeVentingSnapshot())
        let second = try #require(again.envelopeVentingSnapshot())
        #expect(second.panes.first?.brokenAtS == first.panes.first?.brokenAtS)
        #expect(second.rooms.first?.peakPa == first.rooms.first?.peakPa)
        #expect(second.rooms.first?.impulsePaS == first.rooms.first?.impulsePaS)
    }
}
