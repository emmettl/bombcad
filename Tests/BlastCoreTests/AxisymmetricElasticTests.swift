import Foundation
import Testing

@testable import BlastCore
@testable import BlastModel

/// Complex numbers, for the references' transforms.
private struct C {
    var re: Double
    var im: Double
    init(_ re: Double, _ im: Double = 0) {
        self.re = re
        self.im = im
    }
    static func + (a: C, b: C) -> C { C(a.re + b.re, a.im + b.im) }
    static func - (a: C, b: C) -> C { C(a.re - b.re, a.im - b.im) }
    static func * (a: C, b: C) -> C { C(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re) }
    static func * (a: Double, b: C) -> C { C(a * b.re, a * b.im) }
    static func / (a: C, b: C) -> C {
        let d = b.re * b.re + b.im * b.im
        return C((a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d)
    }
    var magnitude: Double { (re * re + im * im).squareRoot() }
    /// The root with a positive real part.
    var sqrt: C {
        let m = magnitude
        var r = C(((m + re) / 2).squareRoot(), (max(m - re, 0) / 2).squareRoot() * (im < 0 ? -1 : 1))
        if r.re < 0 { r = C(-r.re, -r.im) }
        return r
    }
    static func exp(_ a: C) -> C { Foundation.exp(a.re) * C(cos(a.im), sin(a.im)) }
}

/// A uniform Poisson solid: c_S 100 m/s, c_P √3 times it, 2,000 kg/m³.
private let poisson = AxisymmetricElasticGrid.Layer(
    thickness: 100, density: 2000, pWaveSpeed: 100 * 3.0.squareRoot(), sWaveSpeed: 100)

/// The smooth step that switches the loads on, 0 to 1 over `rise`: (1 − cos πt/rise)/2.
private func smoothStep(_ t: Double, rise: Double) -> Double {
    t <= 0 ? 0 : t >= rise ? 1 : (1 - cos(Double.pi * t / rise)) / 2
}

/// Lamb's problem for a disk of pressure p₀ and radius a switched on by the smooth step: the
/// downward velocity of the surface at radius r, by the exact transform solution in frequency
/// and wavenumber, summed by Bouchon's discrete wavenumber method with a complex frequency. With
/// k_S = ω/c_S, ν_P,S = √(k² − ω²/c²) and F = (2k² − k_S²)² − 4k²ν_Pν_S, the surface's
/// displacement under a surface pressure P(k) is W = −P k_S² ν_P/(μF) (Boussinesq's
/// F(1 − ν)/(2πμr) when static), and P(k) = p₀aJ₁(ka)/k for the disk.
private func lambVelocity(
    radius r: Double, times: [Double], disk a: Double, pressure p0: Double, rise: Double,
    layer: AxisymmetricElasticGrid.Layer, length: Double = 60, wavenumbers: Int = 1600,
    frequencyCount: Int = 1200
) -> [Double] {
    let (cp, cs, mu) = (layer.pWaveSpeed, layer.sWaveSpeed, layer.mu)
    let period = 0.5
    let omegaI = Double.pi / period
    let df = 1 / period
    let frequencies = (0..<frequencyCount).map { Double($0) * df }
    let dk = 2 * Double.pi / length
    let ks = (1...wavenumbers).map { Double($0) * dk }
    // The step's rate, sin over the rise, transformed: (π/2T)·a(1 + e^(−sT))/(s² + a²), s = iω.
    func rate(_ w: C) -> C {
        let aa = Double.pi / rise
        let s = C(0, 1) * w
        let num = (Double.pi / (2 * rise) * aa) * (C(1) + C.exp(C(-1) * s * C(rise)))
        return num / (s * s + C(aa * aa))
    }
    var spectrum: [C] = []
    for f in frequencies {
        let w = C(2 * Double.pi * f, -omegaI)
        let w2 = w * w
        let kS2 = w2 / C(cs * cs)
        let kP2 = w2 / C(cp * cp)
        var sum = C(0)
        for k in ks {
            let k2 = C(k * k)
            let nuP = (k2 - kP2).sqrt
            let nuS = (k2 - kS2).sqrt
            let two = C(2 * k * k) - kS2
            let denominator = two * two - C(4 * k * k) * nuP * nuS
            let load = p0 * a * j1(k * a) / k
            let displacement = C(-load / mu) * kS2 * nuP / denominator
            sum = sum + (j0(k * r) * k * dk) * displacement
        }
        // Velocity: iω times displacement, the step's own transform being rate/(iω).
        spectrum.append(sum * rate(w))
    }
    return times.map { t in
        var total = 0.0
        for (n, f) in frequencies.enumerated() {
            let phase = C(cos(2 * Double.pi * f * t), sin(2 * Double.pi * f * t))
            let term = spectrum[n] * phase
            total += (n == 0 ? 1 : 2) * term.re
        }
        return exp(omegaI * t) * total * df
    }
}

/// Runs the grid with the surface pressed by `load(r, t)`, reading `receivers` each step.
private func run(
    _ grid: AxisymmetricElasticGrid, until end: Double, receivers: [ElasticReceiver],
    load: (Double, Double) -> Double, each: (AxisymmetricElasticStepper) -> Void = { _ in }
) -> (times: [Double], readings: [[ElasticReading]], stepper: AxisymmetricElasticStepper) {
    let stepper = AxisymmetricElasticStepper(grid: grid)
    let radii = grid.surfaceRadii
    var times: [Double] = []
    var readings: [[ElasticReading]] = []
    while stepper.time < end {
        let t = stepper.time + grid.timeStep
        stepper.step(surfacePressure: radii.map { load($0, t) })
        // Velocities are half a step behind the stresses.
        times.append(stepper.time - grid.timeStep / 2)
        readings.append(stepper.read(receivers))
        each(stepper)
    }
    return (times, readings, stepper)
}

@Suite("Axisymmetric elastic half-space")
struct AxisymmetricElasticTests {
    @Test("The transform reference settles to Boussinesq's static displacement")
    func boussinesq() {
        // The reference's own check: the displacement it integrates to, long after the waves
        // have passed, is F(1 − ν)/(2πμr) for the disk's force F = p₀πa². The slowest
        // frequencies need wavenumbers far finer than ω_I/c_S, so a longer period in r here.
        let (a, p0, r) = (0.2, 1e5, 2.0)
        let times = stride(from: 0.0, through: 0.3, by: 2e-4).map { $0 }
        let velocity = lambVelocity(
            radius: r, times: times, disk: a, pressure: p0, rise: 0.006, layer: poisson, length: 600,
            wavenumbers: 6000, frequencyCount: 500)
        let displacement = velocity.reduce(0, +) * 2e-4
        let statics = p0 * Double.pi * a * a * (1 - 0.25) / (2 * Double.pi * poisson.mu * r)
        #expect(abs(displacement / statics - 1) < 0.03, "\(displacement) against \(statics)")
    }

