import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// A ground slice of `nx` by `ny` cells from the grid's corner, every cell the same.
private func uniformSlice(
    time: Double, overpressure: Float, peak: Float, impulse: Float, nx: Int32 = 4, ny: Int32 = 4,
    cellSize: Float = 1
) -> GroundSlice {
    GroundSlice(
        time: time, cellSize: cellSize, grid: SIMD3(nx, ny, 4), first: .zero, counts: SIMD2(nx, ny),
        values: Array(repeating: [overpressure, peak, impulse], count: Int(nx * ny)).flatMap { $0 },
        ambientDensity: 1.225, ambientPressure: 101_325, gamma: 1.4)
}

/// A column of linear elastic soil, `depth` deep in cells of `dz`, its top pressed by `load`
/// from time zero: velocities on the nodes, stresses between them, leapfrogged at half the
/// stable step. Returns, at the node `at` metres down, the peak downward velocity, when it came,
/// and the displacement at `until`.
private func elasticColumn(
    soil: GroundSoil, depth: Float, dz: Float, at: Float, until: Double, load: (Double) -> Float
) -> (peak: Float, time: Double, displacement: Float) {
    let rho = soil.density
    let modulus = soil.density * soil.waveSpeed * soil.waveSpeed
    let n = Int(depth / dz)
    let probe = Int((at / dz).rounded())
    let dt = Double(0.5 * dz / soil.waveSpeed)
    var velocity = [Float](repeating: 0, count: n + 1)
    // Compression positive, between node i and i + 1.
    var stress = [Float](repeating: 0, count: n)
    var peak: Float = 0
    var peakTime = 0.0
    var displacement: Float = 0
    var t = 0.0
    while t < until {
        let surface = load(t + dt / 2)
        velocity[0] += Float(dt) * (surface - stress[0]) / (rho * dz / 2)
        for i in 1..<n { velocity[i] += Float(dt) * (stress[i - 1] - stress[i]) / (rho * dz) }
        for i in 0..<n { stress[i] -= Float(dt) * modulus * (velocity[i + 1] - velocity[i]) / dz }
        t += dt
        displacement += Float(dt) * velocity[probe]
        if velocity[probe] > peak {
            peak = velocity[probe]
            peakTime = t
        }
    }
    return (peak, peakTime, displacement)
}

