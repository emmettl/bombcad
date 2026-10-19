import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

@Suite("The fireball's rise and cloud", .gpuThreads)
struct FireballRiseTests {
    @Test("A hot sphere in the air is handed over with its mass, place, temperature and buoyancy")
    func handOverFromSolver() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scenario = Scenario(
            name: "Hot", domainSize: SIMD3(repeating: 8), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)))
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.125)
        let centre = SIMD3<Float>(4, 3.5, 4)
        let pressure: Float = 101_325
        let ambient = Float(pressure) / (1.225 * 287.05)
        solver.mutateState { cells in
            for k in 0..<64 {
                for j in 0..<64 {
                    for i in 0..<64 {
                        let x = (SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5) * 0.125
                        let hot = simd_distance(x, centre) < 1.5
                        let t: Float = hot ? 2000 : ambient
                        // The hot gas compressed to twice the pressure, as if the blast had not
                        // quite left it, and rising.
                        let p = hot ? 2 * pressure : pressure
                        cells[solver.grid.index(i, j, k)] = CellState(
                            Primitive(
                                density: p / (287.05 * t), velocity: SIMD3(0, 0, hot ? 5 : 0), pressure: p),
                            gamma: 1.4)
                    }
                }
            }
        }
        let handOver = solver.cloudHandOver(hotterThan: 500)
        let volume = 4 / 3 * Double.pi * pow(1.5, 3)
        let mass = 2 * Double(pressure) * volume / (287.05 * 2000)
        #expect(abs(handOver.mass / mass - 1) < 0.02, "\(handOver.mass) against \(mass)")
        #expect(simd_distance(handOver.centre, centre) < 0.01)
        #expect(abs(handOver.riseSpeed - 5) < 1e-3)
        // Brought to the ambient pressure isentropically, cooling by 2^(0.4/1.4).
        let temperature = 2000 / pow(2, 0.4 / 1.4)
        #expect(abs(handOver.temperature / temperature - 1) < 1e-3, "\(handOver.temperature)")
        #expect(abs(handOver.volume / (handOver.mass * 287.05 * temperature / Double(pressure)) - 1) < 1e-3)
        #expect(
            abs(handOver.buoyancy / (9.80665 * handOver.mass * (temperature / Double(ambient) - 1)) - 1)
                < 1e-3)
        #expect(abs(handOver.warmBuoyancy / handOver.buoyancy - 1) < 1e-6)
        #expect(abs(handOver.ambientTemperature - Double(ambient)) < 1e-3)
        #expect(solver.cloudHandOver(hotterThan: 2000).mass == 0)
    }
}
