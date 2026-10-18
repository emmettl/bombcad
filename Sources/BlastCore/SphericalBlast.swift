import Foundation
import simd

/// The early life of a blast from a charge in free air, solved in one dimension (spherical
/// symmetry) on a fine radial grid: the same scheme as the air solver (MUSCL-Hancock with an
/// HLLC Riemann solver), in finite-volume form with the face areas 4 pi r^2 and the pressure's
/// geometric source, with the air's own gas (ideal, or thermally perfect: hot air) and, with
/// afterburning, its products and oxygen, burnt as the air solver burns them. Started from the
/// charge's own size, it resolves the shock while it is far thinner than a cell of the 3D grid,
/// and is then mapped onto that grid (see `BlastSolver.depositMapped(_:)`), in place of the
/// coarse "balloon".
struct SphericalBlast {
    /// The gas: an ideal gas of `gamma`, or thermally perfect air (`AirModel.thermallyPerfect`),
    /// whose N2 and O2 store energy in vibration, in double precision.
    struct Gas {
        var gamma: Double
        var thermallyPerfect: Bool

        static let r = 287.05
        static let modes: [(share: Double, theta: Double)] = [(0.79, 3390), (0.21, 2270)]

        static func vibration(_ t: Double) -> Double {
            r * modes.reduce(0) { $0 + $1.share * $1.theta / (exp(min($1.theta / max(t, 1), 80)) - 1) }
        }

        static func vibrationHeat(_ t: Double) -> Double {
            r
                * modes.reduce(0) { sum, mode in
                    let x = min(mode.theta / max(t, 1), 80)
                    let e = exp(x)
                    return sum + mode.share * x * x * e / ((e - 1) * (e - 1))
                }
        }

        /// The temperature at internal energy `e` per kilogram (thermally perfect).
        static func temperature(specificEnergy e: Double) -> Double {
            var t = max(e, 1) / (2.5 * r)
            for _ in 0..<8 { t -= (2.5 * r * t + vibration(t) - e) / (2.5 * r + vibrationHeat(t)) }
            return max(t, 1e-6)
        }

        func pressure(density rho: Double, internalEnergy e: Double) -> Double {
            guard thermallyPerfect else { return (gamma - 1) * e }
            return rho * Self.r * Self.temperature(specificEnergy: e / rho)
        }

        func internalEnergy(density rho: Double, pressure p: Double) -> Double {
            guard thermallyPerfect else { return p / (gamma - 1) }
            let t = p / (rho * Self.r)
            return rho * (2.5 * Self.r * t + Self.vibration(t))
        }

        /// The ratio of specific heats, which sets the speed of sound.
        func ratio(density rho: Double, pressure p: Double) -> Double {
            guard thermallyPerfect else { return gamma }
            let t = p / (rho * Self.r)
            return 1 + Self.r / (2.5 * Self.r + Self.vibrationHeat(t))
        }
    }

    /// Afterburning as the air solver has it: products meeting oxygen burn at `rate` per second
    /// as far as the oxygen allows (`oxygenPerFuel` kilograms a kilogram), releasing `energy` per
    /// kilogram.
    struct Afterburn {
        var energy: Double
        var rate: Double
        var oxygenPerFuel: Double
        /// The fireball's turbulent mixing, an eddy diffusivity of the products and oxygen, m^2/s:
        /// the mixing the grid's own cells give the balloon, which a fine one-dimensional grid
        /// does not.
        var diffusivity: Double = 0
    }

    let cellSize: Double
    var density: [Double]
    var momentum: [Double]
    var energy: [Double]
    /// With afterburning: unburnt products and oxygen, kg/m^3.
    var fuel: [Double]
    var oxygen: [Double]
    let gas: Gas
    let afterburn: Afterburn?
    var gamma: Double { gas.gamma }
    let ambientDensity: Double
    let ambientPressure: Double
    private(set) var time: Double = 0
    /// Steps taken so far.
    private(set) var steps = 0
    /// Largest overpressure and positive-phase impulse seen so far in each cell.
    private(set) var peak: [Double]
    private(set) var impulse: [Double]
    /// When the overpressure in each cell first passed `arrivalThreshold`, s; −1 where it has not.
    private(set) var arrival: [Double]
    /// The overpressure that marks the blast's arrival, Pa.
    static let arrivalThreshold = 1_000.0
    /// Radii at which the pressure is recorded, and their records (time, absolute pressure).
    var probes: [Double] = []
    private(set) var records: [[(time: Double, pressure: Double)]] = []

