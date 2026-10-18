import Foundation
import RadialBlast
import simd

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
        ambientDensity: Float, products: SphericalBlast.JWL? = nil, refined: Int = 1
    ) -> SphericalBlast {
        let multiplier: Double = onGround ? 2 : 1
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
            Charge(mass: mass, position: .zero), radius: reach * cbrt(mass), onGround: true,
            configuration: configuration, ambientDensity: 1.225, products: products, refined: refined)
    }

    /// The wall time, cells and steps of the one-dimensional solution a charge of `mass` kg on the
    /// ground takes to be mapped `cells` cells of `cellSize` m out, under `configuration`.
    public static func mappedStartCost(
        mass: Float, cellSize: Float, cells mappedCells: Float, configuration: SolverConfiguration
    ) -> (seconds: Double, cells: Int, steps: Int, digest: UInt64) {
        let radius = mappedCells * cellSize
        var blast = mappedSolution(
            Charge(mass: mass, position: .zero), radius: radius, onGround: true, configuration: configuration,
            ambientDensity: 1.225)
        let start = Date()
        blast.run(toShockRadius: Double(radius))
        return (Date().timeIntervalSince(start), blast.density.count, blast.steps, blast.digest)
    }

    func depositMapped(_ charge: Charge, radius: Float, onGround: Bool, probes: [SIMD3<Float>])
        -> SphericalBlast
    {
        var blast = Self.mappedSolution(
            charge, radius: radius, onGround: onGround, configuration: configuration,
            ambientDensity: ambientDensity, products: configuration.mappedChargeProducts ? .tnt : nil)
        blast.probes = probes.map { Double(simd_distance($0, charge.position)) }
        // Solved once for each charge, gas and reach (it is deterministic): a scene run again, or
        // another alike, starts from the same solution.
        blast = blast.solved(toShockRadius: Double(radius), until: mappedStartLatest ?? .infinity)

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
