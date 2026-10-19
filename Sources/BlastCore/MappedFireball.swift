import Foundation
import RadialBlast
import simd

extension BlastSolver {
    /// The most voxels an early frame's box holds: finer than the grid where the fireball is
    /// small, its thin hot layers sampled eight times a voxel.
    static let earlyFrameVoxels = 1 << 18
    /// Samples a side each early frame's voxel takes of the one-dimensional solution.
    static let earlyFrameSamples = 2

    /// The fireball at each of `times` before the grid's clock starts, from the mapped start's
    /// one-dimensional solutions (solved again from the start, kept at those times), laid onto a
    /// lattice for the thermal radiation as the grid's frames are; empty where the run did not
    /// start mapped, or for times from its start on. In a run's thermal record they come before
    /// the grid's own frames, so that it starts at detonation.
    public func earlyFireballFrames(for spec: ThermalSpec, at times: [Double]) -> [FireballFrame] {
        // The grid's clock started when the first laid solution stopped, each counted from its
        // charge's firing; a charge fired after a frame's time is not yet in it.
        guard let start = mappedStart.map({ $0.blast.time + $0.charge.firingTime }).min() else { return [] }
        let wanted = times.filter { $0 > 0 && $0 < start - 1e-9 }.sorted()
        guard !wanted.isEmpty else { return [] }
        let solutions = mappedStart.map { entry -> (blast: SphericalBlast, times: [Double]) in
            let delay = entry.charge.firingTime
            var blast = Self.mappedSolution(
                entry.charge, radius: entry.radius, mirrors: entry.mirrors, configuration: configuration,
                ambientDensity: ambientDensity, products: configuration.mappedChargeProducts ? .tnt : nil)
            let own = wanted.filter { $0 > delay }
            blast.snapshotTimes = own.map { $0 - delay }
            return (blast.solved(toShockRadius: Double(entry.radius), until: start - delay), own)
        }
        return wanted.map { time in
            earlyFrame(
                at: time,
                profiles: zip(solutions, mappedStart).compactMap { solution, entry in
                    guard let n = solution.times.firstIndex(of: time), n < solution.blast.snapshots.count
                    else {
                        return nil
                    }
                    return profile(
                        solution.blast.snapshots[n], cellSize: solution.blast.cellSize, centre: entry.centre,
                        mass: Double(entry.charge.mass) * Double(1 << entry.mirrors), spec: spec)
                }, spec: spec)
        }
    }

    /// A snapshot's temperatures, as the grid's air model reads its state, and where its luminous
    /// gas ends. Its unburnt products, which the thermal volume makes soot of, are taken only
    /// within the products' own gas, the sphere holding the charge's `mass` (with its mirrors): the
    /// eddy diffusivity spreads them, a tag on the gas, out to the shock and past it from the start,
    /// where a real fireball's mixing grows from the contact. Their soot would blacken the shock's
    /// layer of air with a cooler skin, and hide the 6,000 K and more behind it that makes the
    /// first flash.
    private func profile(
        _ snapshot: SphericalBlast.Snapshot, cellSize: Double, centre: SIMD3<Float>, mass: Double,
        spec: ThermalSpec
    ) -> RadialVoxels.Profile {
        let model = configuration.airModel
        let temperature = snapshot.density.indices.map { i -> Float in
            let rho = max(snapshot.density[i], 1e-9)
            let p = model.pressure(
                density: rho, internalEnergy: rho * snapshot.specificEnergy[i], gamma: configuration.gamma)
            return model.temperature(density: rho, pressure: p)
        }
        let last = temperature.lastIndex { $0 >= spec.luminousTemperature }
        // The contact: the first cell whose sphere holds the charge's mass.
        var held = 0.0
        var contact = snapshot.density.count
        for i in snapshot.density.indices {
            let shell = 4 * Double.pi / 3 * (pow(Double(i + 1), 3) - pow(Double(i), 3)) * pow(cellSize, 3)
            held += shell * Double(snapshot.density[i])
            if held >= mass {
                contact = i
                break
            }
        }
        let unburnt = snapshot.unburnt.indices.map { $0 <= contact ? snapshot.unburnt[$0] : 0 }
        return RadialVoxels.Profile(
            centre: centre, cellSize: cellSize, temperature: temperature, unburnt: unburnt,
            density: snapshot.density, reach: last.map { Float(Double($0 + 1) * cellSize) } ?? 0)
    }

