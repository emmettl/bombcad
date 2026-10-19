import BlastModel
import Foundation
import simd

extension ThermalExposure {
    /// One receiver's view of the fireball's shape, adding the rays it needs tested to `rays` and
    /// what each gives, in W/m², if nothing is in the way, to `weights`.
    /// The flame radiates evenly from its surface, a radiance of εσT⁴ / π at the temperature of
    /// the block it meets there, so the irradiance is the integral of that radiance times cos θ
    /// over the directions in which the receiver sees the flame. Those directions are sampled tile
    /// by tile, evenly over the cone each tile's sphere subtends (or the hemisphere above the
    /// receiver, from within the sphere), with the samples shared out by each cone's solid angle
    /// and how much of it the tile fills, at least four a tile. Where the cones overlap, a
    /// direction may be drawn from any of them, so each ray counts for its radiance times cos θ
    /// over the density of samples there from all the cones it lies in (Veach's balance
    /// heuristic): every ray that meets the flame counts, and nothing is counted twice. The flame
    /// in front hides what is behind. For one compact tile this is the sphere's sampling, over
    /// the flame's own outline.
    func view(
        from receiver: ThermalReceiver, _ shape: FireballShape, rays: inout [ThermalRay],
        weights: inout [Float]
    ) -> View {
        let scale = Float(Double(spec.emissivity) * Self.stefanBoltzmann)
        func exitance(_ temperature: UInt16) -> Float {
            let square = Float(temperature) * Float(temperature)
            return scale * square * square
        }
        let x = receiver.position
        // Within the flame, surrounded by it: the hemisphere above radiates in full.
        if shape.isInside(x) {
            return View(settled: shape.radiatingBlock(at: x).map { exitance(shape.temperatures[$0]) } ?? 0)
        }
        struct Cone {
            var axis: SIMD3<Float>
            var cosHalfAngle: Float
            var solidAngle: Float
            var share: Float
        }
        var cones: [Cone] = []
        let sampling = shape.sampling
        for tile in sampling.tiles {
            let toCentre = tile.centre - x
            let d = simd_length(toCentre)
            var cone: Cone
            if d <= tile.radius {
                cone = Cone(axis: receiver.normal, cosHalfAngle: 0, solidAngle: 2 * .pi, share: 0)
            } else {
                // The whole tile is below this surface's horizon.
                if simd_dot(receiver.normal, toCentre) < -tile.radius { continue }
                let cosHalfAngle = sqrt(max(0, 1 - (tile.radius / d) * (tile.radius / d)))
                cone = Cone(
                    axis: toCentre / d, cosHalfAngle: cosHalfAngle,
                    solidAngle: 2 * .pi * (1 - cosHalfAngle), share: 0)
            }
            cone.share = cone.solidAngle * pow(min(tile.compactness, 1), 2 / 3)
            cones.append(cone)
        }
        let total = cones.reduce(0) { $0 + $1.share }
        guard total > 0 else { return View(settled: 0) }
        // Each cone's samples, and their density in solid angle.
        let counts = cones.map { max(4, Int((Float(spec.samples) * $0.share / total).rounded())) }
        let densities = zip(cones, counts).map { Float($1) / $0.solidAngle }
        let first = rays.count
        for (c, cone) in cones.enumerated() {
            let count = counts[c]
            let axis = cone.axis
            // Two directions square to the axis, for the cone's samples.
            let helper: SIMD3<Float> = abs(axis.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
            let u = simd_normalize(simd_cross(axis, helper))
            let v = simd_cross(axis, u)
            for s in 0..<count {
                let cosine = 1 - (Float(s) + 0.5) / Float(count) * (1 - cone.cosHalfAngle)
                let sine = sqrt(max(0, 1 - cosine * cosine))
                let direction = cosine * axis + sine * (self.cone[s].y * u + self.cone[s].z * v)
                let cosReceiver = simd_dot(receiver.normal, direction)
                guard cosReceiver > 0,
                    let hit = shape.firstHit(from: x, along: direction, near: sampling.near)
                else { continue }
                // The density of samples in this direction from every cone it lies in.
                var density = densities[c]
                for (other, cone) in cones.enumerated()
                where other != c && simd_dot(direction, cone.axis) >= cone.cosHalfAngle {
                    density += densities[other]
                }
                rays.append(ThermalRay(origin: x, direction: direction, length: hit.distance))
                weights.append(cosReceiver * exitance(shape.temperatures[hit.radiating]) / .pi / density)
            }
        }
        return View(rays: rays.count - first, scale: 1, cap: exitance(shape.hottest))
    }
}

extension BlastSolver {
    /// The luminous gas in blocks of two cells a side, read from the state on the CPU as the GPU's
    /// `extractFireballBlocks` sums it, spread across the CPU's cores.
    func cpuLuminousBlocks(luminousTemperature: Float) -> [LuminousBlock] {
        let (nx, ny, nz) = (grid.nx, grid.ny, grid.nz)
        let dims = LuminousBlock.dimensions(grid)
        let gamma = configuration.gamma
        let airModel = configuration.airModel
        let mask = maskContents.bindMemory(to: UInt8.self, capacity: grid.cellCount)
        var planes = [[LuminousBlock]](repeating: [], count: dims.z)
        withState { cells in
            planes.withUnsafeMutableBufferPointer { planes in
                concurrently(iterations: dims.z) { bk in
                    var plane: [LuminousBlock] = []
                    for bj in 0..<dims.y {
                        for bi in 0..<dims.x {
                            var block = LuminousBlock(
                                index: bi + dims.x * (bj + dims.y * bk), cells: 0, fourth: 0, hottest: 0,
                                position: .zero, air: 0)
                            for k in 2 * bk..<min(2 * bk + 2, nz) {
                                for j in 2 * bj..<min(2 * bj + 2, ny) {
                                    for i in 2 * bi..<min(2 * bi + 2, nx) {
                                        let index = grid.index(i, j, k)
                                        guard mask[index] == 0 else { continue }
                                        block.air += 1
                                        let air = Self.primitive(
                                            of: cells[index], gamma: gamma, airModel: airModel)
                                        // Dissociating air is never hotter than this, so it bounds
                                        // the search.
                                        let bound = air.pressure / (air.density * AirModel.gasConstant)
                                        guard bound >= luminousTemperature else { continue }
                                        let t =
                                            airModel == .dissociating
                                            ? airModel.temperature(
                                                density: air.density, pressure: air.pressure)
                                            : bound
                                        guard t >= luminousTemperature, t.isFinite else { continue }
                                        block.cells += 1
                                        block.position += SIMD3(Float(i), Float(j), Float(k)) + 0.5
                                        let square = t * t
                                        block.fourth += square * square
                                        block.hottest = max(block.hottest, t)
                                    }
                                }
                            }
                            if block.cells > 0 { plane.append(block) }
                        }
                    }
                    planes[bk] = plane
                }
            }
        }
        return planes.flatMap { $0 }
    }
}
