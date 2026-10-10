import BlastCore
import BlastRender
import DocumentKit
import Foundation
import Testing
import simd

@testable import BombCAD

@MainActor @Suite("The fireball's cloud followed after a run in the app", .serialized)
struct CloudOverlayTests {
    /// Low enough to hand over the charge's gas, spread over the coarse grid's half-metre cells.
    private var spec: CloudSpec {
        var spec = CloudSpec()
        spec.handOverTemperature = 400
        spec.duration = 120
        return spec
    }

    private func airOnly() -> ProjectDocument {
        var scene = Scenario(
            name: "Cloud", domainSize: SIMD3(repeating: 8),
            boxes: [Box(min: SIMD3(6, 3, 0), max: SIMD3(7, 5, 3))],
            charge: Charge(mass: 2, position: SIMD3(3, 4, 1)))
        scene.gauges = [Gauge("Near", at: SIMD3(4, 4, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.01
        return document
    }

    private func ready(_ model: SimulationModel, by deadline: ContinuousClock.Instant) async throws {
        while !model.experimentIsReady {
            try #require(ContinuousClock.now < deadline && model.errorMessage == nil)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Runs `document` to its end and keeps the run once its cloud is followed.
    private func run(_ document: ProjectDocument, cloud: CloudSpec?) async throws -> (
        SimulationModel, SavedSimulationRun
    ) {
        var document = document
        document.cloud = cloud
        let model = SimulationModel(document: document, playbackSpeed: .unlimited)
        let deadline = ContinuousClock.now + .seconds(120)
        try await ready(model, by: deadline)
        model.run()
        while model.isRunning || model.hasPendingGPUWork || !model.companionsCaughtUp {
            try #require(ContinuousClock.now < deadline && model.errorMessage == nil)
            try await Task.sleep(for: .milliseconds(5))
        }
        try model.keepRun(named: "Run")
        return (model, model.savedRuns.last!)
    }

    @Test("The cloud is followed from the run's end, changes nothing in the air, and is kept with the run")
    func kept() async throws {
        let (_, without) = try await run(airOnly(), cloud: nil)
        let (model, kept) = try await run(airOnly(), cloud: spec)
        #expect(kept.stepCount == without.stepCount && kept.gauges == without.gauges)
        #expect(without.cloud == nil)
        let cloud = try #require(model.cloud)
        #expect(kept.cloud == cloud && cloud.spec == spec)
        #expect(abs(cloud.handOver.time - 0.01) < 1e-6 && cloud.handOver.mass > 0)
        #expect(abs((cloud.samples.last?.time ?? 0) - (0.01 + 120)) < 1e-6)
        #expect(cloud.samples.last!.height > Double(cloud.handOver.centre.z))
        #expect(cloud.comparison.hasPrefix("Cloud: "))
        // Not part of the inputs' fingerprint, as it does not act on the air.
        #expect(
            kept.inputSHA256 == (try SavedSimulationRun.fingerprint(kept.scenario, settings: kept.settings)))

        var document = ProjectDocument(model: model)
        #expect(document.cloud == spec)
        let reopened = try ProjectDocument(archive: document.makeArchive())
        #expect(reopened.savedRuns.last?.cloud == cloud && reopened.cloud == spec)
        document.cloud = nil
        #expect(try ProjectDocument(archive: document.makeArchive()).cloud == nil)

        // Using a run's inputs brings its cloud back, as one step to undo.
        model.cloudSpec = nil
        try await Task.sleep(for: .milliseconds(300))
        try model.useRunInputs(id: kept.id)
        #expect(model.cloudSpec == spec)
        model.undo()
        #expect(model.cloudSpec == nil)
        model.redo()
        #expect(model.cloudSpec == spec)

        var broken = kept
        broken.cloud?.samples[1].radius = -1
        #expect(throws: ProjectFileError.self) { try broken.validate() }
        broken = kept
        broken.cloud?.samples.swapAt(1, 2)
        #expect(throws: ProjectFileError.self) { try broken.validate() }

        model.reset()
        try await ready(model, by: ContinuousClock.now + .seconds(10))
        #expect(model.cloud == nil && !model.followingCloud)
    }

    @Test(
        "The path is drawn as lines: the track, the outlines until it stopped and as it spread, and its drift"
    )
    func lines() throws {
        let handOver = CloudHandOver(
            time: 0.1, mass: 700, volume: 4 / 3 * .pi * pow(8, 3), centre: SIMD3(30, 30, 5),
            temperature: 1200,
            riseSpeed: 5, hottest: 1500, buoyancy: 0, warmBuoyancy: 0, ambientTemperature: 288.15,
            ambientPressure: 101_325, chargeMass: 100)
        var still = CloudSpec()
        still.duration = 600
        let cloud = CloudResult(spec: still, handOver: handOver)
        let stopped = try #require(cloud.stabilised)
        #expect(CloudOverlay.interval(cloud) == 60)
        let eye = SIMD3<Float>(-500, -500, 200)
        let lines = CloudOverlay.lines(cloud, eye: eye)
        #expect(lines.count % 2 == 0)
        let kinds = stride(from: 0, to: lines.count, by: 2).map { Int(lines[$0].w) }
        // A segment of the track, and of its shadow on the ground, between each pair of samples,
        // and lines down to the ground from where it stopped and from where it ended.
        #expect(kinds.filter { $0 == CloudOverlay.Kind.track.rawValue }.count == cloud.samples.count - 1)
        #expect(kinds.filter { $0 == CloudOverlay.Kind.ground.rawValue }.count == cloud.samples.count + 1)
        // As it spread, its ring at each half minute after it stopped, and at the end its ring and
        // its outline from the side.
        let last = try #require(cloud.samples.last)
        #expect(CloudOverlay.spreadInterval(cloud) == 30 && last.thickness != nil)
        let spreads = Int(((last.time - stopped.time) / 30).rounded(.up))
        #expect(kinds.filter { $0 == CloudOverlay.Kind.spread.rawValue }.count == 64 * (spreads + 1))
        let ends = stride(from: 0, to: lines.count, by: 2).filter {
            Int(lines[$0].w) == CloudOverlay.Kind.spread.rawValue
        }
        .suffix(128).map { SIMD3<Float>(lines[$0].x, lines[$0].y, lines[$0].z) }
        let middle = SIMD3<Float>(Float(last.position.x), Float(last.position.y), Float(last.height))
        #expect(ends.allSatisfy { abs($0.z - middle.z) <= Float(last.halfDepth) * 1.001 })
        #expect(
            ends.map { simd_length(SIMD2($0.x - middle.x, $0.y - middle.y)) }.max()! > Float(last.radius)
                * 0.99)
        // An outline at each minute until it stopped, 64 segments each, and two where it stopped.
        let outlines = Int((stopped.time - handOver.time) / 60) + 1
        #expect(kinds.filter { $0 == CloudOverlay.Kind.outline.rawValue }.count == 64 * outlines)
        #expect(kinds.filter { $0 == CloudOverlay.Kind.stabilised.rawValue }.count == 2 * 64)
        // The outline where it stopped is the sphere's silhouette from the eye: every point on it
        // lies on the cone from the eye that touches the sphere.
        let centre = SIMD3<Float>(Float(stopped.position.x), Float(stopped.position.y), Float(stopped.height))
        let tangent = asin(Float(stopped.radius) / simd_distance(eye, centre))
        for n in kinds.indices where kinds[n] == CloudOverlay.Kind.stabilised.rawValue {
            let point = SIMD3<Float>(lines[2 * n].x, lines[2 * n].y, lines[2 * n].z)
            let angle = acos(simd_dot(simd_normalize(point - eye), simd_normalize(centre - eye)))
            if abs(point.z - centre.z) > 1 { #expect(abs(angle - tangent) < 1e-3) }
        }
        // Framed from the ground to its top, no farther than the controls zoom out.
        let camera = CloudOverlay.framing(cloud)
        #expect(camera.distance <= CloudOverlay.maximumDistance)
        let bounds = CloudOverlay.bounds(cloud)
        #expect(bounds.min.z == 0 && abs(Double(bounds.max.z) - stopped.top) < 30)

        // Carried far downwind, the view frames the cloud where it stopped.
        var windy = still
        windy.windSpeed = 10
        let carried = CloudResult(spec: windy, handOver: handOver)
        let there = try #require(carried.stabilised)
        #expect(carried.drift(there) > 3000)
        let view = CloudOverlay.framing(carried)
        #expect(
            abs(Double(view.target.x) - there.position.x) < 1 && view.distance <= CloudOverlay.maximumDistance
        )
    }
}
