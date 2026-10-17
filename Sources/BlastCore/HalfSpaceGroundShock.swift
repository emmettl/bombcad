import Foundation
import simd

/// Where the half-space is centred and what drives it besides the air: set from the scene's charge
/// (`BombCAD run` fills it in from the scenario where a description leaves it out).
public struct HalfSpaceSetup: Codable, Sendable, Equatable {
    /// The axis, (x, y) in metres: under the charge.
    public var centre: SIMD2<Float>
    /// The charge's TNT-equivalent mass, kg, for the source it drives straight into the ground.
    public var chargeMass: Float
    /// The share of the charge's energy carried off as elastic waves by that source; nil for the
    /// calibrated default (`DirectInducedSource.defaultElasticShare`), 0 for none.
    public var elasticShare: Float?
    /// The grid's spacing, m; nil to suit the slowest shear wave at `DirectInducedSource`'s
    /// highest frequency.
    public var cellSize: Float?

    public init(centre: SIMD2<Float>, chargeMass: Float, elasticShare: Float? = nil, cellSize: Float? = nil) {
        self.centre = centre
        self.chargeMass = chargeMass
        self.elasticShare = elasticShare
        self.cellSize = cellSize
    }
}

extension GroundShockSpec {
    /// For the half-space with no axis given, one under the scene's charge, with its mass.
    public func settingHalfSpace(from scenario: Scenario) -> GroundShockSpec {
        guard model == .halfspace, halfSpace == nil else { return self }
        var spec = self
        spec.halfSpace = HalfSpaceSetup(
            centre: SIMD2(scenario.charge.position.x, scenario.charge.position.y),
            chargeMass: scenario.charge.mass)
        return spec
    }
}

/// What the charge drives into the ground directly, inside its crater, for the half-space: a
/// pressure on the crater's disc that carries a set share of the charge's energy away as elastic
/// waves. The air's own pressure there, on the model's rigid ground, would drive elastic soil far
/// beyond anything it could carry, so it is replaced inside the crater by this.
public enum DirectInducedSource {
    /// Calibrated once against UFC 3-340-01's direct-induced relation (`ufcPeakVelocity`): for
    /// 1 t on dense sand (n = 2.5, c_P 488 m/s), the share at which the half-space's peak
    /// resultant velocity 0.5 m down equals UFC's at 8 ft/lb^(1/3), 32 m (`blastbench
    /// groundmotion --calibrate`). The elastic half-space's direct waves fall away as about
    /// r^(−1/2), UFC's as r^(−2.5), so it is four times too low at half that range and four times
    /// too high at twice it (docs/ground-shock-outrunning.md#the-direct-source).
    public static let defaultElasticShare: Float = 9.3e-6
    /// The highest frequency the grid is sized for by default, Hz.
    public static let gridFrequency: Double = 150

    /// UFC 3-340-01's peak particle velocity of direct-induced ground shock, m/s, at `range` m
    /// from `mass` kg: v = f · 160 · (R/W^(1/3))^(−n) ft/s, R in feet and W in pounds, f the
    /// coupling factor (0.14 for a burst on or above the ground) and n the soil's attenuation
    /// coefficient (2.5 for dense sand, 2.75 for loose dry sand and loess). Quoted by Xia et al.
    /// (2022); W taken here as the TNT-equivalent mass.
    public static func ufcPeakVelocity(range: Double, mass: Double, coupling: Double = 0.14, n: Double)
        -> Double
    {
        let scaled = (range / 0.3048) / cbrt(mass * 2.204_62)
        return coupling * 160 * pow(scaled, -n) * 0.3048
    }

    /// The source's pressure, Pa, at `time` s after the detonation, on a disc of `radius` m, for
    /// `energy` J in soil of impedance ρc_P: A sin²(πt/τ) for τ, with τ twice the time the P
    /// wave takes to cross the disc. The work a disc wider than its waves does is
    /// πa² ∫p² dt/(ρc_P) = πa²A²(3τ/8)/(ρc_P), which sets A.
    public static func pressure(
        time: Double, radius: Double, energy: Double, impedance: Double, pWaveSpeed: Double,
        minimumDuration: Double
    ) -> Double {
        let tau = max(2 * radius / pWaveSpeed, minimumDuration)
        guard time > 0, time < tau, radius > 0, energy > 0 else { return 0 }
        let amplitude = (energy * impedance / (Double.pi * radius * radius * 3 * tau / 8)).squareRoot()
        let s = sin(Double.pi * time / tau)
        return amplitude * s * s
    }
}

