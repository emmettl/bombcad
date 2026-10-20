import Foundation
import simd

/// The ground's CPU studies, run headless by `blastbench` and `blastmodel`.
package enum GroundStudies {
    /// `soilcolumn` (`--ratio`, `--points`, `--depth`): the layered soil column under ground
    /// points: its peak stress against the characteristics' closed form for bilinear soil at
    /// several steps, and its cost a frame for a line of points fed a frame a millisecond, as
    /// `GroundShockConsumer` runs it.
    package static func soilColumn(_ args: [String]) throws {
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }

        let ratio = Double(value("ratio") ?? "2") ?? 2
        let points = Int(value("points") ?? "31") ?? 31
        let deepest = Float(value("depth") ?? "3") ?? 3
        let (peak, duration) = (100e3, 0.004)
        let surface = { (t: Double) in t >= 0 && t <= duration ? peak * (1 - t / duration) : 0 }
        let depths = [0.5, 1.2, 3, 5]
        print(
            "Bilinear soil, 1,600 kg/m³ loading at 300 m/s, unloading at \(300 * ratio) m/s; 100 kPa over 4 ms:"
        )
        print(
            "step (s)   element (m)   peak stress against the closed form at "
                + depths.map { "\($0) m" }.joined(separator: ", "))
        for step in [2e-4, 1e-4, 5e-5, 2.5e-5, 1.25e-5] {
            let profile = SoilProfile(
                layers: [
                    SoilLayer(
                        thickness: 1, density: 1600, waveSpeed: 300, unloadingWaveSpeed: Float(300 * ratio))
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
                    SoilLayer(
                        thickness: 1, density: 1600, waveSpeed: 300, unloadingWaveSpeed: Float(300 * ratio))
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
                            peak
                            * (min(max(s, 0), duration) - pow(min(max(s, 0), duration), 2) / (2 * duration))
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

    /// `groundmotion --calibrate` (`--mass`, `--probe`, `--depth`, `--friction`, `--cohesion`,
    /// `--hs-unloading`, `--half-cell`): the half-space's direct source alone, no air, against
    /// UFC 3-340-01's direct-induced peak particle velocity, v = f · 160 · (R/W^(1/3))^(−n) ft/s
    /// with f = 0.14 for a surface burst, in dense sand (n = 2.5; c_P 1,600 ft/s, 488 m/s;
    /// 1,900 kg/m³; Poisson's ratio 0.3), for 1 t of TNT, 0.5 m down. The source's elastic share
    /// for the model's peak resultant velocity to equal UFC's at R/W^(1/3) = 8 ft/lb^(1/3) is the
    /// calibration.
    package static func halfSpaceCalibration(_ args: [String]) throws {
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }

        let mass = value("mass").flatMap(Double.init) ?? 1000
        let probe = value("probe").flatMap(Float.init) ?? 0.01
        let (density, speed, n) = (Float(1900), Float(488), 2.5)
        let scaled = [4.0, 6.0, 8.0, 12.0, 16.0]
        let pounds = cbrt(mass * 2.204_62)
        let ranges = scaled.map { Float($0 * pounds * 0.3048) }
        // Soil that yields, with `--friction` (degrees), `--cohesion` (Pa) and `--hs-unloading`.
        let friction = value("friction").flatMap(Float.init)
        let unloading = value("hs-unloading").flatMap(Float.init) ?? 2
        var spec = GroundShockSpec()
        spec.model = .halfspace
        spec.points = ranges.map { SIMD2($0, 0) }
        spec.depths = [value("depth").flatMap(Float.init) ?? 0.5]
        spec.profile = SoilProfile(
            layers: [
                SoilLayer(
                    thickness: 1, density: density, waveSpeed: speed,
                    unloadingWaveSpeed: friction != nil && unloading > 1 ? speed * unloading : nil,
                    shearWaveSpeed: speed * SoilLayer.defaultShearRatio, frictionAngle: friction,
                    cohesion: friction != nil ? value("cohesion").flatMap(Float.init) ?? 0 : nil)
            ])
        let setup = HalfSpaceSetup(
            centre: .zero, chargeMass: Float(mass), elasticShare: probe,
            cellSize: value("half-cell").flatMap(Float.init))
        let engine = try HalfSpaceGroundShock(spec: spec, setup: setup)
        let end = Double(ranges.max()!) / (Double(speed) * Double(SoilLayer.defaultShearRatio) * 0.9) + 0.05
        let empty = [(overpressure: Float, peak: Float, impulse: Float)?](
            repeating: nil, count: engine.grid.radialCells)
        var t = 0.0
        while t < end {
            t += 1e-3
            engine.consume(rings: empty, time: t)
        }
        print(
            String(
                format:
                    "Direct source alone, %.0f kg, share %.3g: dense sand %.0f kg/m³ at %.0f m/s, n = %.1f, %.2f m deep; grid %.3f m%@",
                mass, probe, density, speed, n, spec.depths[0], engine.grid.spacing,
                friction.map { String(format: "; yielding at %.0f°, unloading ×%.1f", $0, unloading) } ?? ""))
        var calibrated = Double.nan
        for (k, range) in ranges.enumerated() {
            let model = engine.peakResultant[k]
            let ufc = DirectInducedSource.ufcPeakVelocity(range: Double(range), mass: mass, n: n)
            let share = Double(probe) * pow(ufc / model, 2)
            if scaled[k] == 8 { calibrated = share }
            print(
                String(
                    format:
                        "  %5.1f ft/lb^(1/3), %5.1f m: model %.4f m/s, UFC %.4f m/s, ratio %.2f; share for UFC here %.3g",
                    scaled[k], range, model, ufc, model / ufc, share))
        }
        print(String(format: "Calibrated share at 8 ft/lb^(1/3): %.3g", calibrated))
        print(
            String(
                format: "Yielding took %.3g J of the source's %.3g J", engine.stepper.yieldingLoss,
                engine.stepper.work))
    }
}
