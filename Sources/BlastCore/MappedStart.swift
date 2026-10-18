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

    /// Lays down each of `mappings` from its own one-dimensional solution, all stopped at one time:
    /// the earliest at which any of their shocks reaches its radius, the others then still within
    /// theirs (and no later than `mappedStartLatest`). Each is laid in the cells nearer it than any
    /// other of the scene's charges at `positions`, which its radius, at most half the way to the
    /// nearest, keeps it to. Returns the solutions, in the order of `mappings`.
    func depositMapped(_ mappings: [ChargeMapping], among positions: [SIMD3<Float>], probes: [SIMD3<Float>])
        -> [SphericalBlast]
    {
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
        let start = solved.map(\.time).min() ?? 0
        for k in solved.indices where solved[k].time > start {
            solved[k] = unrun[k].solved(toShockRadius: Double(mappings[k].radius), until: start)
        }
        for (blast, mapping) in zip(solved, mappings) {
            lay(blast, charge: mapping.charge, radius: mapping.radius, among: positions)
        }
        return solved
    }

    /// Whether `point` is nearer `centre` than any of `positions` other than itself.
    private func nearest(_ point: SIMD3<Float>, to centre: SIMD3<Float>, among positions: [SIMD3<Float>])
        -> Bool
    {
        let own = simd_distance_squared(point, centre)
        return !positions.contains { $0 != centre && simd_distance_squared(point, $0) < own }
    }

    /// Lays `blast`, the solution for `charge` mapped `radius` m out, onto the cells within reach
    /// of it and nearer it than any other of the charges at `positions`.
    private func lay(_ blast: SphericalBlast, charge: Charge, radius: Float, among positions: [SIMD3<Float>])
    {
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

    /// After `restart()`, sets the clock to the time the mapped solutions took, and gives the cells
    /// and gauges inside each one's reach (and nearer its charge than any other of `positions`) the
    /// peaks, impulses and histories it recorded.
    func recordMapped(
        _ blasts: [SphericalBlast], mappings: [ChargeMapping], among positions: [SIMD3<Float>],
        gauges: [SIMD3<Float>]
    ) {
        startClock(at: blasts.map(\.time).min() ?? 0)
        mappedStart = zip(blasts, mappings).map { ($0, $1.charge.position, $1.radius) }
        let grid = self.grid
        let dx = grid.cellSize
        let shared = positions.count > 1
        setFields { peak, impulse in
            defer {
                // Patches placed already (at the restart) took their coarse cells' impulse then,
                // before this: they take it again, or their cells would rebuild it from nothing.
                refinement?.reseedImpulseBase(from: UnsafeBufferPointer(impulse), grid: grid)
            }
            for (blast, mapping) in zip(blasts, mappings) {
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
                            peak[grid.index(i, j, k)] = Float(extremes.x)
                            impulse[grid.index(i, j, k)] = Float(extremes.y)
                        }
                    }
                }
            }
        }
        for (blast, mapping) in zip(blasts, mappings) {
            let charge = mapping.charge
            for (index, gauge) in gauges.enumerated()
            where simd_distance(gauge, charge.position) < mapping.radius {
                if shared, !nearest(gauge, to: charge.position, among: positions) { continue }
                prependGaugeHistory(
                    index,
                    blast.records[index].map { GaugeSample(time: $0.time, pressure: Float($0.pressure)) })
            }
        }
    }
}