    /// A sphere of hot gas holding `energy` joules and `mass` kilograms within `radius` metres,
    /// in still air holding `oxygen` kilograms of oxygen per kilogram; the grid reaches `extent`
    /// metres in `cells` cells.
    init(
        mass: Double, energy totalEnergy: Double, radius: Double, extent: Double, cells: Int, gamma: Double,
        ambientDensity: Double, ambientPressure: Double, thermallyPerfect: Bool = false,
        afterburn: Afterburn? = nil, oxygenInAir: Double = 0.232
    ) {
        cellSize = extent / Double(cells)
        gas = Gas(gamma: gamma, thermallyPerfect: thermallyPerfect)
        self.afterburn = afterburn
        self.ambientDensity = ambientDensity
        self.ambientPressure = ambientPressure
        let ambientEnergy = gas.internalEnergy(density: ambientDensity, pressure: ambientPressure)
        let volume = 4 / 3 * Double.pi * radius * radius * radius
        peak = Array(repeating: 0, count: cells)
        impulse = Array(repeating: 0, count: cells)
        arrival = Array(repeating: -1, count: cells)
        density = Array(repeating: ambientDensity, count: cells)
        momentum = Array(repeating: 0, count: cells)
        energy = Array(repeating: ambientEnergy, count: cells)
        fuel = Array(repeating: 0, count: cells)
        // The air the products displace keeps its oxygen, as the air solver's deposit has it.
        oxygen = Array(repeating: afterburn == nil ? 0 : oxygenInAir * ambientDensity, count: cells)
        for i in 0..<cells {
            // The fraction of the cell inside the sphere.
            let inner = Double(i) * cellSize
            let outer = inner + cellSize
            let inside =
                max(0, min(outer, radius) - inner) > 0
                ? (pow(min(outer, radius), 3) - pow(inner, 3)) / (pow(outer, 3) - pow(inner, 3)) : 0
            density[i] += inside * mass / volume
            energy[i] += inside * totalEnergy / volume
            if afterburn != nil { fuel[i] = inside * mass / volume }
        }
    }

    /// Density, velocity and pressure in cell `i`.
    private func primitive(_ i: Int) -> SIMD3<Double> {
        let rho = max(density[i], 1e-9)
        let u = momentum[i] / rho
        let p = max(gas.pressure(density: rho, internalEnergy: energy[i] - 0.5 * rho * u * u), 1e-3)
        return SIMD3(rho, u, p)
    }

    /// The radius of the leading shock: the outermost cell 1% above ambient pressure.
    var shockRadius: Double {
        for i in stride(from: density.count - 1, through: 0, by: -1)
        where primitive(i).z > 1.01 * ambientPressure {
            return (Double(i) + 1) * cellSize
        }
        return 0
    }

    private func flux(_ l: SIMD3<Double>, _ r: SIMD3<Double>) -> SIMD3<Double> {
        func energy(_ w: SIMD3<Double>) -> Double {
            gas.internalEnergy(density: w.x, pressure: w.z) + 0.5 * w.x * w.y * w.y
        }
        func physical(_ w: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(w.x * w.y, w.x * w.y * w.y + w.z, (energy(w) + w.z) * w.y)
        }
        let gl = gas.ratio(density: l.x, pressure: l.z)
        let gr = gas.ratio(density: r.x, pressure: r.z)
        let cl = (gl * l.z / l.x).squareRoot()
        let cr = (gr * r.z / r.x).squareRoot()
        let sl = l.x.squareRoot()
        let sr = r.x.squareRoot()
        let uRoe = (sl * l.y + sr * r.y) / (sl + sr)
        let hl = (energy(l) + l.z) / l.x
        let hr = (energy(r) + r.z) / r.x
        let hRoe = (sl * hl + sr * hr) / (sl + sr)
        let gRoe = (sl * gl + sr * gr) / (sl + sr)
        let cRoe = max((gRoe - 1) * (hRoe - 0.5 * uRoe * uRoe), 1e-12).squareRoot()
        let waveL = min(l.y - cl, uRoe - cRoe)
        let waveR = max(r.y + cr, uRoe + cRoe)
        if waveL >= 0 { return physical(l) }
        if waveR <= 0 { return physical(r) }
        let ml = l.x * (waveL - l.y)
        let mr = r.x * (waveR - r.y)
        let star = (r.z - l.z + l.y * ml - r.y * mr) / (ml - mr)
        if star >= 0 {
            let factor = ml / (waveL - star)
            let starState = SIMD3(
                factor, factor * star, factor * (energy(l) / l.x + (star - l.y) * (star + l.z / ml)))
            return physical(l) + waveL * (starState - SIMD3(l.x, l.x * l.y, energy(l)))
        }
        let factor = mr / (waveR - star)
        let starState = SIMD3(
            factor, factor * star, factor * (energy(r) / r.x + (star - r.y) * (star + r.z / mr)))
        return physical(r) + waveR * (starState - SIMD3(r.x, r.x * r.y, energy(r)))
    }

