import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// Open faces that stand still ambient air beyond them (`OpenFaces.farField`).
@Suite("Far-field faces", .gpuThreads)
struct FarFieldFacesTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// A 2 kg charge burning in a domain hardly bigger than its fireball, 4 m by 4 m by 3 m on the
    /// ground, with a gauge 0.5 m inside one face: its mean overpressure from 40 to 100 ms, when
    /// the blast has long left.
    private func lateOverpressure(_ faces: OpenFaces) throws -> Double {
        var scenario = Scenario(
            name: "Small domain", domainSize: SIMD3(4, 4, 3), boxes: [],
            charge: Charge(mass: 2, position: SIMD3(2, 2, 0.5)))
        scenario.gauges = [Gauge("near a face", at: SIMD3(3.5, 2, 0.5))]
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.1)
        solver.configuration.afterburning = true
        solver.configuration.openFaces = faces
        try solver.load(scenario)
        solver.advance(until: 0.1)
        let ambient = Double(solver.configuration.ambientPressure)
        let samples = solver.gaugeHistories[0].filter { $0.time >= 0.04 }
        var total = 0.0
        for (a, b) in zip(samples, samples.dropFirst()) {
            total += (b.time - a.time) * (0.5 * (Double(a.pressure) + Double(b.pressure)) - ambient)
        }
        return total / max((samples.last?.time ?? 0) - (samples.first?.time ?? 0), 1e-9)
    }

    @Test("Through far-field faces a small domain's air returns to ambient once the blast has left")
    func lateAirIsAmbient() throws {
        let copied = try lateOverpressure(.copy)
        let farField = try lateOverpressure(.farField)
        #expect(
            abs(farField) < 0.25 * abs(copied), "late overpressure \(farField) Pa against \(copied) copied")
    }

    @Test("Still air beyond and inside far-field faces stays still")
    func stillAirStaysStill() throws {
        var scenario = Scenario(
            name: "Still", domainSize: SIMD3(2, 2, 2), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)))
        scenario.gauges = [Gauge("corner", at: SIMD3(0.05, 0.05, 1.95))]
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.1)
        solver.configuration.openFaces = .farField
        solver.configuration.skipStillAir = false
        try solver.load(scenario)
        solver.advance(until: 0.01)
        let ambient = solver.configuration.ambientPressure
        for sample in solver.gaugeHistories[0] {
            #expect(abs(sample.pressure - ambient) < 1e-3 * ambient)
        }
    }
}
