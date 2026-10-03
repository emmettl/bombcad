import Foundation
import simd

/// The early life of a blast from a charge in free air, solved in one dimension (spherical
/// symmetry) on a fine radial grid: the same scheme as the air solver (MUSCL-Hancock with an
/// HLLC Riemann solver), in finite-volume form with the face areas 4 pi r^2 and the pressure's
/// geometric source. Started from the charge's own size, it resolves the shock while it is far
/// thinner than a cell of the 3D grid, and is then mapped onto that grid (see
/// `BlastSolver.depositMapped(_:)`), in place of the coarse "balloon".
struct SphericalBlast {
    let cellSize: Double
    var density: [Double]
    var momentum: [Double]
    var energy: [Double]
    let gamma: Double
    let ambientDensity: Double
    let ambientPressure: Double
    private(set) var time: Double = 0
    /// Largest overpressure and positive-phase impulse seen so far in each cell.
    private(set) var peak: [Double]
    private(set) var impulse: [Double]
    /// Radii at which the pressure is recorded, and their records (time, absolute pressure).
    var probes: [Double] = []
    private(set) var records: [[(time: Double, pressure: Double)]] = []

    /// A sphere of hot gas holding `energy` joules and `mass` kilograms within `radius` metres,
    /// in still air; the grid reaches `extent` metres in `cells` cells.
    init(
        mass: Double, energy totalEnergy: Double, radius: Double, extent: Double, cells: Int, gamma: Double,
        ambientDensity: Double, ambientPressure: Double
    ) {
        cellSize = extent / Double(cells)
        self.gamma = gamma
        self.ambientDensity = ambientDensity
        self.ambientPressure = ambientPressure
        let ambientEnergy = ambientPressure / (gamma - 1)
        let volume = 4 / 3 * Double.pi * radius * radius * radius
        peak = Array(repeating: 0, count: cells)
        impulse = Array(repeating: 0, count: cells)
        density = Array(repeating: ambientDensity, count: cells)
        momentum = Array(repeating: 0, count: cells)
        energy = Array(repeating: ambientEnergy, count: cells)
        for i in 0..<cells {
            // The fraction of the cell inside the sphere.
            let inner = Double(i) * cellSize
            let outer = inner + cellSize
            let inside =
                max(0, min(outer, radius) - inner) > 0
                ? (pow(min(outer, radius), 3) - pow(inner, 3)) / (pow(outer, 3) - pow(inner, 3)) : 0
            density[i] += inside * mass / volume
            energy[i] += inside * totalEnergy / volume
        }
    }