@Suite("Ground shock")
struct GroundShockTests {
    @Test("The response is the plane-wave relation, shaved with depth by 1/(1 + z/(c t_d))")
    func response() {
        let soil = GroundSoil(density: 1600, waveSpeed: 300)
        // 100 kPa and 200 Pa·s on the ground: a 4 ms triangle, 1.2 m long in the soil.
        let speed = AirInducedGroundShock.frontSpeed(
            overpressure: 100e3, ambientPressure: 101_325, ambientDensity: 1.225, gamma: 1.4)
        #expect(abs(speed - 462.341) < 0.01)
        let surface = AirInducedGroundShock.response(
            peak: 100e3, impulse: 200, arrival: 0.01, depth: 0, soil: soil, frontSpeed: speed)
        #expect(surface.stress == 100e3)
        #expect(abs(surface.verticalVelocity - 0.208333) < 1e-6)
        #expect(abs(surface.verticalDisplacement - 4.16667e-4) < 1e-9)
        #expect(abs((surface.horizontalVelocity ?? 0) - 0.177661) < 1e-5)
        #expect(surface.arrival == 0.01)
        // A pulse length down: half the stress and velocity, the same displacement, 4 ms later.
        let deep = AirInducedGroundShock.response(
            peak: 100e3, impulse: 200, arrival: 0.01, depth: 1.2, soil: soil, frontSpeed: speed)
        #expect(abs(deep.stress - 50e3) < 0.5 && abs(deep.verticalVelocity - 0.104167) < 1e-6)
        #expect(deep.verticalDisplacement == surface.verticalDisplacement)
        #expect(abs(deep.arrival! - 0.014) < 1e-9)
        // A weak front runs at the speed of sound. One slower than stiff soil is outrun, and one
        // only a little faster stands too steeply: neither has a horizontal estimate.
        let weak = AirInducedGroundShock.frontSpeed(
            overpressure: 0, ambientPressure: 101_325, ambientDensity: 1.225, gamma: 1.4)
        #expect(abs(weak - 340.294) < 0.01)
        let rock = AirInducedGroundShock.response(
            peak: 100e3, impulse: 200, arrival: 0.01, depth: 0,
            soil: GroundSoil(density: 2600, waveSpeed: 3000),
            frontSpeed: speed)
        #expect(rock.horizontalVelocity == nil && abs(rock.verticalVelocity - 100e3 / 7.8e6) < 1e-9)
        #expect(GroundShockRegime(frontSpeed: speed, soil: GroundSoil(waveSpeed: 3000)) == .outrunning)
        let steep = GroundSoil(waveSpeed: 400)
        #expect(GroundShockRegime(frontSpeed: speed, soil: steep) == .transseismic)
        #expect(
            AirInducedGroundShock.response(
                peak: 100e3, impulse: 200, arrival: 0.01, depth: 0, soil: steep, frontSpeed: speed
            ).horizontalVelocity == nil)
        // At √2 c, 45°: as fast outwards as down.
        let edge = AirInducedGroundShock.response(
            peak: 100e3, impulse: 200, arrival: 0.01, depth: 0, soil: soil,
            frontSpeed: 300 * Float(2).squareRoot())
        #expect(abs(edge.horizontalVelocity! / edge.verticalVelocity - 1) < 1e-5)
        // No blast, no response.
        let none = AirInducedGroundShock.response(
            peak: 0, impulse: 0, arrival: nil, depth: 1, soil: soil, frontSpeed: weak)
        #expect(none.verticalVelocity == 0 && none.verticalDisplacement == 0 && none.arrival == nil)
    }

    @Test("An elastic soil column pressed by a pulse moves as the plane-wave relation says")
    func elasticPulse() {
        let soil = GroundSoil(density: 1600, waveSpeed: 300)
        // A smooth 4 ms pulse, 100 kPa at its peak: 200 Pa·s.
        let peak: Float = 100e3
        let duration = 0.004
        let load = { (t: Double) -> Float in
            t < duration ? peak * Float(pow(sin(.pi * t / duration), 2)) : 0
        }
        let impulse = peak * Float(duration) / 2
        let model = { (depth: Float) in
            AirInducedGroundShock.response(
                peak: peak, impulse: impulse, arrival: 0, depth: depth, soil: soil, frontSpeed: 1000)
        }
        // The wave reaches 3 m in 10 ms and has passed by 15; it comes back from 10 m at 57 ms.
        let top = elasticColumn(soil: soil, depth: 10, dz: 0.01, at: 0, until: 0.02, load: load)
        let below = elasticColumn(soil: soil, depth: 10, dz: 0.01, at: 3, until: 0.02, load: load)
        for column in [top, below] {
            #expect(abs(column.peak / model(0).verticalVelocity - 1) < 0.005)
            #expect(abs(column.displacement / model(3).verticalDisplacement - 1) < 0.005)
        }
        // The peak arrives z/c later, as the model's arrival says.
        let delay = model(3).arrival! - model(0).arrival!
        #expect(abs((below.time - top.time) - delay) < 5e-5)
    }

    @Test("A ground slice gives back the solver's ground, solid cells left out")
    func slice() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let scenario = Scenario(
            name: "Ground", domainSize: SIMD3(8, 8, 4), boxes: [Box(x: 4...6, y: 4...6, height: 2)],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)))
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        // Pressure rising along x on the ground; peak and impulse rising along y.
        solver.mutateState { cells in
            for j in 0..<16 {
                for i in 0..<16 {
                    cells[solver.grid.index(i, j, 0)] = CellState(
                        Primitive(density: 1.225, pressure: 101_325 + Float(i) * 1000), gamma: 1.4)
                }
            }
        }
        solver.setFields { peak, impulse in
            for j in 0..<16 {
                for i in 0..<16 {
                    peak[solver.grid.index(i, j, 0)] = 5000 + Float(j) * 100
                    impulse[solver.grid.index(i, j, 0)] = 10 + Float(j)
                }
            }
        }
        let slice = solver.groundSlice(low: SIMD2(1, 1), high: SIMD2(7, 7))
        #expect(slice.first == SIMD2(2, 2) && slice.counts == SIMD2(13, 13))
        // Halfway between cells 3 and 4 along x (centres 1.75 and 2.25 m), on cell 5 along y.
        let open = try #require(slice.sample(SIMD2(2, 2.75)))
        #expect(abs(open.overpressure - 3500) < 1 && open.peak == 5500 && open.impulse == 15)
        #expect(slice.sample(SIMD2(5, 5)) == nil, "Under the block there is no open ground.")
        // Beside the block, its open neighbours alone.
        let edge = try #require(slice.sample(SIMD2(4, 5)))
        #expect(abs(edge.overpressure - 7000) < 1)
        // Beyond the slice but within the grid: unknown.
        #expect(slice.sample(SIMD2(0.2, 3)) == nil)
        let restored = try GroundSlice(header: slice.header, payload: slice.payload)
        #expect(restored.header == slice.header)
        #expect(zip(restored.values, slice.values).allSatisfy { $0 == $1 || ($0.isNaN && $1.isNaN) })
        #expect(throws: CocoaError.self) {
            try GroundSlice(header: slice.header, payload: slice.payload.dropLast(4))
        }
    }

    @Test("The consumer keeps each point's history, peak and arrival, and finds covered points")
    func consumer() throws {
        var spec = GroundShockSpec()
        spec.points = [SIMD2(1.5, 1.5)]
        spec.line = .init(from: SIMD2(0.5, 2.5), to: SIMD2(3.5, 2.5), count: 4)
        spec.depths = [0, 2]
        spec.arrivalThreshold = 1000
        #expect(spec.allPoints.count == 5 && spec.allPoints[2] == SIMD2(1.5, 2.5))
        var consumer = GroundShockConsumer(spec: spec)
        let region = consumer.region(cellSize: 1)
        #expect(region.low == SIMD2(-0.5, 0.5) && region.high == SIMD2(4.5, 3.5))
        consumer.consume(uniformSlice(time: 0, overpressure: 0, peak: 0, impulse: 0))
        consumer.consume(uniformSlice(time: 0.001, overpressure: 400, peak: 600, impulse: 0.1))
        // From frame 2 a block stands round the line's last point, (3.5, 2.5): cells 2 and 3
        // along each axis.
        func blocked(_ slice: GroundSlice) -> GroundSlice {
            var slice = slice
            for (i, j) in [(2, 2), (3, 2), (2, 3), (3, 3)] { slice.values[3 * (i + 4 * j)] = .nan }
            return slice
        }
        let hit = blocked(uniformSlice(time: 0.002, overpressure: 30e3, peak: 50e3, impulse: 20))
        consumer.consume(hit)
        consumer.consume(blocked(uniformSlice(time: 0.003, overpressure: -2e3, peak: 50e3, impulse: 40)))
        let result = consumer.result(frameInterval: 0.001)
        #expect(result.frames == 4 && result.points.count == 5 && consumer.bytes == 4 * 4 * 48)
        let first = result.points[0]
        #expect(first.history == [0, 400, 30e3, -2e3] && first.arrival == 0.002)
        #expect(first.peakOverpressure == 50e3 && first.impulse == 40 && abs(first.duration - 0.0016) < 1e-9)
        #expect(!first.covered && first.regime == .transseismic && first.responses.map(\.depth) == [0, 2])
        let expected = AirInducedGroundShock.response(
            peak: 50e3, impulse: 40, arrival: 0.002, depth: 2, soil: spec.soil, frontSpeed: first.frontSpeed)
        #expect(first.responses[1] == expected)
        // 50 kPa runs at 405 m/s, short of √2 × 300: no horizontal estimate.
        #expect(first.responses.allSatisfy { $0.horizontalVelocity == nil })
        // The blocked point keeps what it saw while open; one never open is covered.
        let last = result.points[4]
        #expect(!last.covered && last.peakOverpressure == 600 && last.arrival == nil)
        #expect(last.history == [0, 400, 0, 0])
        var never = GroundShockConsumer(spec: spec)
        never.consume(hit)
        let covered = never.result(frameInterval: 0.001).points[4]
        #expect(covered.covered && covered.responses[0].verticalVelocity == 0 && covered.history == [0])
        // A blast laid down at time zero is over the point before the solver keeps a peak.
        var laid = GroundShockConsumer(spec: spec)
        laid.consume(uniformSlice(time: 0, overpressure: 2000, peak: 0, impulse: 0))
        laid.consume(uniformSlice(time: 0.001, overpressure: 500, peak: 1500, impulse: 1))
        let early = laid.result(frameInterval: 0.001).points[0]
        #expect(early.peakOverpressure == 2000 && early.arrival == 0)
        // Through JSON and back, as `--ground-results` writes it.
        let decoded = try JSONDecoder().decode(GroundShockResult.self, from: JSONEncoder().encode(result))
        #expect(decoded == result)
        #expect(result.summary.contains("5 points") && !never.result(frameInterval: 0.001).summary.isEmpty)
    }

    @Test("The column consumer drives a soil column under each point through the frames")
    func columnConsumer() throws {
        var spec = GroundShockSpec()
        spec.model = .column
        spec.points = [SIMD2(1.5, 1.5)]
        spec.depths = [0, 1, 3]
        try spec.validate()
        // A triangle arriving at 2.5 ms: 100 kPa falling to nothing over 4 ms, framed each
        // millisecond with the peak and impulse kept between frames, on cells of 5 cm, which the
        // shock crosses in 0.1 ms.
        let (arrival, peak, duration) = (0.0025, 100e3, 0.004)
        func pressure(_ t: Double) -> Double {
            let s = t - arrival
            return s < 0 || s > duration ? 0 : peak * (1 - s / duration)
        }
        func positive(_ t: Double) -> Double {
            let s = min(max(t - arrival, 0), duration)
            return peak * (s - s * s / (2 * duration))
        }
        var consumer = GroundShockConsumer(spec: spec)
        for frame in 0...40 {
            let t = Double(frame) * 1e-3
            consumer.consume(
                uniformSlice(
                    time: t, overpressure: Float(pressure(t)), peak: t >= arrival ? Float(peak) : 0,
                    impulse: Float(positive(t)), nx: 64, ny: 64, cellSize: 0.05))
        }
        let result = consumer.result(frameInterval: 1e-3)
        #expect(result.model == .column && result.profile == spec.columnProfile)
        let point = try #require(result.points.first)
        let profile = try #require(point.profile)
        #expect(profile.depths.count == GroundDepthProfile.levels && profile.depths.last == 3)
        // Elastic uniform soil: the plane-wave relation at every depth, as the estimate gives at
        // the surface; the impulse over ρc sinks every depth.
        let soil = spec.soil
        for response in point.responses {
            #expect(abs(response.verticalVelocity / (Float(peak) / soil.impedance) - 1) < 0.03)
            #expect(abs(response.stress / Float(peak) - 1) < 0.03)
            #expect(
                abs(response.verticalDisplacement / (Float(peak * duration / 2) / soil.impedance) - 1) < 0.01)
            #expect(response.history?.count == 41)
            let expected = arrival + Double(response.depth) / 300
            #expect(abs(response.arrival! - expected) < 2e-4 || response.depth == 0)
        }
        #expect(point.surfaceVelocity(in: soil) == profile.velocity[0])
        // Below the surface the estimate wears the peak down; the elastic column does not.
        let estimate = AirInducedGroundShock.response(
            peak: Float(peak), impulse: Float(peak * duration / 2), arrival: arrival, depth: 3, soil: soil,
            frontSpeed: point.frontSpeed)
        #expect(estimate.verticalVelocity < 0.5 * point.responses[2].verticalVelocity)
        let decoded = try JSONDecoder().decode(GroundShockResult.self, from: JSONEncoder().encode(result))
        #expect(decoded == result && result.summary.contains("column of 1 layer"))

        // Bilinear soil sends less down, and leaves the ground lower once the wave has gone.
        spec.profile = SoilProfile(
            layers: [SoilLayer(thickness: 2, density: 1600, waveSpeed: 300, unloadingWaveSpeed: 600)])
        var soft = GroundShockConsumer(spec: spec)
        for frame in 0...40 {
            let t = Double(frame) * 1e-3
            soft.consume(
                uniformSlice(
                    time: t, overpressure: Float(pressure(t)), peak: t >= arrival ? Float(peak) : 0,
                    impulse: Float(positive(t)), nx: 64, ny: 64, cellSize: 0.05))
        }
        let worn = try #require(soft.result(frameInterval: 1e-3).points.first)
        let surface = { (t: Double) in pressure(t + arrival) }
        let exact = HystereticAttenuation.peakStress(
            depth: 3, loadingSpeed: 300, unloadingSpeed: 600, surface: surface)
        #expect(abs(Double(worn.responses[2].stress) / exact - 1) < 0.06)
        #expect(worn.responses[0].residualDisplacement! > 0.5 * worn.responses[0].verticalDisplacement)
    }

    @Test("Descriptions and results saved before the column read back as the estimate")
    func olderFiles() throws {
        let spec = try JSONDecoder().decode(GroundShockSpec.self, from: Data(#"{"points": [[1, 2]]}"#.utf8))
        #expect(spec.model == .estimate && spec.profile == nil)
        let json = #"""
            {"soil": {"density": 1600, "waveSpeed": 300}, "depths": [0], "frameInterval": 0.001, "frames": 1,
             "airBytes": 0, "seconds": 0, "points": [{"position": [1, 2], "covered": false,
             "peakOverpressure": 1000, "impulse": 1, "duration": 0.002, "frontSpeed": 340, "regime": "outrunning",
             "history": [], "responses": [{"depth": 0, "stress": 1000, "verticalVelocity": 0.002,
             "verticalDisplacement": 0.000002}]}]}
            """#
        let result = try JSONDecoder().decode(GroundShockResult.self, from: Data(json.utf8))
        #expect(
            result.model == nil && result.points[0].profile == nil
                && result.points[0].responses[0].history == nil)
        var column = spec
        column.model = .column
        column.profile = SoilProfile(layers: [
            SoilLayer(thickness: 1, density: 1600, waveSpeed: 300, damping: 2)
        ])
        #expect(throws: CocoaError.self) { try column.validate() }
        column.profile = SoilProfile(
            layers: [SoilLayer(thickness: 1, density: 1600, waveSpeed: 300)], timeStep: 1e-7)
        #expect(throws: CocoaError.self) { try column.validate() }
    }

    @Test("Descriptions take defaults for fields left out and refuse what is out of range")
    func spec() throws {
        let json = #"{"points": [[10, 20]], "soil": {"density": 1900, "waveSpeed": 450}}"#
        let spec = try JSONDecoder().decode(GroundShockSpec.self, from: Data(json.utf8))
        #expect(spec.points == [SIMD2(10, 20)] && spec.soil.waveSpeed == 450 && spec.depths == [0, 1, 3])
        try spec.validate(domain: SIMD3(64, 64, 32))
        let partial = try JSONDecoder().decode(
            GroundShockSpec.self, from: Data(#"{"soil": {"waveSpeed": 1500}}"#.utf8))
        #expect(partial.soil == GroundSoil(density: 1600, waveSpeed: 1500) && partial.points.isEmpty)
        #expect(throws: CocoaError.self) { try spec.validate(domain: SIMD3(8, 8, 8)) }
        for change in [
            { (s: inout GroundShockSpec) in s.points = [] },
            { $0.soil.waveSpeed = 0 },
            { $0.depths = [-1] },
            { $0.depths = [] },
            { $0.line = .init(from: .zero, to: .one, count: 1) },
            { $0.arrivalThreshold = .nan },
        ] {
            var bad = spec
            change(&bad)
            #expect(throws: CocoaError.self) { try bad.validate() }
        }
    }
}