    /// Advances until the shock reaches `radius` metres.
    mutating func run(toShockRadius radius: Double, cfl: Double = 0.4) {
        let n = density.count
        records = probes.map { _ in [] }
        var guardSteps = 0
        while shockRadius < radius && guardSteps < 2_000_000 {
            guardSteps += 1
            steps += 1
            var fastest = 1e-6
            let w = (0..<n).map(primitive)
            let ratios = w.map { gas.ratio(density: $0.x, pressure: $0.z) }
            for (x, g) in zip(w, ratios) { fastest = max(fastest, abs(x.y) + (g * x.z / x.x).squareRoot()) }
            let dt = cfl * cellSize / fastest
            // Limited slopes (minmod, a monotonised central limiter's cautious member), then the
            // Hancock half step in primitive variables.
            func slope(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
                var s = SIMD3<Double>.zero
                for k in 0..<3 where a[k] * b[k] > 0 {
                    s[k] = (a[k] > 0 ? 1 : -1) * min(abs(a[k]), abs(b[k]))
                }
                return s
            }
            var lo = w
            var hi = w
            let half = 0.5 * dt / cellSize
            for i in 0..<n {
                let below = i > 0 ? w[i - 1] : SIMD3(w[i].x, -w[i].y, w[i].z)
                let above = i < n - 1 ? w[i + 1] : w[i]
                let d = slope(w[i] - below, above - w[i])
                let x = w[i]
                var h = x
                h.x = x.x - half * (x.y * d.x + x.x * d.y)
                h.y = x.y - half * (x.y * d.y + d.z / x.x)
                h.z = x.z - half * (x.y * d.z + ratios[i] * x.z * d.y)
                lo[i] = h - 0.5 * d
                hi[i] = h + 0.5 * d
                if min(lo[i].x, hi[i].x) <= 0 || min(lo[i].z, hi[i].z) <= 0 {
                    lo[i] = x
                    hi[i] = x
                }
            }
            // Fluxes through the faces; face 0 is the centre, where nothing passes. The species go
            // with the mass, at the upwind cell's share.
            var fluxes = Array(repeating: SIMD3<Double>.zero, count: n + 1)
            var fuelFlux = Array(repeating: 0.0, count: n + 1)
            var oxygenFlux = Array(repeating: 0.0, count: n + 1)
            for face in 1...n {
                let left = hi[face - 1]
                let right = face < n ? lo[face] : hi[n - 1]
                fluxes[face] = flux(left, right)
                if afterburn != nil {
                    let upwind = fluxes[face].x >= 0 ? face - 1 : min(face, n - 1)
                    let share = fluxes[face].x / max(density[upwind], 1e-9)
                    fuelFlux[face] = share * fuel[upwind]
                    oxygenFlux[face] = share * oxygen[upwind]
                }
            }
            for i in 0..<n {
                let inner = Double(i) * cellSize
                let outer = inner + cellSize
                let areaIn = inner * inner
                let areaOut = outer * outer
                let volume = (outer * outer * outer - inner * inner * inner) / 3
                let change = (areaOut * fluxes[i + 1] - areaIn * fluxes[i]) / volume
                density[i] -= dt * change.x
                momentum[i] -= dt * (change.y - w[i].z * (areaOut - areaIn) / volume)
                energy[i] -= dt * change.z
                if afterburn != nil {
                    fuel[i] = max(
                        fuel[i] - dt * (areaOut * fuelFlux[i + 1] - areaIn * fuelFlux[i]) / volume, 0)
                    oxygen[i] = max(
                        oxygen[i] - dt * (areaOut * oxygenFlux[i + 1] - areaIn * oxygenFlux[i]) / volume, 0)
                }
            }
            // The fireball's mixing, implicitly over the step (it is far stiffer than the flow).
            if let afterburn, afterburn.diffusivity > 0 {
                mix(&fuel, diffusivity: afterburn.diffusivity, dt: dt)
                mix(&oxygen, diffusivity: afterburn.diffusivity, dt: dt)
            }
            // Afterburning, after the step, as the air solver's final sweep does it.
            if let afterburn {
                let share = 1 - exp(-dt * afterburn.rate)
                for i in 0..<n {
                    let burnt = min(fuel[i], oxygen[i] / afterburn.oxygenPerFuel) * share
                    fuel[i] -= burnt
                    oxygen[i] -= burnt * afterburn.oxygenPerFuel
                    energy[i] += burnt * afterburn.energy
                }
            }
            time += dt
            for i in 0..<n {
                let overpressure = primitive(i).z - ambientPressure
                peak[i] = max(peak[i], overpressure)
                impulse[i] += max(overpressure, 0) * dt
                if arrival[i] < 0, overpressure > Self.arrivalThreshold { arrival[i] = time }
            }
            for (k, r) in probes.enumerated() {
                let s = state(at: r)
                let rho = max(s.x, 1e-9)
                let p = gas.pressure(density: rho, internalEnergy: s.z - 0.5 * s.y * s.y / rho)
                records[k].append((time, p))
            }
        }
    }