    @Test("A disk pressed on the surface moves it as Lamb's problem says")
    func lamb() throws {
        // A disk 0.2 m across, four cells, switched on over 6 ms; the surface's downward velocity
        // at 2 and 3 m: the P wave's small arrival, then the Rayleigh wave's pulse.
        let (a, p0, rise) = (0.2, 1e5, 0.006)
        let grid = try AxisymmetricElasticGrid(
            radialCells: 120, depthCells: 80, spacing: 0.05, layers: [poisson], pmlCells: 20,
            dominantFrequency: 100)
        let receivers = [2.0, 3.0].map { ElasticReceiver(radius: $0, depth: 0) }
        let result = run(grid, until: 0.045, receivers: receivers) { r, t in
            r < a ? p0 * smoothStep(t, rise: rise) : 0
        }
        for (n, receiver) in receivers.enumerated() {
            let model = result.readings.map { $0[n].vertical }
            let exact = lambVelocity(
                radius: receiver.radius, times: result.times, disk: a, pressure: p0, rise: rise,
                layer: poisson)
            let scale = exact.map(abs).max()!
            let worst = zip(model, exact).map { abs($0 - $1) }.max()!
            #expect(worst < 0.08 * scale, "r = \(receiver.radius): worst \(worst / scale) of the peak")
            // Nothing before the P wave.
            let early = zip(result.times, model).filter {
                $0.0 < receiver.radius / poisson.pWaveSpeed - 0.001
            }
            #expect(early.allSatisfy { abs($0.1) < 0.01 * scale })
        }
    }

