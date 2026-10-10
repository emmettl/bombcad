import Foundation
import Testing

@testable import BlastCore

/// A smooth pulse, sin² over `duration` from time zero, `peak` Pa at its middle: its integral
/// from zero to t, Pa·s.
private func sineSquaredIntegral(_ t: Double, peak: Double, duration: Double) -> Double {
    let s = min(max(t, 0), duration)
    return peak * (s / 2 - duration / (4 * .pi) * sin(2 * .pi * s / duration))
}

/// A triangle falling from `peak` at time zero to nothing at `duration`: its integral to t.
private func triangleIntegral(_ t: Double, peak: Double, duration: Double) -> Double {
    let s = min(max(t, 0), duration)
    return peak * (s - s * s / (2 * duration))
}

/// Runs the column to `until`, pressed by the load whose integral from zero is `integral`, and
/// calls `watch` after each step.
private func run(
    _ column: inout SoilColumn, until: Double, integral: (Double) -> Double,
    watch: (SoilColumn) -> Void = { _ in }
) {
    let dt = column.timeStep
    while column.time < until {
        let t = column.time
        column.step(load: (integral(t + dt / 2) - integral(t - dt / 2)) / dt)
        watch(column)
    }
}

/// The index of the element whose mid-depth is nearest `depth`.
private func element(_ column: SoilColumn, at depth: Double) -> Int {
    column.elementDepths.indices.min {
        abs(column.elementDepths[$0] - depth) < abs(column.elementDepths[$1] - depth)
    }!
}

private func node(_ column: SoilColumn, at depth: Double) -> Int {
    column.depths.indices.min { abs(column.depths[$0] - depth) < abs(column.depths[$1] - depth) }!
}

@Suite("Soil column")
struct SoilColumnTests {
    let dry = GroundSoil(density: 1600, waveSpeed: 300)

    @Test(
        "A uniform elastic column carries the pulse down unchanged, as the closed-form wave and the estimate say"
    )
    func uniform() {
        let (peak, duration) = (100e3, 0.004)
        var column = SoilColumn(profile: SoilProfile(uniform: dry), depth: 5)
        // An elastic undamped layer runs at a Courant number of one.
        let courant = column.timeStep * 300 / (column.depths[1] - column.depths[0])
        #expect(courant <= 1 && courant > 1 - 1e-9)
        let probe = node(column, at: 3)
        let z = column.depths[probe]
        var worst = 0.0
        let pulse = { (t: Double) in sineSquaredIntegral(t, peak: peak, duration: duration) }
        run(&column, until: 0.05, integral: pulse) { column in
            // d'Alembert: v(z, t) = p(t − z/c)/(ρc), the velocity half a step behind.
            let t = column.time - column.timeStep / 2 - z / 300
            let exact = t > 0 && t < duration ? peak * pow(sin(.pi * t / duration), 2) / (1600 * 300) : 0
            worst = max(worst, abs(column.velocities[probe] - exact))
        }
        let impedance = 1600.0 * 300
        #expect(worst < 0.01 * peak / impedance)
        // The manuals' estimate at the surface: v = P/(ρc), d = I/(ρc), here at every depth.
        let estimate = AirInducedGroundShock.response(
            peak: Float(peak), impulse: Float(peak * duration / 2), arrival: 0, depth: 0, soil: dry,
            frontSpeed: 1000)
        for depth in [0.0, 1, 3] {
            let n = node(column, at: depth)
            #expect(abs(column.peakVelocity[n] / Double(estimate.verticalVelocity) - 1) < 0.005)
            #expect(abs(column.peakDisplacement[n] / Double(estimate.verticalDisplacement) - 1) < 0.005)
            #expect(abs(column.peakStress[element(column, at: depth + 0.1)] / peak - 1) < 0.005)
        }
        // The wave has gone into the half-space below, taking all the work with it:
        // ∫p²/(ρc) dt for a half-space's surface.
        let work = 3 * peak * peak * duration / 8 / impedance
        #expect(abs(column.work / work - 1) < 0.002)
        #expect(abs(column.radiated / column.work - 1) < 0.002)
    }