    /// One early frame from the charges' `profiles` at `time`.
    private func earlyFrame(at time: Double, profiles: [RadialVoxels.Profile], spec: ThermalSpec)
        -> FireballFrame
    {
        let lit = profiles.filter { $0.reach > 0 }
        let size = SIMD3(Float(grid.nx), Float(grid.ny), Float(grid.nz)) * grid.cellSize
        guard !lit.isEmpty else {
            return FireballFrame(time: time, volume: 0, centre: .zero, temperature: 0, hottest: 0)
        }
        var low = SIMD3<Float>(repeating: .infinity)
        var high = -low
        for profile in lit {
            low = simd_min(low, profile.centre - profile.reach)
            high = simd_max(high, profile.centre + profile.reach)
        }
        low = simd_max(low, .zero)
        high = simd_min(high, size)
        let extent = simd_max(high - low, SIMD3(repeating: 1e-6))
        var voxel = Float(
            cbrt(
                Double(extent.x * extent.y * extent.z) / Double(earlyFrameVoxelLimit ?? Self.earlyFrameVoxels)
            ))
        var first = SIMD3<Int32>.zero
        var counts = SIMD3<Int32>.zero
        repeat {
            voxel *= 1.01
            first = SIMD3<Int32>((low / voxel).rounded(.down))
            counts = SIMD3<Int32>((high / voxel).rounded(.up)) &- first
            counts = simd_max(counts, SIMD3(repeating: 1))
        } while Int(counts.x) * Int(counts.y) * Int(counts.z)
            > (earlyFrameVoxelLimit ?? Self.earlyFrameVoxels)
        let laid = RadialVoxels.lay(
            lit, luminous: spec.luminousTemperature, voxelSize: voxel, first: first, counts: counts,
            samples: earlyFrameSampleCount ?? Self.earlyFrameSamples)
        guard laid.volume > 0 else {
            return FireballFrame(time: time, volume: 0, centre: .zero, temperature: 0, hottest: 0)
        }
        // The shells themselves, for the volume to march exactly.
        let spheres =
            spec.fireball == .volume
            ? lit.map { profile -> FireballSphere in
                let count = min(
                    Int((Double(profile.reach) / profile.cellSize).rounded()), profile.temperature.count)
                return FireballSphere(
                    centre: profile.centre, shellSize: Float(profile.cellSize),
                    temperatures: profile.temperature[..<count].map {
                        $0 >= spec.luminousTemperature ? $0 : 0
                    },
                    products: configuration.afterburning
                        ? Array(profile.unburnt[..<count])
                        : [Float](
                            repeating: 0, count: count),
                    airAbsorption: profile.absorption.isEmpty
                        ? [Float](repeating: 0, count: count) : Array(profile.absorption[..<count]))
            } : nil
        let cells =
            spec.fireball == .volume
            ? LuminousCells(
                voxelSize: voxel, first: first, counts: counts, fills: laid.fills,
                temperatures: laid.temperatures,
                products: configuration.afterburning ? laid.unburnt.map { Float16($0) } : nil,
                airAbsorption: laid.airAbsorption.map { Float16(min($0, 65504)) }) : nil
        return FireballFrame(
            time: time, volume: laid.volume, centre: SIMD3<Float>(laid.moment / laid.volume),
            temperature: Float(pow(laid.fourth / laid.volume, 0.25)), hottest: laid.hottest, cells: cells,
            spheres: spheres)
    }
}
