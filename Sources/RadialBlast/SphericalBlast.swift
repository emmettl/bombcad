import Foundation
import Synchronization
import simd

/// The early life of a blast from a charge in free air, solved in one dimension (spherical
/// symmetry) on a fine radial grid: the same scheme as the air solver (MUSCL-Hancock with an
/// HLLC Riemann solver), in finite-volume form with the face areas 4 pi r^2 and the pressure's
/// geometric source, with the air's own gas (ideal, or thermally perfect: hot air) and, with
/// afterburning, its products and oxygen, burnt as the air solver burns them. Started from the
/// charge's own size, it resolves the shock while it is far thinner than a cell of the 3D grid,
/// and is then mapped onto that grid (see `BlastSolver.depositMapped(_:)`), in place of the
/// coarse "balloon".
///
/// Its own module, built optimised even for debugging (see Package.swift): its loops are millions
/// of cell steps, which unoptimised code takes many minutes over, in every test that starts a run.
public struct SphericalBlast: Sendable {
    /// The gas: an ideal gas of `gamma`, or thermally perfect air (`AirModel.thermallyPerfect`),
    /// whose N2 and O2 store energy in vibration, in double precision.
    public struct Gas: Hashable, Sendable {
        public var gamma: Double
        public var thermallyPerfect: Bool
        /// The detonation products' own equation of state, or nil for products as hot air.
        public var products: JWL?

        public init(gamma: Double, thermallyPerfect: Bool, products: JWL? = nil) {
            self.gamma = gamma
            self.thermallyPerfect = thermallyPerfect
            self.products = products
        }

        static let r = 287.05
        // N2's and O2's shares and vibrational temperatures, K: 0.79 at 3390, 0.21 at 2270, summed
        // in that order.

        static func vibration(_ t: Double) -> Double {
            let warm = max(t, 1)
            let nitrogen = 0.79 * 3390 / (exp(min(3390 / warm, 80)) - 1)
            let oxygen = 0.21 * 2270 / (exp(min(2270 / warm, 80)) - 1)
            return r * (0 + nitrogen + oxygen)
        }

        static func vibrationHeat(_ t: Double) -> Double {
            let warm = max(t, 1)
            func share(_ share: Double, _ theta: Double) -> Double {
                let x = min(theta / warm, 80)
                let e = exp(x)
                return share * x * x * e / ((e - 1) * (e - 1))
            }
            return r * (0 + share(0.79, 3390) + share(0.21, 2270))
        }

        /// `vibration(t)` and `vibrationHeat(t)` together, from the same two exponentials.
        static func vibrationAndHeat(_ t: Double) -> (energy: Double, heat: Double) {
            let warm = max(t, 1)
            let x = min(3390 / warm, 80)
            let y = min(2270 / warm, 80)
            let ex = exp(x)
            let ey = exp(y)
            let energy = r * (0 + 0.79 * 3390 / (ex - 1) + 0.21 * 2270 / (ey - 1))
            let heat =
                r
                * (0 + 0.79 * x * x * ex / ((ex - 1) * (ex - 1)) + 0.21 * y * y * ey / ((ey - 1) * (ey - 1)))
            return (energy, heat)
        }

        /// The temperature at internal energy `e` per kilogram (thermally perfect).
        static func temperature(specificEnergy e: Double) -> Double {
            var t = max(e, 1) / (2.5 * r)
            for _ in 0..<8 {
                let vibrating = vibrationAndHeat(t)
                t -= (2.5 * r * t + vibrating.energy - e) / (2.5 * r + vibrating.heat)
            }
            return max(t, 1e-6)
        }

        public func pressure(density rho: Double, internalEnergy e: Double) -> Double {
            guard thermallyPerfect else { return (gamma - 1) * e }
            return rho * Self.r * Self.temperature(specificEnergy: e / rho)
        }

        public func internalEnergy(density rho: Double, pressure p: Double) -> Double {
            guard thermallyPerfect else { return p / (gamma - 1) }
            let t = p / (rho * Self.r)
            return rho * (2.5 * Self.r * t + Self.vibration(t))
        }