    /// Diffuses a species held per volume, as its mass fraction, with `diffusivity`, by backward
    /// Euler over `dt` (a tridiagonal solve), conserving its mass; no flux at the centre or the edge.
    private func mix(_ amount: inout [Double], diffusivity d: Double, dt: Double) {
        let n = amount.count
        var lower = [Double](repeating: 0, count: n)
        var diagonal = [Double](repeating: 0, count: n)
        var upper = [Double](repeating: 0, count: n)
        var right = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let inner = Double(i) * cellSize
            let outer = inner + cellSize
            let volume = (outer * outer * outer - inner * inner * inner) / 3
            let rho = max(density[i], 1e-9)
            // Conductances through the inner and outer faces, rho D A / dr.
            let a = i > 0 ? d * 0.5 * (rho + density[i - 1]) * inner * inner / cellSize : 0
            let b = i < n - 1 ? d * 0.5 * (rho + density[i + 1]) * outer * outer / cellSize : 0
            diagonal[i] = rho * volume / dt + a + b
            lower[i] = -a
            upper[i] = -b
            right[i] = amount[i] * volume / dt
        }
        // Thomas, for the mass fractions, then back to amounts per volume.
        for i in 1..<n {
            let w = lower[i] / diagonal[i - 1]
            diagonal[i] -= w * upper[i - 1]
            right[i] -= w * right[i - 1]
        }
        var fraction = [Double](repeating: 0, count: n)
        fraction[n - 1] = right[n - 1] / diagonal[n - 1]
        for i in stride(from: n - 2, through: 0, by: -1) {
            fraction[i] = (right[i] - upper[i] * fraction[i + 1]) / diagonal[i]
        }
        for i in 0..<n { amount[i] = max(fraction[i] * max(density[i], 1e-9), 0) }
    }

    /// Peak overpressure and positive impulse at `radius`, interpolated between cell centres.
    func extremes(at radius: Double) -> SIMD2<Double> {
        let x = radius / cellSize - 0.5
        let i = min(max(Int(x.rounded(.down)), 0), density.count - 1)
        let j = min(i + 1, density.count - 1)
        let t = min(max(x - Double(i), 0), 1)
        return SIMD2(peak[i] + t * (peak[j] - peak[i]), impulse[i] + t * (impulse[j] - impulse[i]))
    }

    /// When the blast arrived at `radius`, s, interpolated between cell centres where it has
    /// reached both; nil where it has not arrived.
    func arrival(at radius: Double) -> Double? {
        let x = radius / cellSize - 0.5
        let i = min(max(Int(x.rounded(.down)), 0), arrival.count - 1)
        let j = min(i + 1, arrival.count - 1)
        let t = min(max(x - Double(i), 0), 1)
        guard arrival[i] >= 0 else { return nil }
        return arrival[j] >= 0 ? arrival[i] + t * (arrival[j] - arrival[i]) : arrival[i]
    }

    /// Density, radial momentum and total energy per volume at `radius`, interpolated between
    /// cell centres.
    func state(at radius: Double) -> SIMD3<Double> {
        let x = radius / cellSize - 0.5
        let i = min(max(Int(x.rounded(.down)), 0), density.count - 1)
        let j = min(i + 1, density.count - 1)
        let t = min(max(x - Double(i), 0), 1)
        let a = SIMD3(density[i], momentum[i], energy[i])
        let b = SIMD3(density[j], momentum[j], energy[j])
        return a + t * (b - a)
    }

    /// Unburnt products and oxygen per volume at `radius`, interpolated between cell centres.
    func species(at radius: Double) -> SIMD2<Double> {
        let x = radius / cellSize - 0.5
        let i = min(max(Int(x.rounded(.down)), 0), density.count - 1)
        let j = min(i + 1, density.count - 1)
        let t = min(max(x - Double(i), 0), 1)
        return SIMD2(fuel[i] + t * (fuel[j] - fuel[i]), oxygen[i] + t * (oxygen[j] - oxygen[i]))
    }
}

