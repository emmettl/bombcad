import Foundation
import RadialBlast
import simd

extension BlastSolver {
    /// Lays down `charge` as its blast is when the shock has spread to `radius` metres, from a
    /// one-dimensional solution started at the charge's own size, and returns the solution, from
    /// which the time it took, and the peaks, impulses and histories at points the shock has
    /// already passed, are taken (`recordMapped`). A charge on `mirrors` reflecting faces (the
    /// ground, a model's mirror planes) spreads as one of 2^`mirrors` times the mass in free air,
    /// of which the part on the domain's side is laid down. Cells farther than `radius` are left as they are; nothing solid may lie within it.
    /// The one-dimensional solution, unrun, a charge of `charge` takes to be mapped out to
    /// `radius` m under `configuration`: from a sphere of TNT's density, on a radial grid of a
    /// twentieth of its radius (2,000 to 20,000 cells) reaching 1.6 times `radius`.
    static func mappedSolution(
        _ charge: Charge, radius: Float, mirrors: Int, configuration: SolverConfiguration,
        ambientDensity: Float, products: SphericalBlast.JWL? = nil, refined: Int = 1
    ) -> SphericalBlast {
        let multiplier = Double(1 << mirrors)
        let mass = Double(charge.mass) * multiplier
        let energy = Double(charge.energy) * multiplier
        // With the products' own law, the charge at the explosive's own density.
        let size = cbrt(3 * mass / (4 * Double.pi * (products?.density ?? 1600)))
        let extent = Double(radius) * 1.6
        let cells = min(max(Int(extent / (size / 20)), 2000), 20000) * refined
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
            oxygenInAir: Double(Self.oxygenInAir), products: products)
    }

    /// The one-dimensional start alone, for studying it: a surface burst of `mass` kg on rigid
    /// ground under `configuration`, unrun, reaching `reach` m/kg^(1/3), with the detonation
    /// products' own equation of state `products` (nil: as the air's gas), on `refined` times the
    /// cells the start uses.
    public static func mappedStartStudy(
        mass: Float, reach: Float, configuration: SolverConfiguration, products: SphericalBlast.JWL?,
        refined: Int = 1
    ) -> SphericalBlast {
        mappedSolution(
            Charge(mass: mass, position: .zero), radius: reach * cbrt(mass), mirrors: 1,
            configuration: configuration, ambientDensity: 1.225, products: products, refined: refined)
    }

    /// The wall time, cells and steps of the one-dimensional solution a charge of `mass` kg on the
    /// ground takes to be mapped `cells` cells of `cellSize` m out, under `configuration`.
    public static func mappedStartCost(
        mass: Float, cellSize: Float, cells mappedCells: Float, configuration: SolverConfiguration
    ) -> (seconds: Double, cells: Int, steps: Int, digest: UInt64) {
        let radius = mappedCells * cellSize
        var blast = mappedSolution(
            Charge(mass: mass, position: .zero), radius: radius, mirrors: 1, configuration: configuration,
            ambientDensity: 1.225)
        let start = Date()
        blast.run(toShockRadius: Double(radius))
        return (Date().timeIntervalSince(start), blast.density.count, blast.steps, blast.digest)
    }

    /// Each of `mappings` solved in one dimension, and the time on the run's clock the grid starts
    /// at: the earliest at which any of their shocks, counted from its charge's firing time,
    /// reaches its radius (no later, from its firing, than `mappedStartLatest`). Those that fire
    /// before then are solved to then, the others still within their radius; those that fire
    /// after, to their radius, to be laid down when the grid's clock reaches that
    /// (`fireDueCharges`). Returns the solutions in the order of `mappings`.
    func solveMapped(_ mappings: [ChargeMapping], probes: [SIMD3<Float>]) -> (
        solutions: [SphericalBlast], start: Double
    ) {
        let unrun = mappings.map { mapping -> SphericalBlast in
            var blast = Self.mappedSolution(
                mapping.charge, radius: mapping.radius, mirrors: mapping.mirrors,
                configuration: configuration,
                ambientDensity: ambientDensity, products: configuration.mappedChargeProducts ? .tnt : nil)
            blast.probes = probes.map { Double(simd_distance($0, mapping.charge.position)) }
            return blast
        }
        // Solved once for each charge, gas and reach (it is deterministic): a scene run again, or
        // another alike, starts from the same solution, and alike charges share one.
        var solved = zip(unrun, mappings).map { blast, mapping in
            blast.solved(toShockRadius: Double(mapping.radius), until: mappedStartLatest ?? .infinity)
        }
        let start = zip(solved, mappings).map { $0.time + $1.charge.firingTime }.min() ?? 0
        for k in solved.indices {
            let delay = mappings[k].charge.firingTime
            if delay < start, solved[k].time + delay > start {
                solved[k] = unrun[k].solved(toShockRadius: Double(mappings[k].radius), until: start - delay)
            }
        }
        return (solved, start)
    }

    /// Lays down each solution of `laid` in the cells nearer its charge than any other of the
    /// scene's charges at `positions`, which its radius, at most half the way to the nearest,
    /// keeps it to.
    func layMapped(_ laid: [(blast: SphericalBlast, mapping: ChargeMapping)], among positions: [SIMD3<Float>])
    {
        for (blast, mapping) in laid {
            lay(blast, charge: mapping.charge, radius: mapping.radius, among: positions)
        }
    }

    /// Whether `point` is nearer `centre` than any of `positions` other than itself.
    func nearest(_ point: SIMD3<Float>, to centre: SIMD3<Float>, among positions: [SIMD3<Float>])
        -> Bool
    {
        let own = simd_distance_squared(point, centre)
        return !positions.contains { $0 != centre && simd_distance_squared(point, $0) < own }
    }

    /// Lays `blast`, the solution for `charge` mapped `radius` m out, onto the cells within reach
    /// of it and nearer it than any other of the charges at `positions`.
    func lay(_ blast: SphericalBlast, charge: Charge, radius: Float, among positions: [SIMD3<Float>]) {
        let grid = self.grid
        let dx = grid.cellSize
        let reach = radius + dx
        let low = grid.cell(containing: charge.position - reach)
        let high = grid.cell(containing: charge.position + reach)
        let samples = 4
        let shared = positions.count > 1
        var species: [(index: Int, value: SIMD2<Float>)] = []
        mutateState { cells in
            for k in low.k...high.k {
                for j in low.j...high.j {
                    for i in low.i...high.i where !isSolid(i, j, k) {
                        if shared,
                            !nearest(
                                (SIMD3(Float(i), Float(j), Float(k)) + 0.5) * dx, to: charge.position,
                                among: positions)
                        {
                            continue
                        }
                        let (sum, momentum, carried, counted) = blast.sample(
                            cell: i, j, k, cellSize: dx, centre: charge.position, reach: Double(radius) * 1.5,
                            samples: samples)
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
    }

    /// After `restart()`, sets the clock to `start`, and gives the cells and gauges inside each laid
    /// solution's reach (and nearer its charge than any other of `positions`) the peaks, impulses
    /// and histories it recorded, at their times from its charge's firing.
    func recordMapped(
        _ laid: [(blast: SphericalBlast, mapping: ChargeMapping)], among positions: [SIMD3<Float>],
        gauges: [SIMD3<Float>], start: Double
    ) {
        startClock(at: start)
        mappedStart = laid.map {
            ($0.blast, $0.mapping.charge.position, $0.mapping.radius, $0.mapping.charge, $0.mapping.mirrors)
        }
        setFields { peak, impulse in
            defer {
                // Patches placed already (at the restart) took their coarse cells' impulse then,
                // before this: they take it again, or their cells would rebuild it from nothing.
                refinement?.reseedImpulseBase(from: UnsafeBufferPointer(impulse), grid: grid)
            }
            for (blast, mapping) in laid {
                record(blast, mapping: mapping, among: positions, peak: peak, impulse: impulse, adding: false)
            }
        }
        for (blast, mapping) in laid {
            recordGauges(blast, mapping: mapping, among: positions, gauges: gauges)
        }
    }

    /// The cells within `mapping`'s radius (and nearer its charge than any other of `positions`)
    /// given `blast`'s peaks and impulses: in place of theirs, or, `adding`, their peak the larger
    /// and its impulse added to theirs.
    func record(
        _ blast: SphericalBlast, mapping: ChargeMapping, among positions: [SIMD3<Float>],
        peak: UnsafeMutableBufferPointer<Float>, impulse: UnsafeMutableBufferPointer<Float>, adding: Bool
    ) {
        let grid = self.grid
        let dx = grid.cellSize
        let shared = positions.count > 1
        let charge = mapping.charge
        let radius = mapping.radius
        let low = grid.cell(containing: charge.position - radius)
        let high = grid.cell(containing: charge.position + radius)
        for k in low.k...high.k {
            for j in low.j...high.j {
                for i in low.i...high.i {
                    let centre = (SIMD3(Float(i), Float(j), Float(k)) + 0.5) * dx
                    let r = Double(simd_distance(centre, charge.position))
                    guard r < Double(radius) else { continue }
                    if shared, !nearest(centre, to: charge.position, among: positions) { continue }
                    let extremes = blast.extremes(at: r)
                    let index = grid.index(i, j, k)
                    peak[index] = adding ? max(peak[index], Float(extremes.x)) : Float(extremes.x)
                    impulse[index] = (adding ? impulse[index] : 0) + Float(extremes.y)
                }
            }
        }
    }

    /// The gauges within `mapping`'s radius (and nearer its charge than any other of `positions`)
    /// given `blast`'s records, at their times from its charge's firing, in place of what they
    /// recorded over the same time.
    func recordGauges(
        _ blast: SphericalBlast, mapping: ChargeMapping, among positions: [SIMD3<Float>],
        gauges: [SIMD3<Float>]
    ) {
        let charge = mapping.charge
        let delay = charge.firingTime
        for (index, gauge) in gauges.enumerated() where simd_distance(gauge, charge.position) < mapping.radius
        {
            if positions.count > 1, !nearest(gauge, to: charge.position, among: positions) { continue }
            let samples = blast.records[index].map {
                GaugeSample(time: $0.time + delay, pressure: Float($0.pressure))
            }
            guard let first = samples.first, let last = samples.last else { continue }
            spliceGaugeHistory(index, samples, from: first.time, through: last.time)
        }
    }
}