        /// The ratio of specific heats, which sets the speed of sound.
        public func ratio(density rho: Double, pressure p: Double) -> Double {
            guard thermallyPerfect else { return gamma }
            let t = p / (rho * Self.r)
            return 1 + Self.r / (2.5 * Self.r + Self.vibrationHeat(t))
        }

        // With the products' own equation of state, a mixture holding a share `y` of its mass as
        // products: each part presses as it would alone at its own partial density (Dalton), both
        // at the mixture's internal energy per kilogram. It is the products' JWL where they are
        // alone, the air's gas where they are absent, and JWL's terms for dense products die away
        // as they dilute.

        /// The pressure of a mixture holding `e` internal energy per volume.
        public func pressure(density rho: Double, internalEnergy e: Double, products y: Double) -> Double {
            guard let jwl = products, y > 0 else { return pressure(density: rho, internalEnergy: e) }
            let specific = e / rho
            let air =
                thermallyPerfect
                ? rho * (1 - y) * Self.r * Self.temperature(specificEnergy: specific)
                : (gamma - 1) * rho * (1 - y) * specific
            return jwl.cold(rho * y).pressure + jwl.omega * rho * y * specific + air
        }

        /// The internal energy per volume of a mixture at pressure `p`.
        public func internalEnergy(density rho: Double, pressure p: Double, products y: Double) -> Double {
            guard let jwl = products, y > 0 else { return internalEnergy(density: rho, pressure: p) }
            let thermal = p - jwl.cold(rho * y).pressure
            guard thermallyPerfect else {
                return thermal / (jwl.omega * y + (gamma - 1) * (1 - y))
            }
            // Newton on the temperature the energy per kilogram has in air: from above, as the
            // translational and rotational heat alone overestimates it.
            var t = max(thermal, 1) / (rho * Self.r * (2.5 * jwl.omega * y + 1 - y))
            for _ in 0..<12 {
                let vibrating = Self.vibrationAndHeat(t)
                let f =
                    rho * (jwl.omega * y * (2.5 * Self.r * t + vibrating.energy) + (1 - y) * Self.r * t)
                    - thermal
                let slope = rho * (jwl.omega * y * (2.5 * Self.r + vibrating.heat) + (1 - y) * Self.r)
                t = max(t - f / slope, 1e-6)
            }
            return rho * (2.5 * Self.r * t + Self.vibration(t))
        }

        /// The square of a mixture's speed of sound, at `specific` internal energy per kilogram and
        /// pressure `p`: (∂p/∂ρ) at that energy, plus p/ρ² (∂p/∂e) at that density.
        func soundSquared(density rho: Double, specific: Double, pressure p: Double, products y: Double)
            -> Double
        {
            guard let jwl = products else { return 0 }
            var byDensity = y * (jwl.cold(rho * y).slope + jwl.omega * specific)
            var byEnergy = jwl.omega * rho * y
            if thermallyPerfect {
                let t = Self.temperature(specificEnergy: specific)
                byDensity += (1 - y) * Self.r * t
                byEnergy += rho * (1 - y) * Self.r / (2.5 * Self.r + Self.vibrationHeat(t))
            } else {
                byDensity += (1 - y) * (gamma - 1) * specific
                byEnergy += rho * (1 - y) * (gamma - 1)
            }
            return max(byDensity + p / (rho * rho) * byEnergy, 1e-6)
        }

        /// The ratio ρc²/p of a mixture, which the scheme takes as its gas's ratio of heats.
        public func ratio(density rho: Double, pressure p: Double, products y: Double) -> Double {
            guard products != nil, y > 0 else { return ratio(density: rho, pressure: p) }
            let specific = internalEnergy(density: rho, pressure: p, products: y) / rho
            return rho * soundSquared(density: rho, specific: specific, pressure: p, products: y) / p
        }
    }

    /// The Jones–Wilkins–Lee equation of state of detonation products: p = A (1 − ω/(R1 V))
    /// exp(−R1 V) + B (1 − ω/(R2 V)) exp(−R2 V) + ω ρ e, with V the products' volume relative to the
    /// unreacted explosive's (`density`).
    public struct JWL: Hashable, Sendable {
        public var a, b, r1, r2, omega, density: Double

