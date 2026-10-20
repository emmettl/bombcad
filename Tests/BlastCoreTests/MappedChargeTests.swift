import Foundation
import Metal
import RadialBlast
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// The blast's first moments solved in one dimension and mapped onto the grid.
@Suite("Mapped charge", .gpuThreads)
struct MappedChargeTests {
    @Test("Mapped onto the grid, the charge brings its energy, and gauges it passed keep their record")
    func mappedOntoGrid() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        var scenario = ScenarioPreset.openGround.scenario
        scenario.gauges = [Gauge("Near", at: SIMD3(34, 32, 0.25)), Gauge("Far", at: SIMD3(52, 32, 0.25))]
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        let balloon = solver.totals()
        solver.configuration.mappedCharge = true
        try solver.load(scenario)
        let mapped = solver.totals()
        // The same energy as the balloon it replaces, which holds exactly the charge's.
        let charge = Double(scenario.charge.energy)
        #expect(
            abs(mapped.energy - balloon.energy) < 0.03 * charge,
            "\(mapped.energy) J against \(balloon.energy) J")
        #expect(solver.time > 0)
        // The near gauge, 2 m out, lies inside the mapped region: its history starts at the
        // blast's arrival, from the one-dimensional solution.
        let near = try #require(solver.gaugeHistories.first)
        #expect(!near.isEmpty && (near.map(\.pressure).max() ?? 0) > 1e6)
        #expect(solver.peakOverpressure(68, 64, 0) > 1e6)
    }

    @Test("Before the grid's clock the fireball comes from the one-dimensional solution, from detonation on")
    func earlyFrames() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        var configuration = SolverConfiguration.recommended
        configuration.mappedCharge = true
        let scenario = ScenarioPreset.openGround.scenario
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.5, configuration: configuration)
        let start = solver.time
        #expect(start > 0.002)
        let spec = ThermalSpec()
        let frames = solver.earlyFireballFrames(
            for: spec, at: [0, 0.0005, 0.001, 0.002, start, start + 0.001])
        // Only the times after detonation and before the clock.
        #expect(frames.map(\.time) == [0.0005, 0.001, 0.002])
        for frame in frames {
            #expect(frame.volume > 0 && frame.temperature >= spec.luminousTemperature, "\(frame.time) s")
            let cells = try #require(frame.cells)
            #expect(cells.fills.contains { $0 > 0 })
            // Each voxel's gas absorbing as hot air, for a volume that asks for it; and the shells
            // themselves, as far out as the luminous gas, for the volume to march.
            #expect(cells.airAbsorption?.contains { $0 > 0 } == true)
            let sphere = try #require(frame.spheres?.first)
            #expect(frame.spheres?.count == 1 && sphere.centre == scenario.charge.position)
            #expect(sphere.temperatures.last.map { $0 >= spec.luminousTemperature } == true)
            // Mirrored by the ground: the luminous gas above it, round the charge.
            #expect(frame.centre.z > 0 && abs(frame.centre.x - scenario.charge.position.x) < 0.5)
        }
        // The fireball grows.
        #expect(
            frames[0].volume < frames[2].volume, "\(frames.map { ($0.time, $0.radius, $0.temperature) })")
    }

    @Test(
        "Before the grid's clock the ground inside the mapped radius comes from the one-dimensional solution")
    func earlyGround() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let scenario = ScenarioPreset.openGround.scenario
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.5, configuration: .recommended)
        let radius = try #require(solver.mappedRadii.first)
        #expect(radius > 16)
        // Soil columns 10 and 16 m from the charge, both inside the mapped radius.
        var spec = GroundShockSpec()
        spec.points = [SIMD2(42, 32), SIMD2(48, 32)]
        spec.depths = [0, 0.5]
        spec.model = .column
        let region = spec.region(cellSize: 0.5)
        let frame = 2e-4
        let start = solver.time
        let times = stride(from: 0, to: start + 0.01, by: frame).map { $0 }
        let early = solver.earlyGroundSlices(low: region.low, high: region.high, at: times)
        // Only the times before the clock, detonation's among them, and still air at detonation.
        #expect(early.map(\.time) == times.filter { $0 < start - 1e-9 })
        #expect(early.first?.values.allSatisfy { $0 == 0 } == true)
        var seeded = GroundShockConsumer(spec: spec)
        var unseeded = GroundShockConsumer(spec: spec)
        for slice in early { seeded.consume(slice) }
        let last = try #require(early.last)
        // The front reaches both points before the clock, its peak and impulse there carried on by
        // the grid's own fields, laid from the same solution.
        let atStart = solver.groundSlice(low: region.low, high: region.high)
        for point in spec.points {
            let before = try #require(last.sample(point))
            let after = try #require(atStart.sample(point))
            #expect(before.peak > 20e3, "\(point)")
            #expect(abs(before.peak / after.peak - 1) < 0.03, "\(before) then \(after)")
            #expect(before.impulse <= after.impulse * 1.001 && before.impulse > 0.5 * after.impulse)
        }
        var next = start
        while solver.time < start + 0.005 - 1e-9 {
            if solver.time >= next - 1e-9 {
                let slice = solver.groundSlice(low: region.low, high: region.high)
                seeded.consume(slice)
                unseeded.consume(slice)
                next += frame
            }
            let result = solver.advance(steps: 32, timeLimit: next)
            try #require(result.steps > 0 && result.isStable)
        }
        // Seeded, the surface moves at about the peak over the soil's impedance (less the column's
        // window shaves off a short pulse's peak); without the early frames, at the overpressure
        // left behind the front when the clock starts.
        let soil = spec.columnProfile.surface
        for (n, point) in seeded.result(frameInterval: frame).points.enumerated() {
            let free = point.peakOverpressure / (soil.density * soil.waveSpeed)
            let with = point.responses[0].verticalVelocity
            let without = unseeded.result(frameInterval: frame).points[n].responses[0].verticalVelocity
            #expect(with > 0.7 * free && with < 1.05 * free, "\(with) m/s against \(free)")
            #expect(without < 0.7 * with, "\(without) m/s unseeded against \(with)")
        }
    }

    @Test("A charge on a mirror plane, or in a corner of two, is mapped as mirrored by each")
    func mirrorPlanes() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        var scenario = ScenarioPreset.openGround.scenario
        scenario.reflectiveFaces = [.zMin, .xMin]
        let middle = scenario.charge.position
        scenario.charge.position = SIMD3(0, middle.y, 0)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        solver.configuration.mappedCharge = true
        #expect(solver.mappings(for: scenario).map(\.mirrors) == [2])
        // Above the ground on the mirror plane: mirrored once.
        scenario.charge.position = SIMD3(0, middle.y, 3)
        #expect(solver.mappings(for: scenario).map(\.mirrors) == [1])
        // On a face that does not reflect: not mapped (the open face is at the charge).
        scenario.reflectiveFaces = [.zMin]
        #expect(solver.mappings(for: scenario).isEmpty)
    }

    @Test("Several charges are each mapped to half the way between them, one by a block left the balloon")
    func severalCharges() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        var scenario = ScenarioPreset.openGround.scenario
        let main = scenario.charge.position
        // One alike 8 m off, one hard against a block: mapped, mapped (4 m out, half way) and balloon.
        scenario.additionalCharges = [
            Charge(mass: scenario.charge.mass, position: main + SIMD3(0, 8, 0)),
            Charge(mass: scenario.charge.mass, position: main + SIMD3(0, -12, 0)),
        ]
        scenario.boxes = [Box(min: main + SIMD3(-1, -12.4, 0), max: main + SIMD3(1, -12.2, 2))]
        scenario.gauges = [
            Gauge("First", at: main + SIMD3(2, 0, 0.25)), Gauge("Second", at: main + SIMD3(2, 8, 0.25)),
        ]
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        let balloon = solver.totals()
        solver.configuration.mappedCharge = true
        let mappings = solver.mappings(for: scenario)
        #expect(mappings.map(\.index) == [0, 1])
        #expect(mappings.allSatisfy { abs($0.radius - 4) < 1e-4 })
        try solver.load(scenario)
        let mapped = solver.totals()
        #expect(
            abs(mapped.energy - balloon.energy) < 0.03 * 3 * Double(scenario.charge.energy),
            "\(mapped.energy) J against \(balloon.energy) J")
        // One clock for both; each gauge 2 m from its own charge keeps that charge's record.
        #expect(solver.time > 0 && solver.mappedStart.count == 2)
        for history in solver.gaugeHistories.prefix(2) {
            #expect(!history.isEmpty && (history.map(\.pressure).max() ?? 0) > 1e6)
        }
        let first = solver.gaugeHistories[0].map(\.pressure).max() ?? 0
        let second = solver.gaugeHistories[1].map(\.pressure).max() ?? 0
        #expect(abs(first / second - 1) < 1e-3, "alike charges, alike records: \(first) and \(second) Pa")
    }
}
