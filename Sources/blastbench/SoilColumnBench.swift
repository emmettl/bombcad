import BlastCore
import Foundation
import Metal
import simd

// `blastbench soilcolumn`.
// Split from main.swift (emmettl/bombcad-work#51).

/// The layered soil column under ground points: its peak stress against the characteristics'
/// closed form for bilinear soil at several steps, and its cost a frame for a line of points fed
/// a frame a millisecond, as `GroundShockConsumer` runs it.
func runSoilColumn() throws {
    let ratio = Double(option("ratio") ?? "2") ?? 2
    let points = Int(option("points") ?? "31") ?? 31
    let deepest = Float(option("depth") ?? "3") ?? 3
    let (peak, duration) = (100e3, 0.004)
    let surface = { (t: Double) in t >= 0 && t <= duration ? peak * (1 - t / duration) : 0 }
    let depths = [0.5, 1.2, 3, 5]
    print(
        "Bilinear soil, 1,600 kg/m³ loading at 300 m/s, unloading at \(300 * ratio) m/s; 100 kPa over 4 ms:")
    print(
        "step (s)   element (m)   peak stress against the closed form at "
            + depths.map { "\($0) m" }.joined(separator: ", "))
    for step in [2e-4, 1e-4, 5e-5, 2.5e-5, 1.25e-5] {
        let profile = SoilProfile(
            layers: [
                SoilLayer(thickness: 1, density: 1600, waveSpeed: 300, unloadingWaveSpeed: Float(300 * ratio))
            ],
            timeStep: Float(step))
        var column = SoilColumn(profile: profile, depth: 5)
        while column.time < 0.03 {
            let t = column.time
            let mean = { (t: Double) -> Double in
                let s = min(max(t, 0), duration)
                return peak * (s - s * s / (2 * duration))
            }
            column.step(load: (mean(t + step / 2) - mean(t - step / 2)) / column.timeStep)
        }
        let mids = column.elementDepths
        let ratios = depths.map { depth -> String in
            let e = mids.indices.min { abs(mids[$0] - depth) < abs(mids[$1] - depth) }!
            let exact = HystereticAttenuation.peakStress(
                depth: mids[e], loadingSpeed: 300, unloadingSpeed: 300 * ratio, surface: surface)
            return String(format: "%.3f", column.peakStress[e] / exact)
        }
        print(String(format: "%-10g %-13.4f ", step, column.depths[1]) + ratios.joined(separator: "  "))
    }
    // The cost: a line of points, 170 frames a millisecond apart, a triangle arriving later
    // further out.
    print("\nCost, \(points) points to \(deepest) m, 170 frames of 1 ms:")
    for step in [1e-4, 5e-5, 2.5e-5] {
        var spec = GroundShockSpec()
        spec.model = .column
        spec.depths = [0, 1, deepest]
        spec.points = (0..<points).map { SIMD2(Float($0) + 0.5, 0.5) }
        spec.profile = SoilProfile(
            layers: [
                SoilLayer(thickness: 1, density: 1600, waveSpeed: 300, unloadingWaveSpeed: Float(300 * ratio))
            ],
            timeStep: Float(step))
        var consumer = GroundShockConsumer(spec: spec)
        let nx = Int32(points + 1)
        let start = Date()
        for frame in 0..<170 {
            let t = Double(frame) * 1e-3
            var values: [Float] = []
            for _ in 0..<2 {
                for i in 0..<Int(nx) {
                    let s = t - Double(i) * 0.002
                    let p = s >= 0 && s <= duration ? peak * (1 - s / duration) : 0
                    let kept = s >= 0 ? peak : 0
                    let impulse =
                        peak * (min(max(s, 0), duration) - pow(min(max(s, 0), duration), 2) / (2 * duration))
                    values += [Float(p), Float(kept), Float(impulse)]
                }
            }
            consumer.consume(
                GroundSlice(
                    time: t, cellSize: 1, grid: SIMD3(nx, 2, 4), first: .zero, counts: SIMD2(nx, 2),
                    values: values,
                    ambientDensity: 1.225, ambientPressure: 101_325, gamma: 1.4))
        }
        let seconds = Date().timeIntervalSince(start)
        let column = SoilColumn(profile: spec.columnProfile, depth: deepest)
        print(
            String(
                format: "step %-8g %4d elements a column: %.3f ms a frame, %.1f ns an element-step", step,
                column.elementCount, seconds / 170 * 1000,
                seconds / (170 * 1e-3 / column.timeStep * Double(column.elementCount * points)) * 1e9))
    }
}