        public init(a: Double, b: Double, r1: Double, r2: Double, omega: Double, density: Double) {
            (self.a, self.b, self.r1, self.r2, self.omega, self.density) = (a, b, r1, r2, omega, density)
        }

        /// TNT at 1.63 g/cm³, from the LLNL Explosives Handbook (B. M. Dobratz and P. C. Crawford,
        /// UCRL-52997, Change 2, 1985): A 3.712 Mbar, B 0.03231 Mbar, R1 4.15, R2 0.95, ω 0.30.
        public static let tnt = JWL(a: 371.2e9, b: 3.231e9, r1: 4.15, r2: 0.95, omega: 0.30, density: 1630)
        /// TNT's other set quoted from the handbook, which ANSYS Autodyn's library carries: A 373.77
        /// GPa, B 3.747 GPa, R1 4.15, R2 0.90, ω 0.35; the difference between the two is a measure
        /// of how well the products' state is known.
        public static let tntLeeFinger = JWL(
            a: 373.77e9, b: 3.747e9, r1: 4.15, r2: 0.90, omega: 0.35, density: 1630)

        /// The pressure of products at density `rho` beyond ω ρ e, and its slope in density.
        func cold(_ rho: Double) -> (pressure: Double, slope: Double) {
            let v = density / rho
            // Beyond a thousand times the explosive's volume both terms are below the smallest
            // double (and the slope would be 0 × ∞).
            guard rho > 0, v < 1000 else { return (0, 0) }
            let first = exp(-r1 * v)
            let second = exp(-r2 * v)
            let pressure = a * (1 - omega / (r1 * v)) * first + b * (1 - omega / (r2 * v)) * second
            let byVolume =
                a * first * (omega / (r1 * v * v) - r1 + omega / v)
                + b * second * (omega / (r2 * v * v) - r2 + omega / v)
            return (pressure, -byVolume * v / rho)
        }
    }

    /// Afterburning as the air solver has it: products meeting oxygen burn at `rate` per second
    /// as far as the oxygen allows (`oxygenPerFuel` kilograms a kilogram), releasing `energy` per
    /// kilogram.
    public struct Afterburn: Hashable, Sendable {
        public var energy: Double
        public var rate: Double
        public var oxygenPerFuel: Double
        /// The fireball's turbulent mixing, an eddy diffusivity of the products and oxygen, m^2/s:
        /// the mixing the grid's own cells give the balloon, which a fine one-dimensional grid
        /// does not.
        public var diffusivity: Double = 0

        public init(energy: Double, rate: Double, oxygenPerFuel: Double, diffusivity: Double = 0) {
            self.energy = energy
            self.rate = rate
            self.oxygenPerFuel = oxygenPerFuel
            self.diffusivity = diffusivity
        }
    }

    /// What the solution starts from, all of it: two alike give the same solution, bit for bit.
    struct Setup: Hashable {
        var mass, energy, radius, extent: Double
        var cells: Int
        var gas: Gas
        var ambientDensity, ambientPressure: Double
        var afterburn: Afterburn?
        var oxygenInAir: Double
    }

    let setup: Setup
    public let cellSize: Double
    public internal(set) var density: [Double]
    public internal(set) var momentum: [Double]
    public internal(set) var energy: [Double]
    /// With afterburning: unburnt products and oxygen, kg/m^3.
    public internal(set) var fuel: [Double]
    public internal(set) var oxygen: [Double]
    /// With the products' own equation of state: the detonation products, burnt or not, kg/m^3.
    public internal(set) var products: [Double]
    public let gas: Gas
    public let afterburn: Afterburn?
    public var gamma: Double { gas.gamma }
    public let ambientDensity: Double
    public let ambientPressure: Double
    public private(set) var time: Double = 0
    /// Steps taken so far.
    public private(set) var steps = 0
    /// Largest overpressure and positive-phase impulse seen so far in each cell.
    public private(set) var peak: [Double]
    public private(set) var impulse: [Double]
    /// When the overpressure in each cell first passed `arrivalThreshold`, s; −1 where it has not.
    public private(set) var arrival: [Double]
    /// The overpressure that marks the blast's arrival, Pa.
    public static let arrivalThreshold = 1_000.0
    /// Radii at which the pressure is recorded, and their records (time, absolute pressure).
    public var probes: [Double] = []
    public private(set) var records: [[(time: Double, pressure: Double)]] = []