extension BlastSolver {
    /// Lays down `charge` as its blast is when the shock has spread to `radius` metres, from a
    /// one-dimensional solution started at the charge's own size, and returns the solution, from
    /// which the time it took, and the peaks, impulses and histories at points the shock has
    /// already passed, are taken (`recordMapped`). A charge on the ground (rigid, reflecting)
    /// spreads as one of twice the mass in free air, of which the half above the ground is laid
    /// down. Cells farther than `radius` are left as they are; nothing solid may lie within it.
    /// The one-dimensional solution, unrun, a charge of `charge` takes to be mapped out to
    /// `radius` m under `configuration`: from a sphere of TNT's density, on a radial grid of a
    /// twentieth of its radius (2,000 to 20,000 cells) reaching 1.6 times `radius`.
    static func mappedSolution(
        _ charge: Charge, radius: Float, onGround: Bool, configuration: SolverConfiguration,
        ambientDensity: Float
    ) -> SphericalBlast {
        let multiplier: Double = onGround ? 2 : 1
        let mass = Double(charge.mass) * multiplier
        let energy = Double(charge.energy) * multiplier
        let size = cbrt(3 * mass / (4 * Double.pi * 1600))
        let extent = Double(radius) * 1.6
        let cells = min(max(Int(extent / (size / 20)), 2000), 20000)
        // The air's own gas and, with afterburning, its burning, at the real charge's rate.
        let burning: SphericalBlast.Afterburn? =
            configuration.afterburning
            ? SphericalBlast.Afterburn(
                energy: Double(configuration.afterburnEnergy),
                rate: configuration.mappedChargeBurns
                    ? 1
                        / max(
                            Double(configuration.afterburnTime) * cbrt(max(Double(charge.mass), 1e-3)), 1e-9)
                    : 0,
                oxygenPerFuel: Double(Self.oxygenPerFuel),
                diffusivity: Double(configuration.mappedChargeMixing) * cbrt(Double(charge.mass))) : nil
        return SphericalBlast(
            mass: mass, energy: energy, radius: size, extent: extent, cells: cells,
            gamma: Double(configuration.gamma), ambientDensity: Double(ambientDensity),
            ambientPressure: Double(configuration.ambientPressure),
            thermallyPerfect: configuration.airModel == .thermallyPerfect, afterburn: burning,
            oxygenInAir: Double(Self.oxygenInAir))
    }

    /// The wall time, cells and steps of the one-dimensional solution a charge of `mass` kg on the
    /// ground takes to be mapped `cells` cells of `cellSize` m out, under `configuration`.
    public static func mappedStartCost(
        mass: Float, cellSize: Float, cells mappedCells: Float, configuration: SolverConfiguration
    ) -> (seconds: Double, cells: Int, steps: Int) {
        let radius = mappedCells * cellSize
        var blast = mappedSolution(
            Charge(mass: mass, position: .zero), radius: radius, onGround: true, configuration: configuration,
            ambientDensity: 1.225)
        let start = Date()
        blast.run(toShockRadius: Double(radius))
        return (Date().timeIntervalSince(start), blast.density.count, blast.steps)
    }