    @Test("A load sweeping out faster than the P wave moves the surface as Cole and Huth's plane solution")
    func movingLoad() throws {
        // A step of pressure sweeping outwards at U: superseismic, the ground still until the
        // front, then the plane solution's jump, with s = 1/U, η = √(1/c² − s²) and
        // R = (η_S² − s²)² + 4s²η_Pη_S: v_z = p₀η_P(η_S² + s²)/(μR) down and
        // v_r = −p₀s(2η_Pη_S − η_S² + s²)/(μR) outwards.
        let p0 = 1e5
        let grid = try AxisymmetricElasticGrid(
            radialCells: 140, depthCells: 60, spacing: 0.05, layers: [poisson], pmlCells: 20,
            dominantFrequency: 100)
        let (cp, cs, mu) = (poisson.pWaveSpeed, poisson.sWaveSpeed, poisson.mu)
        let r = 4.5
        let receivers = [ElasticReceiver(radius: r, depth: 0)]
        let rise = 0.002
        for factor in [2.0, 3.0] {
            let speed = factor * cp
            let result = run(grid, until: r / speed + 0.008, receivers: receivers) { x, t in
                p0 * smoothStep(t - x / speed, rise: rise)
            }
            let s = 1 / speed
            let etaP = (1 / (cp * cp) - s * s).squareRoot()
            let etaS = (1 / (cs * cs) - s * s).squareRoot()
            let rr = pow(etaS * etaS - s * s, 2) + 4 * s * s * etaP * etaS
            let vz = p0 * etaP * (etaS * etaS + s * s) / (mu * rr)
            let vr = -p0 * s * (2 * etaP * etaS - etaS * etaS + s * s) / (mu * rr)
            // Behind the front's rise, over 2 ms.
            let window = zip(result.times, result.readings).filter {
                $0.0 > r / speed + rise + 0.0005 && $0.0 < r / speed + rise + 0.0025
            }
            let meanZ = window.map { $0.1[0].vertical }.reduce(0, +) / Double(window.count)
            let meanR = window.map { $0.1[0].radial }.reduce(0, +) / Double(window.count)
            #expect(abs(meanZ / vz - 1) < 0.05, "U = \(factor) c_P: v_z \(meanZ) against \(vz)")
            #expect(abs(meanR / vr - 1) < 0.08, "U = \(factor) c_P: v_r \(meanR) against \(vr)")
            let before = zip(result.times, result.readings).filter { $0.0 < r / speed - 0.0005 }
            #expect(before.allSatisfy { abs($0.1[0].vertical) < 0.01 * vz })
        }
        // Slower than the P wave (transseismic) and than the S wave (subseismic), the ground moves
        // before the front reaches it: the waves outrun the load. Transseismic, the P field ahead
        // is quasi-static and falls away within a few metres of the front (6% of the peak half a
        // millisecond ahead here, 1% at 4 ms); subseismic, the whole field runs ahead.
        for (speed, least) in [(1.4 * cs, 0.03), (0.7 * cs, 0.3)] {
            let result = run(grid, until: r / speed + 0.005, receivers: receivers) { x, t in
                p0 * smoothStep(t - x / speed, rise: rise)
            }
            let peak = result.readings.map { abs($0[0].vertical) }.max()!
            let ahead = zip(result.times, result.readings).filter { $0.0 < r / speed - 0.0005 }
                .map { abs($0.1[0].vertical) }.max()!
            #expect(ahead > least * peak, "U = \(speed): \(ahead) ahead against \(peak)")
        }
    }

