import Foundation
import Testing
import simd

@testable import BlastCore

@Suite("Ground shock in a half-space")
struct HalfSpaceGroundShockTests {
    /// Dense sand, as the direct source's calibration uses: 1,900 kg/m³ at 488 m/s, Poisson's ratio 0.3.
    private let sand = SoilProfile(layers: [SoilLayer(thickness: 1, density: 1900, waveSpeed: 488)])

    @Test("Descriptions carry the half-space and its setup, and read older files as before")
    func description() throws {
        let json = #"""
            {"model": "halfspace", "points": [[30, 20]], "depths": [0, 0.5],
             "profile": {"layers": [{"thickness": 2, "density": 1900, "waveSpeed": 488, "shearWaveSpeed": 250}]},
             "halfSpace": {"centre": [20, 20], "chargeMass": 1000, "elasticShare": 0}}
            """#
        let spec = try JSONDecoder().decode(GroundShockSpec.self, from: Data(json.utf8))
        #expect(spec.model == .halfspace && spec.halfSpace?.centre == SIMD2(20, 20))
        #expect(spec.halfSpace?.elasticShare == 0 && spec.profile?.layers[0].shearSpeed == 250)
        #expect(try JSONDecoder().decode(GroundShockSpec.self, from: JSONEncoder().encode(spec)) == spec)
        // Without a shear speed, a Poisson's ratio of 0.3.
        #expect(abs(sand.layers[0].shearSpeed / 488 - 0.5345) < 1e-4)
        // A shear speed beyond c_P/√2 is no solid.
        var bad = spec
        bad.profile?.layers[0].shearWaveSpeed = 400
        #expect(bad.profile?.isValid == false)
        // Older descriptions: no half-space.
        let old = try JSONDecoder().decode(GroundShockSpec.self, from: Data(#"{"points": [[1, 2]]}"#.utf8))
        #expect(old.model == .estimate && old.halfSpace == nil)
    }

    @Test("BombCAD run puts the axis under the charge, and the slice covers the disc")
    func setup() {
        var spec = GroundShockSpec()
        spec.model = .halfspace
        spec.points = [SIMD2(40, 30)]
        let scenario = Scenario(
            name: "Open", domainSize: SIMD3(64, 64, 32), boxes: [],
            charge: Charge(mass: 100, position: SIMD3(32, 30, 0)))
        let set = spec.settingHalfSpace(from: scenario)
        #expect(set.halfSpace == HalfSpaceSetup(centre: SIMD2(32, 30), chargeMass: 100))
        #expect(spec.settingHalfSpace(from: scenario).halfSpace != nil)
        // The disc reaches past the point by a seventh and 5 m, all round the axis.
        let reach = Float(HalfSpaceGroundShock.reach(points: spec.points, centre: SIMD2(32, 30)))
        #expect(abs(reach - (1.15 * 8 + 5)) < 1e-4)
        let region = set.region(cellSize: 0.5)
        #expect(region.low == SIMD2(32, 30) - reach - 0.5 && region.high == SIMD2(32, 30) + reach + 0.5)
        // The estimate's region is only the points'.
        var estimate = spec
        estimate.model = .estimate
        #expect(estimate.region(cellSize: 0.5).low == SIMD2(39.5, 29.5))
    }

    @Test("UFC 3-340-01's direct-induced velocity, as Xia et al. use it")
    func ufc() {
        // v = f · 160 · (R/W^(1/3))^(−n) ft/s: 1 t at 8 ft/lb^(1/3), n = 2.5, f = 0.14.
        let range = 8 * cbrt(1000 * 2.204_62) * 0.3048
        let v = DirectInducedSource.ufcPeakVelocity(range: range, mass: 1000, n: 2.5)
        #expect(abs(v / (0.14 * 160 * pow(8, -2.5) * 0.3048) - 1) < 1e-12)
        // Xia et al.'s fitted n = 2.55 at 21 m: 0.098 m/s with W as TNT (they give 0.116, with W
        // as C-4).
        #expect(abs(DirectInducedSource.ufcPeakVelocity(range: 21, mass: 1000, n: 2.55) - 0.0976) < 0.001)
    }

    @Test("The direct source does the work its share of the charge's energy sets")
    func directSource() throws {
        // 100 kg on dense sand at a hundredth of a per cent: the work the crater's disc does on
        // the elastic ground, against the share it is set for (by the estimate πa²∫p²dt/(ρc_P)
        // for a disc wider than its waves; a third or so either way for a narrow one).
        var spec = GroundShockSpec()
        spec.model = .halfspace
        spec.profile = sand
        spec.points = [SIMD2(12, 0)]
        spec.depths = [0.5]
        let share: Float = 1e-4
        let setup = HalfSpaceSetup(centre: .zero, chargeMass: 100, elasticShare: share, cellSize: 0.15)
        let engine = try HalfSpaceGroundShock(spec: spec, setup: setup)
        let empty = [(overpressure: Float, peak: Float, impulse: Float)?](
            repeating: nil, count: engine.grid.radialCells)
        var t = 0.0
        while t < 0.03 {
            t += 1e-3
            engine.consume(rings: empty, time: t)
        }
        let energy = Double(share) * 100 * 4.184e6
        #expect(abs(engine.stepper.work / energy - 1) < 0.35, "work \(engine.stepper.work) against \(energy)")
        // It reaches the point, sideways and down.
        #expect(engine.peakResultant[0] > 0 && engine.peakOutwards[0] > 0)
    }

    @Test("Soil that yields takes the crater's share by default, and keeps every wave within its cone")
    func yielding() throws {
        var spec = GroundShockSpec()
        spec.model = .halfspace
        spec.profile = SoilProfile(
            layers: [
                SoilLayer(
                    thickness: 1, density: 1900, waveSpeed: 488, unloadingWaveSpeed: 976, frictionAngle: 35)
            ])
        spec.points = [SIMD2(10, 0)]
        spec.depths = [0.5]
        let setup = HalfSpaceSetup(centre: .zero, chargeMass: 10, cellSize: 0.2)
        let engine = try HalfSpaceGroundShock(spec: spec, setup: setup)
        // The default share is the yielding one, and the layer reaches the grid as it should: K₀
        // from Jaky, unloading at twice the loading speed.
        let energy = try #require(engine.crater?.energy)
        #expect(abs(energy / (Double(DirectInducedSource.defaultYieldingShare) * 10 * 4.184e6) - 1) < 1e-6)
        let layer = engine.grid.layers[0]
        #expect(layer.frictionAngle == 35 && layer.unloadingPWaveSpeed == 976)
        #expect(abs(layer.restingRatio - (1 - sin(35 * Double.pi / 180))) < 1e-6)
        // The source alone: the yielding takes most of its work, never more, and the cone holds.
        let empty = [(overpressure: Float, peak: Float, impulse: Float)?](
            repeating: nil, count: engine.grid.radialCells)
        var t = 0.0
        var worst = -Double.infinity
        while t < 0.05 {
            t += 1e-3
            engine.consume(rings: empty, time: t)
            worst = max(worst, engine.stepper.coneExcess())
        }
        let (loss, work) = (engine.stepper.yieldingLoss, engine.stepper.work)
        #expect(loss > 0.5 * work && loss < work, "yielding took \(loss) J of \(work) J")
        #expect(worst < 0.01)
        #expect(engine.peakResultant[0] > 0)
        // Elastic soil keeps the elastic default.
        spec.profile = sand
        let elastic = try HalfSpaceGroundShock(spec: spec, setup: setup)
        #expect(
            abs(elastic.crater!.energy / (Double(DirectInducedSource.defaultElasticShare) * 10 * 4.184e6) - 1)
                < 1e-6)
    }

    @Test("The consumer drives the half-space, which under a load everywhere at once is the plane wave")
    func consumer() throws {
        var spec = GroundShockSpec()
        spec.model = .halfspace
        spec.profile = sand
        spec.points = [SIMD2(42, 32)]
        spec.depths = [0, 1]
        spec.halfSpace = HalfSpaceSetup(
            centre: SIMD2(32, 32), chargeMass: 100, elasticShare: 0, cellSize: 0.25)
        var consumer = GroundShockConsumer(spec: spec)
        // 80 kPa everywhere at once from 2 ms, falling to nothing over 8 ms, framed each millisecond.
        let (peak, duration) = (80e3, 0.008)
        for frame in 0...20 {
            let t = Double(frame) * 1e-3
            let s = min(max(t - 0.002, 0), duration)
            let p = t < 0.002 ? 0 : peak * (1 - s / duration)
            let impulse = peak * (s - s * s / (2 * duration))
            let cells = Array(
                repeating: [Float(p), t < 0.002 ? 0 : Float(peak), Float(impulse)], count: 64 * 64)
            consumer.consume(
                GroundSlice(
                    time: t, cellSize: 1, grid: SIMD3(64, 64, 8), first: .zero, counts: SIMD2(64, 64),
                    values: cells.flatMap { $0 }, ambientDensity: 1.225, ambientPressure: 101_325, gamma: 1.4)
            )
        }
        let result = consumer.result(frameInterval: 1e-3)
        #expect(result.model == .halfspace && result.profile == sand)
        let point = try #require(result.points.first)
        // The plane wave p/(ρc_P), shaved by the load's averaging window over w/(2t_d).
        let window = HalfSpaceGroundShock.windowSteps
        let engine = try HalfSpaceGroundShock(spec: spec, setup: spec.halfSpace!)
        let shaved = 1 - window * engine.grid.timeStep / (2 * duration)
        let plane = Float(shaved * peak / (1900 * 488))
        for response in point.responses {
            #expect(
                abs(response.verticalVelocity / plane - 1) < 0.05,
                "\(response.verticalVelocity) against \(plane)")
            #expect((response.horizontalVelocity ?? 1) < 0.05 * plane)
            #expect(response.history?.count == 21)
        }
        #expect(result.summary.contains("a half-space of 1 layer"))
    }
}
