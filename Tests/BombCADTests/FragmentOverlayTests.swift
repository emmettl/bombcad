import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@MainActor @Suite("Fragments drawn over a run in the app", .serialized)
struct FragmentOverlayTests {
    private func spec() -> FragmentSpec {
        var spec = FragmentSpec()
        spec.casingMass = 0.05
        spec.count = 300
        spec.tracers = 40
        spec.tracerRegion = Box(min: SIMD3(2, 3, 0.5), max: SIMD3(4, 5, 2))
        return spec
    }

    private func airOnly() -> ProjectDocument {
        var scene = Scenario(
            name: "Cased", domainSize: SIMD3(repeating: 8),
            boxes: [Box(min: SIMD3(6, 3, 0), max: SIMD3(7, 5, 3))],
            charge: Charge(mass: 0.05, position: SIMD3(3, 4, 1)))
        scene.gauges = [Gauge("Near", at: SIMD3(4, 4, 1)), Gauge("Far", at: SIMD3(7.5, 7.5, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.01
        return document
    }

    private func structural() throws -> ProjectDocument {
        let kept = try SavedRunTests().fixture()
        var document = ProjectDocument(scenario: kept.scenario)
        document.runSettings = kept.settings
        return document
    }

    /// Runs `document` to its end at unlimited speed and keeps the run.
    private func run(_ document: ProjectDocument, fragments: FragmentSpec?) async throws -> (
        SimulationModel, SavedSimulationRun
    ) {
        var document = document
        document.fragments = fragments
        let model = SimulationModel(document: document, playbackSpeed: .unlimited)
        let deadline = ContinuousClock.now + .seconds(120)
        while !model.experimentIsReady {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        model.run()
        while model.isRunning || model.hasPendingGPUWork {
            try #require(ContinuousClock.now < deadline && model.errorMessage == nil)
            try await Task.sleep(for: .milliseconds(5))
        }
        try model.keepRun(named: "Run")
        return (model, model.savedRuns.last!)
    }

    @Test("Fragments change nothing in the air or the structure, to the last bit")
    func airUnchanged() async throws {
        for document in [airOnly(), try structural()] {
            let (_, without) = try await run(document, fragments: nil)
            let (model, with) = try await run(document, fragments: spec())
            #expect(with.stepCount == without.stepCount)
            #expect(with.gauges == without.gauges && with.structure == without.structure)
            #expect(model.fragments != nil)
        }
    }

    @Test("The run's particles are drawn as they fly and land, and Reset clears them")
    func dots() async throws {
        let (model, _) = try await run(airOnly(), fragments: spec())
        // The last frames may still be in flight.
        let deadline = ContinuousClock.now + .seconds(10)
        while let fragments = model.fragments, fragments.report.frame < fragments.sent - 1 {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        let live = try #require(model.fragments?.live)
        #expect(live.positions.count == 340 && live.fragmentCount == 300)
        #expect(abs(live.time - 0.01) < 1e-6)
        let dots = model.fragmentDots(showFragments: true, showTracers: true)
        let landed = dots.filter { $0.w >= 2 }.count
        #expect(landed == live.impacts.count && landed > 0)
        #expect(dots.filter { $0.w == 1 }.count == (300..<340).filter { !live.landed[$0] }.count)
        #expect(model.fragmentDots(showFragments: false, showTracers: false).isEmpty)
        #expect(model.fragmentStatus.contains("landed"))
        model.reset()
        let cleared = ContinuousClock.now + .seconds(10)
        while !model.experimentIsReady {
            try #require(ContinuousClock.now < cleared)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.fragmentDots(showFragments: true, showTracers: true).isEmpty)
    }

    @Test("A project keeps its fragments when saved and reopened")
    func saved() throws {
        var document = airOnly()
        document.fragments = spec()
        let reopened = try ProjectDocument(archive: document.makeArchive())
        #expect(reopened.fragments == spec())
        document.fragments = nil
        #expect(try ProjectDocument(archive: document.makeArchive()).fragments == nil)
    }
}