    /// A sphere of hot gas holding `energy` joules and `mass` kilograms within `radius` metres,
    /// in still air holding `oxygen` kilograms of oxygen per kilogram; the grid reaches `extent`
    /// metres in `cells` cells.
    public init(
        mass: Double, energy totalEnergy: Double, radius: Double, extent: Double, cells: Int, gamma: Double,
        ambientDensity: Double, ambientPressure: Double, thermallyPerfect: Bool = false,
        afterburn: Afterburn? = nil, oxygenInAir: Double = 0.232, products jwl: JWL? = nil
    ) {
        cellSize = extent / Double(cells)
        gas = Gas(gamma: gamma, thermallyPerfect: thermallyPerfect, products: jwl)
        setup = Setup(
            mass: mass, energy: totalEnergy, radius: radius, extent: extent, cells: cells, gas: gas,
            ambientDensity: ambientDensity, ambientPressure: ambientPressure, afterburn: afterburn,
            oxygenInAir: oxygenInAir)
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
        products = Array(repeating: 0, count: cells)
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
            if jwl != nil { products[i] = inside * mass / volume }
        }
    }

    /// Density, velocity and pressure in cell `i`.
    private func primitive(_ i: Int) -> SIMD3<Double> {
        let rho = max(density[i], 1e-9)
        let u = momentum[i] / rho
        guard gas.products != nil else {
            let p = max(gas.pressure(density: rho, internalEnergy: energy[i] - 0.5 * rho * u * u), 1e-3)
            return SIMD3(rho, u, p)
        }
        let p = gas.pressure(density: rho, internalEnergy: energy[i] - 0.5 * rho * u * u, products: share(i))
        return SIMD3(rho, u, max(p, 1e-3))
    }

    /// The share of cell `i`'s mass that is detonation products; below a billionth, none (the
    /// air's own law, and its cost).
    private func share(_ i: Int) -> Double {
        let y = min(max(products[i] / max(density[i], 1e-9), 0), 1)
        return y < 1e-9 ? 0 : y
    }

    /// The products' share of the mass at `radius`, interpolated between cell centres.
    public func productShare(at radius: Double) -> Double {
        let x = radius / cellSize - 0.5
        let i = min(max(Int(x.rounded(.down)), 0), density.count - 1)
        let j = min(i + 1, density.count - 1)
        let t = min(max(x - Double(i), 0), 1)
        let rho = density[i] + t * (density[j] - density[i])
        let y = min(max((products[i] + t * (products[j] - products[i])) / max(rho, 1e-9), 0), 1)
        return y < 1e-9 ? 0 : y
    }

    /// The radius of the leading shock: the outermost cell 1% above ambient pressure.
    public var shockRadius: Double { shockRadius((0..<density.count).map(primitive)) }

    private func shockRadius(_ w: [SIMD3<Double>]) -> Double {
        for i in stride(from: w.count - 1, through: 0, by: -1) where w[i].z > 1.01 * ambientPressure {
            return (Double(i) + 1) * cellSize
        }
        return 0
    }

    private func flux(_ l: SIMD3<Double>, _ r: SIMD3<Double>) -> SIMD3<Double> {
        func energy(_ w: SIMD3<Double>) -> Double {
            gas.internalEnergy(density: w.x, pressure: w.z) + 0.5 * w.x * w.y * w.y
        }
        func physical(_ w: SIMD3<Double>, _ e: Double) -> SIMD3<Double> {
            SIMD3(w.x * w.y, w.x * w.y * w.y + w.z, (e + w.z) * w.y)
        }
        // Each side's total energy once: the gas law's exponentials are most of the cost.
        let el = energy(l)
        let er = energy(r)
        let gl = gas.ratio(density: l.x, pressure: l.z)
        let gr = gas.ratio(density: r.x, pressure: r.z)
        let cl = (gl * l.z / l.x).squareRoot()
        let cr = (gr * r.z / r.x).squareRoot()
        let sl = l.x.squareRoot()
        let sr = r.x.squareRoot()
        let uRoe = (sl * l.y + sr * r.y) / (sl + sr)
        let hl = (el + l.z) / l.x
        let hr = (er + r.z) / r.x
        let hRoe = (sl * hl + sr * hr) / (sl + sr)
        let gRoe = (sl * gl + sr * gr) / (sl + sr)
        let cRoe = max((gRoe - 1) * (hRoe - 0.5 * uRoe * uRoe), 1e-12).squareRoot()
        let waveL = min(l.y - cl, uRoe - cRoe)
        let waveR = max(r.y + cr, uRoe + cRoe)
        if waveL >= 0 { return physical(l, el) }
        if waveR <= 0 { return physical(r, er) }
        let ml = l.x * (waveL - l.y)
        let mr = r.x * (waveR - r.y)
        let star = (r.z - l.z + l.y * ml - r.y * mr) / (ml - mr)
        if star >= 0 {
            let factor = ml / (waveL - star)
            let starState = SIMD3(
                factor, factor * star, factor * (el / l.x + (star - l.y) * (star + l.z / ml)))
            return physical(l, el) + waveL * (starState - SIMD3(l.x, l.x * l.y, el))
        }
        let factor = mr / (waveR - star)
        let starState = SIMD3(factor, factor * star, factor * (er / r.x + (star - r.y) * (star + r.z / mr)))
        return physical(r, er) + waveR * (starState - SIMD3(r.x, r.x * r.y, er))
    }

    /// The HLLC flux between a mixture of products `yl` on the left and `yr` on the right, with
    /// Davis's bounds on the waves, as the Roe-averaged sound speed of an ideal gas does not hold.
    private func flux(_ l: SIMD3<Double>, _ r: SIMD3<Double>, products yl: Double, _ yr: Double) -> SIMD3<
        Double
    > {
        let il = gas.internalEnergy(density: l.x, pressure: l.z, products: yl)
        let ir = gas.internalEnergy(density: r.x, pressure: r.z, products: yr)
        let el = il + 0.5 * l.x * l.y * l.y
        let er = ir + 0.5 * r.x * r.y * r.y
        func physical(_ w: SIMD3<Double>, _ e: Double) -> SIMD3<Double> {
            SIMD3(w.x * w.y, w.x * w.y * w.y + w.z, (e + w.z) * w.y)
        }
        func sound(_ w: SIMD3<Double>, _ heat: Double, _ y: Double) -> Double {
            guard y > 0 else { return (gas.ratio(density: w.x, pressure: w.z) * w.z / w.x).squareRoot() }
            return gas.soundSquared(density: w.x, specific: heat / w.x, pressure: w.z, products: y)
                .squareRoot()
        }
        let cl = sound(l, il, yl)
        let cr = sound(r, ir, yr)
        let waveL = min(l.y - cl, r.y - cr)
        let waveR = max(l.y + cl, r.y + cr)
        if waveL >= 0 { return physical(l, el) }
        if waveR <= 0 { return physical(r, er) }
        let ml = l.x * (waveL - l.y)
        let mr = r.x * (waveR - r.y)
        let star = (r.z - l.z + l.y * ml - r.y * mr) / (ml - mr)
        if star >= 0 {
            let factor = ml / (waveL - star)
            let starState = SIMD3(
                factor, factor * star, factor * (el / l.x + (star - l.y) * (star + l.z / ml)))
            return physical(l, el) + waveL * (starState - SIMD3(l.x, l.x * l.y, el))
        }
        let factor = mr / (waveR - star)
        let starState = SIMD3(factor, factor * star, factor * (er / r.x + (star - r.y) * (star + r.z / mr)))
        return physical(r, er) + waveR * (starState - SIMD3(r.x, r.x * r.y, er))
    }

    /// Advances until the shock reaches `radius` metres, or the clock `limit` seconds.
    public mutating func run(toShockRadius radius: Double, until limit: Double = .infinity, cfl: Double = 0.4)
    {
        let n = density.count
        records = probes.map { _ in [] }
        var guardSteps = 0
        // The primitive state, once a step: the shock's reach, the step and the records all read it.
        var w = (0..<n).map(primitive)
        while shockRadius(w) < radius && time < limit && guardSteps < 2_000_000 {
            guardSteps += 1
            steps += 1
            var fastest = 1e-6
            let ratios =
                gas.products == nil
                ? w.map { gas.ratio(density: $0.x, pressure: $0.z) }
                : (0..<n).map { i in
                    let y = share(i)
                    guard y > 0 else { return gas.ratio(density: w[i].x, pressure: w[i].z) }
                    let specific = (energy[i] - 0.5 * w[i].x * w[i].y * w[i].y) / w[i].x
                    return w[i].x
                        * gas.soundSquared(density: w[i].x, specific: specific, pressure: w[i].z, products: y)
                        / w[i].z
                }
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
            var productFlux = Array(repeating: 0.0, count: gas.products == nil ? 0 : n + 1)
            for face in 1...n {
                let left = hi[face - 1]
                let right = face < n ? lo[face] : hi[n - 1]
                if gas.products == nil {
                    fluxes[face] = flux(left, right)
                } else {
                    fluxes[face] = flux(left, right, products: share(face - 1), share(min(face, n - 1)))
                    let upwind = fluxes[face].x >= 0 ? face - 1 : min(face, n - 1)
                    productFlux[face] = fluxes[face].x / max(density[upwind], 1e-9) * products[upwind]
                }
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
                if gas.products != nil {
                    products[i] = max(
                        products[i] - dt * (areaOut * productFlux[i + 1] - areaIn * productFlux[i]) / volume,
                        0)
                }
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
                if gas.products != nil { mix(&products, diffusivity: afterburn.diffusivity, dt: dt) }
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
            w = (0..<n).map(primitive)
            for i in 0..<n {
                let overpressure = w[i].z - ambientPressure
                peak[i] = max(peak[i], overpressure)
                impulse[i] += max(overpressure, 0) * dt
                if arrival[i] < 0, overpressure > Self.arrivalThreshold { arrival[i] = time }
            }
            for (k, r) in probes.enumerated() {
                let s = state(at: r)
                let rho = max(s.x, 1e-9)
                let p =
                    gas.products == nil
                    ? gas.pressure(density: rho, internalEnergy: s.z - 0.5 * s.y * s.y / rho)
                    : gas.pressure(
                        density: rho, internalEnergy: s.z - 0.5 * s.y * s.y / rho,
                        products: productShare(at: r))
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

    /// A hash of the solution's every bit (state, species, records and clock), for checking that
    /// a change to the solver leaves it exactly as it was.
    public var digest: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for field in [density, momentum, energy, fuel, oxygen, peak, impulse, arrival, [time]] {
            for value in field {
                hash = (hash ^ value.bitPattern) &* 0x100_0000_01b3
            }
        }
        return hash
    }

    /// Peak overpressure and positive impulse at `radius`, interpolated between cell centres.
    public func extremes(at radius: Double) -> SIMD2<Double> {
        let x = radius / cellSize - 0.5
        let i = min(max(Int(x.rounded(.down)), 0), density.count - 1)
        let j = min(i + 1, density.count - 1)
        let t = min(max(x - Double(i), 0), 1)
        return SIMD2(peak[i] + t * (peak[j] - peak[i]), impulse[i] + t * (impulse[j] - impulse[i]))
    }

    /// When the blast arrived at `radius`, s, interpolated between cell centres where it has
    /// reached both; nil where it has not arrived.
    public func arrival(at radius: Double) -> Double? {
        let x = radius / cellSize - 0.5
        let i = min(max(Int(x.rounded(.down)), 0), arrival.count - 1)
        let j = min(i + 1, arrival.count - 1)
        let t = min(max(x - Double(i), 0), 1)
        guard arrival[i] >= 0 else { return nil }
        return arrival[j] >= 0 ? arrival[i] + t * (arrival[j] - arrival[i]) : arrival[i]
    }

    /// Density, radial momentum and total energy per volume at `radius`, interpolated between
    /// cell centres.
    public func state(at radius: Double) -> SIMD3<Double> {
        let x = radius / cellSize - 0.5
        let i = min(max(Int(x.rounded(.down)), 0), density.count - 1)
        let j = min(i + 1, density.count - 1)
        let t = min(max(x - Double(i), 0), 1)
        let a = SIMD3(density[i], momentum[i], energy[i])
        let b = SIMD3(density[j], momentum[j], energy[j])
        return a + t * (b - a)
    }

    /// Unburnt products and oxygen per volume at `radius`, interpolated between cell centres.
    public func species(at radius: Double) -> SIMD2<Double> {
        let x = radius / cellSize - 0.5
        let i = min(max(Int(x.rounded(.down)), 0), density.count - 1)
        let j = min(i + 1, density.count - 1)
        let t = min(max(x - Double(i), 0), 1)
        return SIMD2(fuel[i] + t * (fuel[j] - fuel[i]), oxygen[i] + t * (oxygen[j] - oxygen[i]))
    }

    /// The solution sampled over the grid cell (`i`, `j`, `k`) of `dx` m, centred on the charge
    /// at `centre`, at `samples` points a side: the sums of the state (density, radial momentum,
    /// total energy), of the momentum as a vector and, with afterburning, of the products and
    /// oxygen, over the points within `reach` m of the centre, and how many those were.
    public func sample(
        cell i: Int, _ j: Int, _ k: Int, cellSize dx: Float, centre: SIMD3<Float>, reach: Double, samples: Int
    ) -> (state: SIMD3<Double>, momentum: SIMD3<Double>, species: SIMD2<Double>, count: Int) {
        var sum = SIMD3<Double>.zero
        var momentum = SIMD3<Double>.zero
        var carried = SIMD2<Double>.zero
        var counted = 0
        for c in 0..<samples {
            for b in 0..<samples {
                for a in 0..<samples {
                    let offset = (SIMD3(Float(a), Float(b), Float(c)) + 0.5) / Float(samples)
                    let point = (SIMD3(Float(i), Float(j), Float(k)) + offset) * dx
                    let arm = SIMD3<Double>(point - centre)
                    let r = simd_length(arm)
                    guard r < reach else { continue }
                    let s = state(at: r)
                    sum += s
                    momentum += r > 1e-9 ? s.y * arm / r : .zero
                    if afterburn != nil { carried += species(at: r) }
                    counted += 1
                }
            }
        }
        return (sum, momentum, carried, counted)
    }
}

extension SphericalBlast {
    private struct Key: Hashable {
        var setup: Setup
        var probes: [Double]
        var radius: Double
        var limit: Double
    }

    /// The last few solutions, newest last: runs of one scene, and tests of alike scenes, start
    /// from one charge again and again.
    private static let solutions = Mutex<[(key: Key, blast: SphericalBlast)]>([])
    private static let kept = 4

    /// This blast, unrun, run until the shock reaches `radius` metres or the clock `limit` seconds
    /// (`run(toShockRadius:until:)`), or the same solution kept from an earlier call that asked for
    /// it exactly.
    public func solved(toShockRadius radius: Double, until limit: Double = .infinity) -> SphericalBlast {
        precondition(steps == 0, "Only an unrun blast can be solved")
        let key = Key(setup: setup, probes: probes, radius: radius, limit: limit)
        if let kept = Self.solutions.withLock({ list in list.last { $0.key == key }?.blast }) { return kept }
        var blast = self
        blast.run(toShockRadius: radius, until: limit)
        Self.solutions.withLock { list in
            list.removeAll { $0.key == key }
            list.append((key, blast))
            if list.count > Self.kept { list.removeFirst(list.count - Self.kept) }
        }
        return blast
    }
}