    @Test("Rayleigh waves over a soft layer travel at Haskell's phase speed")
    func dispersion() throws {
        // 1 m of soil at 100 m/s (S) over a half-space at 200 m/s, both Poisson solids. The
        // fundamental mode's phase speed by Haskell's secular function, against the speed
        // between two surface receivers 4 m apart.
        let soft = AxisymmetricElasticGrid.Layer(
            thickness: 1, density: 1800, pWaveSpeed: 100 * 3.0.squareRoot(), sWaveSpeed: 100)
        let stiff = AxisymmetricElasticGrid.Layer(
            thickness: 100, density: 2000, pWaveSpeed: 200 * 3.0.squareRoot(), sWaveSpeed: 200)
        // The secular function's check: one material throughout gives Rayleigh's 0.9194 c_S.
        var thin = poisson
        thin.thickness = 1
        #expect(abs(haskell(frequency: 50, layer: thin, below: poisson)! / (0.91940 * 100) - 1) < 1e-3)
        let grid = try AxisymmetricElasticGrid(
            radialCells: 150, depthCells: 80, spacing: 0.1, layers: [soft, stiff], pmlCells: 25,
            dominantFrequency: 60)
        let (r1, r2) = (6.0, 10.0)
        let receivers = [r1, r2].map { ElasticReceiver(radius: $0, depth: 0) }
        // A broad pulse: a smooth rise and fall over 8 ms on a disk 0.3 m across.
        let result = run(grid, until: 0.2, receivers: receivers) { r, t in
            r < 0.3 ? 1e5 * (smoothStep(t, rise: 0.004) - smoothStep(t - 0.004, rise: 0.004)) : 0
        }
        // From 30 to 100 Hz the speed falls from 149 to 92 m/s. (At 40 and 50 Hz, two or three
        // wavelengths out, the receivers read 8–17% off, where the near field and the next mode
        // still mix in; they are left out.)
        for f in [30.0, 60.0, 70.0, 80.0, 100.0] {
            // Each receiver's spectrum at f, over a window round the Rayleigh arrivals.
            func spectrum(_ n: Int, _ radius: Double) -> C {
                var sum = C(0)
                for (t, reading) in zip(result.times, result.readings) {
                    let centre = radius / 95
                    let taper = exp(-pow((t - centre) / 0.03, 2))
                    let phase = -2 * Double.pi * f * t
                    sum = sum + (reading[n].vertical * taper) * C(cos(phase), sin(phase))
                }
                return sum
            }
            let ratio = spectrum(1, r2) / spectrum(0, r1)
            var lag = -atan2(ratio.im, ratio.re)
            let exact = haskell(frequency: f, layer: soft, below: stiff)!
            // The whole cycles the phase lost over the 4 m: the one nearest the exact speed.
            let cycles = ((2 * Double.pi * f * (r2 - r1) / exact - lag) / (2 * Double.pi)).rounded()
            lag += 2 * Double.pi * cycles
            let measured = 2 * Double.pi * f * (r2 - r1) / lag
            #expect(abs(measured / exact - 1) < 0.04, "\(f) Hz: \(measured) against \(exact) m/s")
        }
    }

    @Test("The perfectly matched layer takes the waves away; rigid edges keep them")
    func absorbing() throws {
        let load = { (r: Double, t: Double) in
            r < 0.2 ? 1e5 * (smoothStep(t, rise: 0.004) - smoothStep(t - 0.004, rise: 0.004)) : 0
        }
        var energies: [Double] = []
        for cells in [20, 0] {
            let grid = try AxisymmetricElasticGrid(
                radialCells: 60 + cells, depthCells: 40 + cells, spacing: 0.05, layers: [poisson],
                pmlCells: cells, dominantFrequency: 100)
            var peak = 0.0
            var last = 0.0
            _ = run(grid, until: 0.12, receivers: []) { r, t in
                load(r, t)
            } each: { stepper in
                last = stepper.interiorEnergy()
                peak = max(peak, last)
            }
            energies.append(last / peak)
        }
        #expect(energies[0] < 0.02, "with the layer \(energies[0]) of the peak is left")
        #expect(energies[1] > 0.3, "with rigid edges \(energies[1]) of the peak is left")
    }

