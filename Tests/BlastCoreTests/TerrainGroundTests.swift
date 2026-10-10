import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// The ground points and their soil columns over a terrain.
@Suite("Ground points on the terrain")
struct TerrainGroundTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// Ground points along the centreline, each with a soil column to 3 m.
    private var spec: GroundShockSpec {
        var spec = GroundShockSpec()
        spec.model = .column
        spec.depths = [0, 1, 3]
        spec.points = []
        spec.line = .init(from: SIMD2(6, 4), to: SIMD2(20, 4), count: 8)
        spec.arrivalThreshold = 1000
        return spec
    }

    /// The consumer's result from a run of `scenario`, a slice every 20 steps, placed on its terrain.
    private func run(_ scenario: Scenario) throws -> GroundShockResult {
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        var consumer = GroundShockConsumer(spec: spec)
        let region = consumer.region(cellSize: solver.grid.cellSize)
        consumer.consume(solver.groundSlice(low: region.low, high: region.high))
        for _ in 0..<12 {
            _ = solver.advance(steps: 20)
            consumer.consume(solver.groundSlice(low: region.low, high: region.high))
        }
        var result = consumer.result(frameInterval: 0.001)
        result.place(on: scenario.terrain)
        return result
    }

    private var open: Scenario {
        Scenario(
            name: "Open", domainSize: SIMD3(24, 8, 12), boxes: [],
            charge: Charge(mass: 2, position: SIMD3(4, 4, 1)))
    }

    @Test("A flat heightfield gives the flat ground's answer, to the bit")
    func flatIsLevel() throws {
        let level = try run(open)
        var scenario = open
        scenario.terrain = .flat(domain: scenario.domainSize, spacing: 0.37)
        let flat = try run(scenario)
        #expect(flat == level)
        #expect(level.points.allSatisfy { $0.elevation == nil && $0.normal == nil && !$0.covered })
        #expect(level.points.contains { ($0.responses.first?.verticalVelocity ?? 0) > 0 })
        // And encodes as results did before the terrain.
        let text = String(decoding: try JSONEncoder().encode(flat), as: UTF8.self)
        #expect(!text.contains("elevation") && !text.contains("normal"))
        #expect(spec.dots(on: scenario.terrain) == spec.dots())
    }

    @Test(
        "On a slope the points sit on the surface, read the air above it, and their columns run along its normal"
    )
    func onASlope() throws {
        var scenario = open
        let slope = Terrain.slope(domain: scenario.domainSize, spacing: 0.5, foot: 8, angle: 30)
        scenario.terrain = slope
        let result = try run(scenario)
        let level = try run(open)
        let rising = SIMD3<Float>(-sin(Float.pi / 6), 0, cos(Float.pi / 6))
        for (point, flat) in zip(result.points, level.points) {
            // Open ground, the air of the first cells above the surface, the blast arriving.
            #expect(
                !point.covered && point.peakOverpressure > 1000,
                "\(point.position) \(point.peakOverpressure) \(flat.peakOverpressure)")
            let elevation = try #require(point.elevation)
            let normal = try #require(point.normal)
            #expect(elevation == slope.height(at: point.position))
            if point.position.x > 8.5 {
                #expect(simd_distance(normal, rising) < 1e-4 && elevation > 0)
            } else if point.position.x < 7.5 {
                #expect(normal == SIMD3(0, 0, 1) && elevation == 0)
            }
            // The column is the level ground's, under this point's own load.
            let marker = point.marker
            #expect(
                abs(simd_dot(marker - SIMD3(point.position.x, point.position.y, elevation), normal) - 0.05)
                    < 1e-6)
            #expect(point.responses.count == flat.responses.count && point.profile != nil)
        }
        // The slope faces the blast: up it, the air reflects and presses harder than on level ground.
        let up = zip(result.points, level.points).filter { $0.0.position.x > 10 }
        #expect(up.contains { $0.0.peakOverpressure > 1.2 * $0.1.peakOverpressure })
        // Drawn there, before a run and after.
        let before = spec.dots(on: slope)
        #expect(before.count == result.points.count)
        for (dot, point) in zip(before, result.points) {
            #expect(simd_distance(SIMD3(dot.x, dot.y, dot.z), point.marker) < 1e-5 && dot.w == 3)
        }
        #expect(result.dots.allSatisfy { $0.z >= slope.height(at: SIMD2($0.x, $0.y)) + 0.04 })
    }

    @Test("A column along the normal is the level column under the same load")
    func columnAlongTheNormal() throws {
        // The same history of overpressure on a point on level ground and on one placed on a
        // slope: the column's answer does not depend on the slope.
        var spec = spec
        spec.line = nil
        spec.points = [SIMD2(1.5, 1.5)]
        func slice(_ t: Double) -> GroundSlice {
            let p: Float = t < 0.002 ? 0 : 80e3 * Float(max(0, 1 - (t - 0.002) / 0.004))
            let kept: Float = t < 0.002 ? 0 : 80e3
            let s = Float(min(max(t - 0.002, 0), 0.004))
            let impulse = 80e3 * (s - s * s / 0.008)
            return GroundSlice(
                time: t, cellSize: 1, grid: SIMD3(4, 4, 4), first: .zero, counts: SIMD2(4, 4),
                values: (0..<16).flatMap { _ in [p, kept, impulse] }, ambientDensity: 1.225,
                ambientPressure: 101_325,
                gamma: 1.4)
        }
        var consumer = GroundShockConsumer(spec: spec)
        for frame in 0...20 { consumer.consume(slice(Double(frame) * 1e-3)) }
        let level = consumer.result(frameInterval: 1e-3)
        var sloped = level
        sloped.place(on: .slope(domain: SIMD3(4, 4, 4), spacing: 0.5, foot: 0, angle: 30))
        #expect(sloped.points[0].normal != nil && sloped.points[0].responses == level.points[0].responses)
        // Elastic soil: the plane wave's velocity along the column, p / ρc.
        let velocity = level.points[0].responses[0].verticalVelocity
        #expect(abs(velocity / (80e3 / spec.soil.impedance) - 1) < 0.03)
    }
}
