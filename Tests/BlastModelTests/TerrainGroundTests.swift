import Foundation
import Testing
import simd

@testable import BlastModel

/// The ground points and their soil columns over a terrain.
@Suite("Ground points on the terrain")
struct TerrainGroundTests {
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
        // Elastic soil: the plane wave's velocity along the column, p / ρc, of the load averaged
        // over the column's window, which shaves the falling triangle's peak by w/(2t_d).
        let velocity = level.points[0].responses[0].verticalVelocity
        let window = GroundShockConsumer.riseSteps * Double(SoilProfile.defaultTimeStep)
        let shaved = Float(1 - window / (2 * 0.004))
        #expect(abs(velocity / (shaved * 80e3 / spec.soil.impedance) - 1) < 0.03)
    }
}