    @Test("Under a load sweeping out far faster than any wave, it is the soil column")
    func column() throws {
        // A pressure front at 20 c_P, nearly a plane load on the whole surface: 1 m down, the
        // downward velocity p/(ρc_P), as the elastic column of the same soil gives.
        let p0 = 1e5
        let grid = try AxisymmetricElasticGrid(
            radialCells: 120, depthCells: 80, spacing: 0.05, layers: [poisson], pmlCells: 20,
            dominantFrequency: 100)
        let speed = 20 * poisson.pWaveSpeed
        let pulse = { (t: Double) in p0 * (smoothStep(t, rise: 0.003) - smoothStep(t - 0.006, rise: 0.003)) }
        let receiver = ElasticReceiver(radius: 2, depth: 1)
        let result = run(grid, until: 0.025, receivers: [receiver]) { r, t in pulse(t - r / speed) }
        let peak = result.readings.map { $0[0].vertical }.max()!
        let soil = SoilProfile(
            layers: [
                SoilLayer(
                    thickness: 10, density: Float(poisson.density), waveSpeed: Float(poisson.pWaveSpeed))
            ])
        var column = SoilColumn(profile: soil, depth: 1)
        let dt = column.timeStep
        var columnPeak = 0.0
        while column.time < 0.025 {
            let t = column.time - receiver.radius / speed
            column.step(load: (pulse(t - dt / 2) + 4 * pulse(t) + pulse(t + dt / 2)) / 6)
            columnPeak = max(columnPeak, column.atNodes(column.velocities, depth: 1))
        }
        let plane = p0 / (poisson.density * poisson.pWaveSpeed)
        #expect(abs(peak / plane - 1) < 0.03, "\(peak) against p/(ρc_P) \(plane)")
        #expect(abs(peak / columnPeak - 1) < 0.03, "\(peak) against the column's \(columnPeak)")
        // Even so the front sends a weak S wave down behind the P wave, nearly vertical, its
        // particles moving sideways: by the plane solution, outwards at 2sη_S/(η_S² − s²) times
        // the P wave's downward speed (about a seventeenth here). At the surface the two cancel
        // to a tenth of that; a metre down the S wave arrives on its own, later.
        let s = 1 / speed
        let etaS = (1 / pow(poisson.sWaveSpeed, 2) - s * s).squareRoot()
        let share = 2 * s * etaS / (etaS * etaS - s * s)
        let outwards = result.readings.map { abs($0[0].radial) }.max()!
        #expect(abs(outwards / (share * peak) - 1) < 0.15, "\(outwards) against \(share * peak)")
    }

    @Test("Soil that unloads stiffly, under a front far faster than any wave, is the bilinear column")
    func bilinear() throws {
        // The column's bilinear law as compaction along each shortening: in uniaxial strain,
        // ρc² loading and ρc_u² unloading, the column's moduli exactly. The column carries
        // tension, which soil does not; under a surcharge the soil never pulls. The absorbing
        // layer stays elastic, so its edge sends waves in at c_u: it is kept 9 m away. Within 4%
        // at 1 m and 6% at 3 m on these 0.05 m cells (the rise is seven of them), 2% and 5% on
        // 0.025 m.
        let p0 = 1e5
        var soil = poisson
        soil.unloadingPWaveSpeed = 2 * poisson.pWaveSpeed
        let grid = try AxisymmetricElasticGrid(
            radialCells: 240, depthCells: 100, spacing: 0.05, layers: [soil], pmlCells: 20,
            dominantFrequency: 100, surcharge: 2e5)
        let speed = 20 * soil.fastest
        let pulse = { (t: Double) in p0 * (smoothStep(t, rise: 0.002) - smoothStep(t - 0.002, rise: 0.008)) }
        let receivers = [1.0, 3.0].map { ElasticReceiver(radius: 2, depth: $0) }
        let result = run(grid, until: 0.03, receivers: receivers) { r, t in pulse(t - r / speed) }
        let profile = SoilProfile(
            layers: [
                SoilLayer(
                    thickness: 10, density: Float(soil.density), waveSpeed: Float(soil.pWaveSpeed),
                    unloadingWaveSpeed: Float(soil.fastest))
            ], timeStep: 1e-5)
        var column = SoilColumn(profile: profile, depth: 6)
        let dt = column.timeStep
        var peaks = [0.0, 0.0]
        while column.time < 0.03 {
            let t = column.time - 2 / speed
            column.step(load: (pulse(t - dt / 2) + 4 * pulse(t) + pulse(t + dt / 2)) / 6)
            for (n, depth) in [1.0, 3.0].enumerated() {
                peaks[n] = max(peaks[n], column.atNodes(column.velocities, depth: depth))
            }
        }
        for n in 0..<2 {
            let peak = result.readings.map { $0[n].vertical }.max()!
            #expect(
                abs(peak / peaks[n] - 1) < 0.07, "at \(receivers[n].depth) m: \(peak) against \(peaks[n])")
        }
        // Worn down with depth, as the column is.
        #expect(peaks[1] < 0.9 * peaks[0])
    }