    @Test("Two layers send back and pass on the analytical shares of the stress")
    func twoLayers() {
        let (peak, duration) = (100e3, 0.004)
        // Soft over stiff, then stiff over soft, each lower layer going on for ever.
        for (upper, lower) in [((1600.0, 300.0), (1900.0, 900.0)), ((1900.0, 900.0), (1600.0, 300.0))] {
            let profile = SoilProfile(
                layers: [
                    SoilLayer(thickness: 6, density: Float(upper.0), waveSpeed: Float(upper.1)),
                    SoilLayer(thickness: 20, density: Float(lower.0), waveSpeed: Float(lower.1)),
                ],
                base: .halfSpace(density: Float(lower.0), waveSpeed: Float(lower.1)))
            var column = SoilColumn(profile: profile, depth: 10)
            let (z1, z2) = (upper.0 * upper.1, lower.0 * lower.1)
            let reflected = (z2 - z1) / (z2 + z1)
            let transmitted = 2 * z2 / (z1 + z2)
            // Up in the top layer, the reflection comes back after the incident pulse has gone
            // by; down in the lower one, only the transmitted pulse goes by.
            let top = element(column, at: 2)
            let deep = element(column, at: 6 + 3 * lower.1 / 300)
            let back = (2 * 6 - column.elementDepths[top]) / upper.1
            var echo = 0.0
            var through = 0.0
            let past = max(back, 6 / upper.1 + 3 / 300) + duration * 1.5
            let pulse = { (t: Double) in sineSquaredIntegral(t, peak: peak, duration: duration) }
            run(&column, until: past, integral: pulse) { column in
                let stress = column.stresses
                if column.time > back - duration * 0.5, column.time < back + duration * 1.5 {
                    echo = abs(stress[top]) > abs(echo) ? stress[top] : echo
                }
                through = max(through, stress[deep])
            }
            #expect(abs(echo / peak - reflected) < 0.01, "reflected \(echo / peak) against \(reflected)")
            #expect(
                abs(through / peak - transmitted) < 0.01,
                "transmitted \(through / peak) against \(transmitted)")
        }
    }

    @Test("A layer over a stiff base rings at a quarter wavelength, c/4H")
    func resonance() {
        // 10 m of soil at 300 m/s: 7.5 Hz. Over rock held still, over a half-space eight times as
        // stiff, and for a shear wave of 150 m/s (the same equation, G = ρVs²): 3.75 Hz.
        let cases: [(speed: Float, base: SoilBase)] = [
            (300, .rigid), (300, .halfSpace(density: 2400, waveSpeed: 1600)), (150, .rigid),
        ]
        for (speed, base) in cases {
            let profile = SoilProfile(
                layers: [SoilLayer(thickness: 10, density: 1600, waveSpeed: speed, damping: 0.02)],
                base: base,
                dampingFrequencies: SIMD2(2, 20), timeStep: 4e-4)
            var column = SoilColumn(profile: profile, depth: 3)
            var history: [Double] = []
            var steps = 0
            let knock = { (t: Double) in triangleIntegral(t, peak: 10e3, duration: 0.004) }
            run(&column, until: 2, integral: knock) {
                steps += 1
                if steps % 5 == 0 { history.append($0.velocities[0]) }
            }
            // The surface's velocity, its spectrum's highest peak: where the wave sent back from
            // the base meets the next going down in phase. (The displacement's peak, the
            // velocity's over ω, lies a little lower where the base takes much of the wave away.)
            let dt = column.timeStep * 5
            let frequencies = Array(
                stride(from: 0.4 * Double(speed) / 40, through: 1.6 * Double(speed) / 40, by: 0.01))
            let power = frequencies.map { f -> Double in
                var (re, im) = (0.0, 0.0)
                for (n, u) in history.enumerated() {
                    let phase = 2 * .pi * f * Double(n) * dt
                    re += u * cos(phase)
                    im += u * sin(phase)
                }
                return re * re + im * im
            }
            let found = frequencies[power.indices.max { power[$0] < power[$1] }!]
            let expected = Double(speed) / 40
            #expect(abs(found / expected - 1) < 0.01, "resonance \(found) Hz against \(expected)")
        }
    }

    @Test("Bilinear soil wears the peak down as the characteristics say, converging as the step shrinks")
    func hysteretic() {
        let (peak, duration) = (100e3, 0.004)
        let surface = { (t: Double) in t >= 0 && t <= duration ? peak * (1 - t / duration) : 0 }
        for ratio in [2.0, 3.0] {
            var errors: [Double] = []
            for step in [4e-4, 2e-4, 1e-4, 5e-5, 2.5e-5] {
                let profile = SoilProfile(
                    layers: [
                        SoilLayer(
                            thickness: 1, density: 1600, waveSpeed: 300,
                            unloadingWaveSpeed: Float(300 * ratio))
                    ],
                    timeStep: Float(step))
                var column = SoilColumn(profile: profile, depth: 5)
                run(&column, until: 0.03, integral: { triangleIntegral($0, peak: peak, duration: duration) })
                var worst = 0.0
                for depth in [0.5, 1.2, 3, 5] {
                    let e = element(column, at: depth)
                    let exact = HystereticAttenuation.peakStress(
                        depth: column.elementDepths[e], loadingSpeed: 300, unloadingSpeed: 300 * ratio,
                        surface: surface)
                    worst = max(worst, abs(column.peakStress[e] / exact - 1))
                }
                errors.append(worst)
            }
            // First order, the loading front a jump the grid smears: within 8% at 5e-5 s, 3% at
            // 2.5e-5 s.
            #expect(errors[3] < 0.08 && errors[4] < 0.03, "ratio \(ratio): errors \(errors)")
            #expect(errors[4] < errors[0] / 4, "ratio \(ratio): errors \(errors)")
        }
        // Closed form: a straight line down to c t_d r/(r − 1), P/2 at c t_d for stiff unloading,
        // where the manuals' 1/(1 + z/(c t_d)) is too.
        let r = 10.0
        let line = HystereticAttenuation.peakStress(
            depth: 0.6, loadingSpeed: 300, unloadingSpeed: 300 * r, surface: surface)
        #expect(abs(line / peak - (1 - 0.6 * (1 - 1 / (r * r)) / (2 * 300 * duration))) < 1e-9)
        let length = HystereticAttenuation.peakStress(
            depth: 1.2, loadingSpeed: 300, unloadingSpeed: 300 * r, surface: surface)
        let manual = AirInducedGroundShock.attenuation(depth: 1.2, soil: dry, duration: Float(duration))
        #expect(abs(length / peak - Double(manual)) < 0.01)
        // Far down, as 1/z with a ripple: for r = 2, k = 1/3, three times as deep, a third the stress.
        let far = (
            HystereticAttenuation.peakStress(
                depth: 20, loadingSpeed: 300, unloadingSpeed: 600, surface: surface),
            HystereticAttenuation.peakStress(
                depth: 60, loadingSpeed: 300, unloadingSpeed: 600, surface: surface)
        )
        #expect(abs(far.1 / far.0 - 1.0 / 3) < 1e-9)
    }

    @Test("The energy balances, and damping and hysteresis take what the analysis says")
    func energy() {
        let (peak, duration) = (100e3, 0.004)
        let integral = { (t: Double) in triangleIntegral(t, peak: peak, duration: duration) }
        // Layered, hysteretic and damped together: the scheme's own identity, to rounding.
        let mixed = SoilProfile(
            layers: [
                SoilLayer(
                    thickness: 2, density: 1600, waveSpeed: 300, unloadingWaveSpeed: 600, damping: 0.05),
                SoilLayer(thickness: 3, density: 1900, waveSpeed: 800, damping: 0.02),
            ], base: .halfSpace(density: 2200, waveSpeed: 1500))
        var column = SoilColumn(profile: mixed, depth: 5)
        run(&column, until: 0.05, integral: integral) { column in
            let held = column.kineticEnergy + column.strainWork + column.damped + column.radiated
            #expect(abs(held - column.work) <= 1e-9 * column.work + 1e-12)
        }
        #expect(column.damped > 0 && column.radiated > 0 && column.hystereticLoss > 0)

        // Damped soil over rock: once still, everything the load put in was damped.
        let damped = SoilProfile(
            layers: [SoilLayer(thickness: 5, density: 1600, waveSpeed: 300, damping: 0.05)], base: .rigid,
            dampingFrequencies: SIMD2(5, 50), timeStep: 2e-4)
        var ringing = SoilColumn(profile: damped, depth: 5)
        run(&ringing, until: 3, integral: integral)
        #expect(ringing.kineticEnergy + ringing.recoverableEnergy < 1e-3 * ringing.work)
        #expect(abs(ringing.damped / ringing.work - 1) < 1e-3)

        // Bilinear soil: each depth loses σ²(1/M − 1/M_u)/2 of the front's peak σ, all the way
        // down to where the run stops, the rest radiated. The column is long enough that the
        // front is still well inside it.
        let bilinear = SoilProfile(
            layers: [SoilLayer(thickness: 1, density: 1600, waveSpeed: 300, unloadingWaveSpeed: 600)],
            timeStep: 5e-5)
        var soft = SoilColumn(profile: bilinear, depth: 20)
        run(&soft, until: 0.05, integral: integral)
        let surface = { (t: Double) in t >= 0 && t <= duration ? peak * (1 - t / duration) : 0 }
        let compliance = (1 / (1600 * 300 * 300) - 1 / (1600 * 600 * 600.0)) / 2
        var lost = 0.0
        let dz = 0.005
        for z in stride(from: dz / 2, to: 300 * 0.05 - 1, by: dz) {
            let s = HystereticAttenuation.peakStress(
                depth: z, loadingSpeed: 300, unloadingSpeed: 600, surface: surface)
            lost += s * s * compliance * dz
        }
        #expect(abs(soft.hystereticLoss / lost - 1) < 0.05, "lost \(soft.hystereticLoss) against \(lost)")
    }

    @Test("The rebuilt load between frames keeps the solver's peak and impulse")
    func load() {
        // A Friedlander pulse arriving at 2.3 ms: 200 kPa, decaying over 3 ms.
        let (arrival, peak, positive) = (0.0023, 200e3, 0.003)
        func pressure(_ t: Double) -> Double {
            let s = t - arrival
            return s < 0 ? 0 : peak * (1 - s / positive) * exp(-s / positive)
        }
        // Frames a millisecond apart, each with the peak and positive impulse kept every 10 µs.
        var load = GroundLoad()
        // The same, the shock rising over 0.2 ms as the front crosses a cell.
        var rising = GroundLoad()
        var (kept, impulse) = (0.0, 0.0)
        var t = 0.0
        let fine = 1e-6
        var impulses: [Double] = []
        for frame in 0...20 {
            let time = Double(frame) * 1e-3
            while t < time - fine / 2 {
                let p = pressure(t + fine / 2)
                kept = max(kept, p)
                impulse += max(p, 0) * fine
                t += fine
            }
            load.append(
                time: time, overpressure: Float(pressure(time)), peak: Float(kept), impulse: Float(impulse))
            impulses.append(impulse)
            rising.append(
                time: time, overpressure: Float(pressure(time)), peak: Float(kept), impulse: Float(impulse),
                rise: 2e-4)
        }
        #expect(abs(rising.integral(from: 0, to: 0.005) / impulses[5] - 1) < 2e-3)
        #expect(rising.knots.map(\.pressure).max() == load.knots.map(\.pressure).max())
        // Through the positive phase, frame by frame, the solver's impulse.
        for frame in 3...5 {
            let rebuilt = load.integral(from: 0, to: Double(frame) * 1e-3)
            #expect(abs(rebuilt / impulses[frame] - 1) < 1e-4)
        }
        #expect(abs(load.knots.map(\.pressure).max()! / peak - 1) < 1e-3)
        // The column driven by the rebuilt load moves much as it does under the real one.
        let profile = SoilProfile(layers: [
            SoilLayer(thickness: 1, density: 1600, waveSpeed: 300, unloadingWaveSpeed: 600)
        ])
        var rebuilt = SoilColumn(profile: profile, depth: 3)
        rebuilt.advance(to: 0.02, load: load)
        var exact = SoilColumn(profile: profile, depth: 3)
        // ∫P(1 − s/T)e^(−s/T) ds = P s e^(−s/T).
        run(
            &exact, until: rebuilt.time - exact.timeStep / 2,
            integral: { t in t < arrival ? 0 : peak * (t - arrival) * exp(-(t - arrival) / positive) })
        for depth in [0.0, 1, 3] {
            let n = node(exact, at: depth)
            #expect(abs(rebuilt.peakVelocity[n] / exact.peakVelocity[n] - 1) < 0.06)
        }
        // Forgetting what the column has passed changes nothing ahead of it.
        var short = load
        short.forget(before: 0.0105)
        #expect(short.knots.count < load.knots.count)
        #expect(abs(short.integral(from: 0.011, to: 0.02) - load.integral(from: 0.011, to: 0.02)) < 1e-9)
    }

    @Test("Profiles decode with defaults and refuse what is out of range")
    func profile() throws {
        let json = #"""
            {"layers": [{"thickness": 2, "unloadingWaveSpeed": 600}, {"thickness": 5, "density": 2000, "waveSpeed": 900, "damping": 0.05}], "base": "rigid"}
            """#
        let profile = try JSONDecoder().decode(SoilProfile.self, from: Data(json.utf8))
        #expect(profile.layers[0].density == 1600 && profile.layers[0].unloadingSpeed == 600)
        #expect(profile.base == .rigid && profile.timeStep == SoilProfile.defaultTimeStep && profile.isValid)
        #expect(
            profile.waveSpeed(at: 1) == 300 && profile.waveSpeed(at: 3) == 900
                && profile.waveSpeed(at: 8) == nil)
        let again = try JSONDecoder().decode(SoilProfile.self, from: JSONEncoder().encode(profile))
        #expect(again == profile)
        let rock = try JSONDecoder().decode(
            SoilBase.self, from: Data(#"{"density": 2600, "waveSpeed": 2500}"#.utf8))
        #expect(rock == .halfSpace(density: 2600, waveSpeed: 2500))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SoilBase.self, from: Data(#""soft""#.utf8))
        }
        for change in [
            { (p: inout SoilProfile) in p.layers = [] },
            { $0.layers[0].unloadingWaveSpeed = 100 },
            { $0.layers[0].damping = 0.9 },
            { $0.layers[1].thickness = 0 },
            { $0.dampingFrequencies = SIMD2(50, 10) },
            { $0.timeStep = 0 },
            { $0.base = .halfSpace(density: 0, waveSpeed: 300) },
        ] {
            var bad = profile
            change(&bad)
            #expect(!bad.isValid)
        }
    }
}