    private func primitive(_ i: Int) -> SIMD3<Double> {
        let rho = max(density[i], 1e-9)
        let u = momentum[i] / rho
        let p = max((gamma - 1) * (energy[i] - 0.5 * rho * u * u), 1e-3)
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
        func energy(_ w: SIMD3<Double>) -> Double { w.z / (gamma - 1) + 0.5 * w.x * w.y * w.y }
        func physical(_ w: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(w.x * w.y, w.x * w.y * w.y + w.z, (energy(w) + w.z) * w.y)
        }
        let cl = (gamma * l.z / l.x).squareRoot()
        let cr = (gamma * r.z / r.x).squareRoot()
        let sl = l.x.squareRoot()
        let sr = r.x.squareRoot()
        let uRoe = (sl * l.y + sr * r.y) / (sl + sr)
        let hl = (energy(l) + l.z) / l.x
        let hr = (energy(r) + r.z) / r.x
        let hRoe = (sl * hl + sr * hr) / (sl + sr)
        let cRoe = max((gamma - 1) * (hRoe - 0.5 * uRoe * uRoe), 1e-12).squareRoot()
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
            var fastest = 1e-6
            let w = (0..<n).map(primitive)
            for x in w { fastest = max(fastest, abs(x.y) + (gamma * x.z / x.x).squareRoot()) }
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
                h.z = x.z - half * (x.y * d.z + gamma * x.z * d.y)
                lo[i] = h - 0.5 * d
                hi[i] = h + 0.5 * d
                if min(lo[i].x, hi[i].x) <= 0 || min(lo[i].z, hi[i].z) <= 0 {
                    lo[i] = x
                    hi[i] = x
                }
            }
            // Fluxes through the faces; face 0 is the centre, where nothing passes.
            var fluxes = Array(repeating: SIMD3<Double>.zero, count: n + 1)
            for face in 1...n {
                let left = hi[face - 1]
                let right = face < n ? lo[face] : hi[n - 1]
                fluxes[face] = flux(left, right)
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
            }
            time += dt
            for i in 0..<n {
                let overpressure = primitive(i).z - ambientPressure
                peak[i] = max(peak[i], overpressure)
                impulse[i] += max(overpressure, 0) * dt
            }
            for (k, r) in probes.enumerated() {
                let s = state(at: r)
                let rho = max(s.x, 1e-9)
                let p = (gamma - 1) * (s.z - 0.5 * s.y * s.y / rho)
                records[k].append((time, p))
            }
        }
    }

    /// Peak overpressure and positive impulse at `radius`, interpolated between cell centres.
    func extremes(at radius: Double) -> SIMD2<Double> {
        let x = radius / cellSize - 0.5
        let i = min(max(Int(x.rounded(.down)), 0), density.count - 1)
        let j = min(i + 1, density.count - 1)
        let t = min(max(x - Double(i), 0), 1)
        return SIMD2(peak[i] + t * (peak[j] - peak[i]), impulse[i] + t * (impulse[j] - impulse[i]))
    }

    /// Density, radial velocity and pressure at `radius`, interpolated between cell centres.
    func state(at radius: Double) -> SIMD3<Double> {
        let x = radius / cellSize - 0.5
        let i = min(max(Int(x.rounded(.down)), 0), density.count - 1)
        let j = min(i + 1, density.count - 1)
        let t = min(max(x - Double(i), 0), 1)
        let a = SIMD3(density[i], momentum[i], energy[i])
        let b = SIMD3(density[j], momentum[j], energy[j])
        return a + t * (b - a)
    }
}

extension BlastSolver {
    /// Lays down `charge` as its blast is when the shock has spread to `radius` metres, from a
    /// one-dimensional solution started at the charge's own size, and returns the solution, from
    /// which the time it took, and the peaks, impulses and histories at points the shock has
    /// already passed, are taken (`recordMapped`). A charge on the ground (rigid, reflecting)
    /// spreads as one of twice the mass in free air, of which the half above the ground is laid
    /// down. Cells farther than `radius` are left as they are; nothing solid may lie within it.
    func depositMapped(_ charge: Charge, radius: Float, onGround: Bool, probes: [SIMD3<Float>])
        -> SphericalBlast
    {
        let multiplier: Double = onGround ? 2 : 1
        let mass = Double(charge.mass) * multiplier
        let energy = Double(charge.energy) * multiplier
        let size = cbrt(3 * mass / (4 * Double.pi * 1600))
        let extent = Double(radius) * 1.6
        let cells = min(max(Int(extent / (size / 20)), 2000), 20000)
        var blast = SphericalBlast(
            mass: mass, energy: energy, radius: size, extent: extent, cells: cells,
            gamma: Double(configuration.gamma), ambientDensity: Double(ambientDensity),
            ambientPressure: Double(configuration.ambientPressure))
        blast.probes = probes.map { Double(simd_distance($0, charge.position)) }
        blast.run(toShockRadius: Double(radius))

        let grid = self.grid
        let dx = grid.cellSize
        let reach = radius + dx
        let low = grid.cell(containing: charge.position - reach)
        let high = grid.cell(containing: charge.position + reach)
        let samples = 4
        mutateState { cells in
            for k in low.k...high.k {
                for j in low.j...high.j {
                    for i in low.i...high.i where !isSolid(i, j, k) {
                        var sum = SIMD3<Double>.zero
                        var momentum = SIMD3<Double>.zero
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
                    }
                }
            }
        }
        return blast
    }

    /// After `restart()`, sets the clock to the time the mapped solution took, and gives the
    /// cells and gauges inside its reach the peaks, impulses and histories it recorded.
    func recordMapped(_ blast: SphericalBlast, charge: Charge, radius: Float, gauges: [SIMD3<Float>]) {
        startClock(at: blast.time)
        let grid = self.grid
        let dx = grid.cellSize
        let low = grid.cell(containing: charge.position - radius)
        let high = grid.cell(containing: charge.position + radius)
        setFields { peak, impulse in
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