    @Test("Sand that yields in shear stays within its Drucker–Prager cone, and the yielding takes energy")
    func cone() throws {
        // Sand at 35° and no cohesion, resting under its own weight with K₀ = 1 − sin φ, under a
        // disc pressed with 2 MPa: every yielding point's √J₂ within a hundredth of the cone's radius.
        var sand = poisson
        sand.frictionAngle = 35
        sand.restingRatio = 1 - sin(35 * Double.pi / 180)
        let grid = try AxisymmetricElasticGrid(
            radialCells: 80, depthCells: 60, spacing: 0.05, layers: [sand], pmlCells: 20,
            dominantFrequency: 100)
        // At rest, K₀ = 1 − sin φ is inside Mohr–Coulomb's limit, Rankine's active 0.27 here, and
        // the cone matched to it in triaxial compression: nothing yields and nothing moves.
        let rest = run(grid, until: 0.005, receivers: [ElasticReceiver(radius: 1, depth: 0.5)]) { _, _ in 0 }
        #expect(rest.stepper.yieldingLoss == 0 && rest.stepper.coneExcess() < 0)
        #expect(rest.readings.allSatisfy { $0[0].vertical == 0 && $0[0].radial == 0 })
        var worst = -Double.infinity
        var steps = 0
        let result = run(grid, until: 0.03, receivers: [ElasticReceiver(radius: 1.5, depth: 0)]) { r, t in
            r < 0.4 ? 2e6 * (smoothStep(t, rise: 0.002) - smoothStep(t - 0.004, rise: 0.004)) : 0
        } each: { stepper in
            steps += 1
            if steps % 5 == 0 { worst = max(worst, stepper.coneExcess()) }
        }
        #expect(worst < 0.01, "a point stood \(worst) outside its cone")
        // It takes energy, never more than the disc put in (here nine tenths of it).
        #expect(result.stepper.yieldingLoss > 0 && result.stepper.yieldingLoss < result.stepper.work)
        // The same disc on elastic soil moves the surface further out faster.
        let elastic = run(
            try grid.withLayers([poisson]), until: 0.03, receivers: [ElasticReceiver(radius: 1.5, depth: 0)]
        ) {
            r, t in r < 0.4 ? 2e6 * (smoothStep(t, rise: 0.002) - smoothStep(t - 0.004, rise: 0.004)) : 0
        }
        let yielding = result.readings.map { abs($0[0].vertical) }.max()!
        let springy = elastic.readings.map { abs($0[0].vertical) }.max()!
        #expect(yielding < springy, "\(yielding) against elastic \(springy)")
    }
}

