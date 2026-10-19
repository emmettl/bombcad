import BlastModel
import Foundation
import RadialBlast
import simd

extension BlastSolver {
    /// The most voxels an early frame's box holds: finer than the grid where the fireball is
    /// small, its thin hot layers sampled eight times a voxel.
    static let earlyFrameVoxels = 1 << 18

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
                        spec: spec)
                }, spec: spec)
        }
    }

    /// A snapshot's temperatures, as the grid's air model reads its state, and where its luminous
    /// gas ends.
    private func profile(
        _ snapshot: SphericalBlast.Snapshot, cellSize: Double, centre: SIMD3<Float>, spec: ThermalSpec
    ) -> RadialVoxels.Profile {
        let model = configuration.airModel
        let temperature = snapshot.density.indices.map { i -> Float in
            let rho = max(snapshot.density[i], 1e-9)
            let p = model.pressure(
                density: rho, internalEnergy: rho * snapshot.specificEnergy[i], gamma: configuration.gamma)
            return model.temperature(density: rho, pressure: p)
        }
        let last = temperature.lastIndex { $0 >= spec.luminousTemperature }
        return RadialVoxels.Profile(
            centre: centre, cellSize: cellSize, temperature: temperature, unburnt: snapshot.unburnt,
            reach: last.map { Float(Double($0 + 1) * cellSize) } ?? 0)
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
        var voxel = Float(cbrt(Double(extent.x * extent.y * extent.z) / Double(Self.earlyFrameVoxels)))
        var first = SIMD3<Int32>.zero
        var counts = SIMD3<Int32>.zero
        repeat {
            voxel *= 1.01
            first = SIMD3<Int32>((low / voxel).rounded(.down))
            counts = SIMD3<Int32>((high / voxel).rounded(.up)) &- first
            counts = simd_max(counts, SIMD3(repeating: 1))
        } while Int(counts.x) * Int(counts.y) * Int(counts.z) > Self.earlyFrameVoxels
        let laid = RadialVoxels.lay(
            lit, luminous: spec.luminousTemperature, voxelSize: voxel, first: first, counts: counts,
            samples: 2)
        guard laid.volume > 0 else {
            return FireballFrame(time: time, volume: 0, centre: .zero, temperature: 0, hottest: 0)
        }
        let cells =
            spec.fireball == .volume
            ? LuminousCells(
                voxelSize: voxel, first: first, counts: counts, fills: laid.fills,
                temperatures: laid.temperatures,
                products: configuration.afterburning ? laid.unburnt.map { Float16($0) } : nil) : nil
        return FireballFrame(
            time: time, volume: laid.volume, centre: SIMD3<Float>(laid.moment / laid.volume),
            temperature: Float(pow(laid.fourth / laid.volume, 0.25)), hottest: laid.hottest, cells: cells)
    }
}