    func depositMapped(_ charge: Charge, radius: Float, onGround: Bool, probes: [SIMD3<Float>])
        -> SphericalBlast
    {
        var blast = Self.mappedSolution(
            charge, radius: radius, onGround: onGround, configuration: configuration,
            ambientDensity: ambientDensity)
        blast.probes = probes.map { Double(simd_distance($0, charge.position)) }
        blast.run(toShockRadius: Double(radius))

        let grid = self.grid
        let dx = grid.cellSize
        let reach = radius + dx
        let low = grid.cell(containing: charge.position - reach)
        let high = grid.cell(containing: charge.position + reach)
        let samples = 4
        var species: [(index: Int, value: SIMD2<Float>)] = []
        mutateState { cells in
            for k in low.k...high.k {
                for j in low.j...high.j {
                    for i in low.i...high.i where !isSolid(i, j, k) {
                        var sum = SIMD3<Double>.zero
                        var momentum = SIMD3<Double>.zero
                        var carried = SIMD2<Double>.zero
                        var counted = 0
                        for c in 0..<samples {
                            for b in 0..<samples {
                                for a in 0..<samples {
                                    let offset = (SIMD3(Float(a), Float(b), Float(c)) + 0.5) / Float(samples)
                                    let point = (SIMD3(Float(i), Float(j), Float(k)) + offset) * dx
                                    let arm = SIMD3<Double>(point - charge.position)
                                    let r = simd_length(arm)
                                    guard r < Double(radius) * 1.5 else { continue }
                                    let s = blast.state(at: r)
                                    sum += s
                                    momentum += r > 1e-9 ? s.y * arm / r : .zero
                                    if blast.afterburn != nil { carried += blast.species(at: r) }
                                    counted += 1
                                }
                            }
                        }
                        // Only cells wholly within reach of the solution are replaced; the rest
                        // are still air.
                        guard counted == samples * samples * samples else { continue }
                        let n = Double(counted)
                        let index = grid.index(i, j, k)
                        cells[index].density = Float(sum.x / n)
                        cells[index].momentumX = Float(momentum.x / n)
                        cells[index].momentumY = Float(momentum.y / n)
                        cells[index].momentumZ = Float(momentum.z / n)
                        cells[index].energy = Float(sum.z / n)
                        if blast.afterburn != nil { species.append((index, SIMD2<Float>(carried / n))) }
                    }
                }
            }
        }
        // The products and oxygen the solution carried there, as the balloon's deposit lays them.
        if !species.isEmpty {
            mutateSpecies { buffer in
                for (index, value) in species { buffer[index] = value }
            }
            largestCharge = max(largestCharge, charge.mass)
        }
        return blast
    }

    /// After `restart()`, sets the clock to the time the mapped solution took, and gives the
    /// cells and gauges inside its reach the peaks, impulses and histories it recorded.
    func recordMapped(_ blast: SphericalBlast, charge: Charge, radius: Float, gauges: [SIMD3<Float>]) {
        startClock(at: blast.time)
        mappedStart = (blast, charge.position, radius)
        let grid = self.grid
        let dx = grid.cellSize
        let low = grid.cell(containing: charge.position - radius)
        let high = grid.cell(containing: charge.position + radius)
        setFields { peak, impulse in
            defer {
                // Patches placed already (at the restart) took their coarse cells' impulse then,
                // before this: they take it again, or their cells would rebuild it from nothing.
                refinement?.reseedImpulseBase(from: UnsafeBufferPointer(impulse), grid: grid)
            }
            for k in low.k...high.k {
                for j in low.j...high.j {
                    for i in low.i...high.i {
                        let centre = (SIMD3(Float(i), Float(j), Float(k)) + 0.5) * dx
                        let r = Double(simd_distance(centre, charge.position))
                        guard r < Double(radius) else { continue }
                        let extremes = blast.extremes(at: r)
                        peak[grid.index(i, j, k)] = Float(extremes.x)
                        impulse[grid.index(i, j, k)] = Float(extremes.y)
                    }
                }
            }
        }
        for (index, gauge) in gauges.enumerated() where simd_distance(gauge, charge.position) < radius {
            prependGaugeHistory(
                index, blast.records[index].map { GaugeSample(time: $0.time, pressure: Float($0.pressure)) })
        }
    }
}