/// The fundamental Rayleigh mode's phase speed, m/s, at `frequency` over one layer on a
/// half-space, by the root of Haskell's secular function: P-SV potentials in the layer as
/// cosh(νz) and sinh(νz)/ν (real whether ν² is positive or negative), decaying in the
/// half-space; traction-free surface and continuity at the interface, a 6 × 6 determinant.
private func haskell(
    frequency: Double, layer: AxisymmetricElasticGrid.Layer, below: AxisymmetricElasticGrid.Layer
) -> Double? {
    let w = 2 * Double.pi * frequency
    let thickness = layer.thickness
    func coshAndSinc(_ nu2: Double, _ z: Double) -> (c: Double, s: Double) {
        if nu2 >= 0 {
            let nu = nu2.squareRoot()
            return (cosh(nu * z), nu * z < 1e-8 ? z : sinh(nu * z) / nu)
        }
        let nu = (-nu2).squareRoot()
        return (cos(nu * z), nu * z < 1e-8 ? z : sin(nu * z) / nu)
    }
    func determinant(_ c: Double) -> Double {
        let k = w / c
        let (mu1, mu2) = (layer.mu, below.mu)
        let kS1 = w / layer.sWaveSpeed
        let kS2 = w / below.sWaveSpeed
        let nu1 = k * k - pow(w / layer.pWaveSpeed, 2)
        let ga1 = k * k - kS1 * kS1
        let nu2 = (k * k - pow(w / below.pWaveSpeed, 2)).squareRoot()
        let ga2 = (k * k - kS2 * kS2).squareRoot()
        // Rows u_x/i, u_z, σzz, σxz/i for a φ term f and a ψ term g (ψ = i·amplitude).
        func phi(_ f: Double, _ df: Double) -> [Double] {
            [k * f, df, mu1 * (2 * k * k - kS1 * kS1) * f, 2 * mu1 * k * df]
        }
        func psi(_ g: Double, _ dg: Double, _ g2: Double) -> [Double] {
            [-dg, -k * g, -2 * mu1 * k * dg, -mu1 * (g2 + k * k) * g]
        }
        let p0 = coshAndSinc(nu1, 0)
        let pH = coshAndSinc(nu1, thickness)
        let s0 = coshAndSinc(ga1, 0)
        let sH = coshAndSinc(ga1, thickness)
        // Columns: φ cosh, φ sinh/ν, ψ cosh, ψ sinh/γ, then the half-space's φ and ψ.
        let top = [
            phi(p0.c, nu1 * p0.s), phi(p0.s, p0.c), psi(s0.c, ga1 * s0.s, ga1), psi(s0.s, s0.c, ga1),
        ]
        let bottom = [
            phi(pH.c, nu1 * pH.s), phi(pH.s, pH.c), psi(sH.c, ga1 * sH.s, ga1), psi(sH.s, sH.c, ga1),
        ]
        let halfPhi = [k, -nu2, mu2 * (2 * k * k - kS2 * kS2), 2 * mu2 * k * -nu2]
        let halfPsi = [ga2, -k, -2 * mu2 * k * -ga2, -mu2 * (ga2 * ga2 + k * k)]
        var m = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
        // The surface: σzz = σxz = 0.
        for col in 0..<4 {
            m[0][col] = top[col][2]
            m[1][col] = top[col][3]
        }
        // The interface: the layer's u_x, u_z, σzz, σxz equal the half-space's.
        for row in 0..<4 {
            for col in 0..<4 { m[2 + row][col] = bottom[col][row] }
            m[2 + row][4] = -halfPhi[row]
            m[2 + row][5] = -halfPsi[row]
        }
        // Gaussian elimination with partial pivoting.
        var det = 1.0
        for i in 0..<6 {
            let pivot = (i..<6).max { abs(m[$0][i]) < abs(m[$1][i]) }!
            if pivot != i {
                m.swapAt(pivot, i)
                det = -det
            }
            guard m[i][i] != 0 else { return 0 }
            det *= m[i][i]
            for r in (i + 1)..<6 {
                let f = m[r][i] / m[i][i]
                for c2 in i..<6 { m[r][c2] -= f * m[i][c2] }
            }
        }
        return det
    }
    // The fundamental mode is the slowest root, between nine-tenths of the layer's S speed and
    // the half-space's.
    var c = 0.85 * min(layer.sWaveSpeed, below.sWaveSpeed)
    let top = 0.9999 * below.sWaveSpeed
    var previous = determinant(c)
    let step = 0.0005 * below.sWaveSpeed
    while c + step < top {
        let next = determinant(c + step)
        if previous.sign != next.sign {
            var (low, high) = (c, c + step)
            for _ in 0..<60 {
                let mid = (low + high) / 2
                if determinant(mid).sign == determinant(low).sign { low = mid } else { high = mid }
            }
            return (low + high) / 2
        }
        previous = next
        c += step
    }
    return nil
}