/// The ground's motion under ground points in a layered elastic half-space about the charge,
/// driven by the air's ground pressures averaged round rings centred on it, and inside the
/// crater by the charge's direct source: P, S and Rayleigh waves, vertical and radial motion,
/// including where the ground's waves outrun the air. One way, as the column is.
///
/// Single owner, as its stepper: a consumer carries it from frame to frame.
public final class HalfSpaceGroundShock: @unchecked Sendable {
    public let grid: AxisymmetricElasticGrid
    public let stepper: AxisymmetricElasticStepper
    public let setup: HalfSpaceSetup
    let points: [SIMD2<Float>]
    let depths: [Float]
    let receivers: [ElasticReceiver]
    private var loads: [GroundLoad]
    /// The load's averaging window, s.
    let window: Double
    private let crater: (radius: Double, energy: Double, impedance: Double, speed: Double)?

    // Per receiver: peaks, displacements and the history at each frame.
    public private(set) var peakDown: [Double]
    public private(set) var peakOutwards: [Double]
    /// The fastest the ground moved at each receiver, m/s: √(v_r² + v_z²).
    public private(set) var peakResultant: [Double]
    private(set) var peakStress: [Double]
    private(set) var peakAcceleration: [Double]
    private(set) var displacement: [Double]
    private(set) var peakDisplacement: [Double]
    private(set) var arrivals: [Double?]
    private(set) var verticalHistory: [[Float]]
    private(set) var radialHistory: [[Float]]
    private var previous: [ElasticReading]
    let arrivalThreshold: Double

    /// Twelve steps' worth of averaging, as the column's.
    public static let windowSteps = 12.0

    public enum SetupError: Error { case invalid(String) }

    public init(spec: GroundShockSpec, setup: HalfSpaceSetup) throws {
        self.setup = setup
        let profile = spec.columnProfile
        points = spec.allPoints
        depths = spec.depths
        arrivalThreshold = Double(spec.arrivalThreshold)
        let distances = points.map { Double(simd_distance($0, setup.centre)) }
        // The layers, each with its shear speed, and what lies beneath as the last.
        var layers = profile.layers.map { layer in
            AxisymmetricElasticGrid.Layer(
                thickness: Double(layer.thickness), density: Double(layer.density),
                pWaveSpeed: Double(layer.waveSpeed), sWaveSpeed: Double(layer.shearSpeed))
        }
        switch profile.base {
        case .halfSpace(let density, let waveSpeed):
            layers.append(
                .init(
                    thickness: 1e4, density: Double(density), pWaveSpeed: Double(waveSpeed),
                    sWaveSpeed: Double(waveSpeed * SoilLayer.defaultShearRatio)))
        case .rigid, nil:
            // Rock held still is not offered here: the last layer goes on.
            layers[layers.count - 1].thickness = 1e4
        }
        let slowest = layers.map(\.sWaveSpeed).min()!
        let h = setup.cellSize.map(Double.init) ?? slowest / (10 * DirectInducedSource.gridFrequency)
        let pml = 20
        let reach = Self.reach(points: points, centre: setup.centre)
        let deep = max(2 * Double(depths.max() ?? 1), 0.4 * reach)
        grid = try AxisymmetricElasticGrid(
            radialCells: Int((reach / h).rounded(.up)) + pml, depthCells: Int((deep / h).rounded(.up)) + pml,
            spacing: h, layers: layers, pmlCells: pml,
            dominantFrequency: DirectInducedSource.gridFrequency / 3)
        stepper = AxisymmetricElasticStepper(grid: grid)
        window = Self.windowSteps * grid.timeStep
        let asked = spec.depths
        receivers = distances.flatMap { r in asked.map { ElasticReceiver(radius: r, depth: Double($0)) } }
        loads = Array(repeating: GroundLoad(), count: grid.radialCells)
        let n = receivers.count
        peakDown = Array(repeating: 0, count: n)
        peakOutwards = peakDown
        peakResultant = peakDown
        peakStress = peakDown
        peakAcceleration = peakDown
        displacement = peakDown
        peakDisplacement = peakDown
        arrivals = Array(repeating: nil, count: n)
        verticalHistory = Array(repeating: [], count: n)
        radialHistory = verticalHistory
        previous = Array(repeating: ElasticReading(radial: 0, vertical: 0, verticalStress: 0), count: n)
        // The direct source on the crater's disc.
        let share = Double(setup.elasticShare ?? DirectInducedSource.defaultElasticShare)
        let charge = Charge(mass: setup.chargeMass, position: SIMD3(setup.centre.x, setup.centre.y, 0))
        if share > 0, let estimate = CraterEstimate(charge: charge, groundHeight: 0, ground: .alluvium) {
            let top = layers[0]
            crater = (
                Double(estimate.apparentRadius), share * Double(setup.chargeMass) * 4.184e6,
                top.density * top.pWaveSpeed, top.pWaveSpeed
            )
        } else {
            crater = nil
        }
    }

    /// How far out the half-space reaches before its absorbing layer, m: past the farthest point
    /// by a seventh and 5 m.
    public static func reach(points: [SIMD2<Float>], centre: SIMD2<Float>) -> Double {
        1.15 * Double(points.map { simd_distance($0, centre) }.max() ?? 10) + 5
    }

    /// The air on the ground averaged round each of the grid's surface rings at a frame: the
    /// overpressure now and the peak and positive impulse so far, sampled round the ring at
    /// about a cell's spacing where the slice holds the ground.
    func rings(_ slice: GroundSlice) -> [(overpressure: Float, peak: Float, impulse: Float)?] {
        let extent = SIMD2(Float(slice.grid.x), Float(slice.grid.y)) * slice.cellSize
        return grid.surfaceRadii.map { r in
            // Two samples a cell round the ring at most: enough to average the cells it crosses.
            let count = min(max(Int(Double.pi * r / Double(slice.cellSize)) + 1, 8), 256)
            var sum = SIMD3<Float>.zero
            var found: Float = 0
            for n in 0..<count {
                let angle = 2 * Double.pi * (Double(n) + 0.5) / Double(count)
                let point = setup.centre + SIMD2(Float(r * cos(angle)), Float(r * sin(angle)))
                guard point.x >= 0, point.y >= 0, point.x <= extent.x, point.y <= extent.y,
                    let sample = slice.sample(point)
                else { continue }
                sum += SIMD3(sample.overpressure, sample.peak, sample.impulse)
                found += 1
            }
            guard found > 0 else { return nil }
            let mean = sum / found
            return (mean.x, mean.y, mean.z)
        }
    }

    /// Takes a frame of the ground's air and advances the half-space to its time.
    public func consume(_ slice: GroundSlice) {
        consume(rings: rings(slice), time: slice.time)
    }

    /// Takes a frame given as each surface ring's air (overpressure, Pa, and the peak and
    /// positive impulse so far), and advances the half-space to `time`.
    public func consume(rings: [(overpressure: Float, peak: Float, impulse: Float)?], time: Double) {
        for (n, ring) in rings.enumerated() {
            loads[n].append(
                time: time, overpressure: ring?.overpressure ?? 0, peak: ring?.peak ?? 0,
                impulse: max(ring?.impulse ?? 0, 0))
        }
        let dt = grid.timeStep
        let radii = grid.surfaceRadii
        while stepper.time + dt + window / 2 <= time + 1e-12 {
            let t = stepper.time + dt
            var pressures = loads.map { $0.integral(from: t - window / 2, to: t + window / 2) / window }
            if let crater {
                let p = DirectInducedSource.pressure(
                    time: t, radius: crater.radius, energy: crater.energy, impedance: crater.impedance,
                    pWaveSpeed: crater.speed, minimumDuration: 4 * window)
                for (i, r) in radii.enumerated() where r < crater.radius { pressures[i] = p }
            }
            stepper.step(surfacePressure: pressures)
            record()
        }
        for n in loads.indices { loads[n].forget(before: stepper.time - window) }
        let readings = stepper.read(receivers)
        for n in receivers.indices {
            verticalHistory[n].append(Float(readings[n].vertical))
            radialHistory[n].append(Float(readings[n].radial))
        }
    }

    private func record() {
        let dt = grid.timeStep
        let readings = stepper.read(receivers)
        for (n, reading) in readings.enumerated() {
            peakDown[n] = max(peakDown[n], reading.vertical)
            peakOutwards[n] = max(peakOutwards[n], abs(reading.radial))
            peakResultant[n] = max(
                peakResultant[n],
                (reading.radial * reading.radial + reading.vertical * reading.vertical).squareRoot())
            peakStress[n] = max(peakStress[n], reading.verticalStress)
            let rate = (reading.vertical - previous[n].vertical) / dt
            peakAcceleration[n] = max(peakAcceleration[n], abs(rate))
            displacement[n] += reading.vertical * dt
            peakDisplacement[n] = max(peakDisplacement[n], displacement[n])
            if arrivals[n] == nil, reading.verticalStress >= arrivalThreshold { arrivals[n] = stepper.time }
        }
        previous = readings
    }

    /// The responses at each point's depths: the downward and outward peaks, the stress, the
    /// displacement and its history, and the acceleration (only as fine as the load's window).
    public func responses(_ point: Int) -> [GroundResponse] {
        depths.indices.map { d in
            let n = point * depths.count + d
            return GroundResponse(
                depth: depths[d], stress: Float(peakStress[n]), verticalVelocity: Float(peakDown[n]),
                verticalDisplacement: Float(peakDisplacement[n]), horizontalVelocity: Float(peakOutwards[n]),
                arrival: arrivals[n], residualDisplacement: Float(displacement[n]),
                history: verticalHistory[n],
                verticalAcceleration: Float(peakAcceleration[n]), upwardAcceleration: nil)
        }
    }
}
