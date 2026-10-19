import BlastModel
import Foundation
import Metal
import RadialBlast
import simd

// The air solver's gauges and exposure plane: where they read, their histories, and the passes that
// record them.
extension BlastSolver {
    /// Enables fixed spatial probes before stepping. Does not change the air solution.
    /// Snapshot arrays are x-fast; stencils touching solids and unreached arrivals are null.
    /// Probe spacing defaults to the air grid and must divide both horizontal domain extents.
    public func configureExposurePlane(heightM: Float, arrivalThresholdPa: Float, spacingM: Float? = nil)
        throws
    {
        precondition(!batchInFlight && stepCount == 0, "Configure probes before stepping")
        let plane = try ExposurePlane(
            device: device, library: library, grid: grid, height: heightM,
            threshold: arrivalThresholdPa, spacing: spacingM)
        // A charge mapped from one dimension has already passed the plane within its mapped radius:
        // there it takes the solution's own peak, impulse and arrival.
        for mappedStart in mappedStart {
            plane.seed(
                mappedStart.blast, centre: mappedStart.centre, radius: mappedStart.radius,
                delay: mappedStart.charge.firingTime)
        }
        exposurePlane = plane
        exposureNeedsInitialSample = true
    }

    public func exposureSnapshot() -> ExposurePlaneSnapshot? {
        precondition(!batchInFlight, "Cannot read probes while a batch is in flight")
        return exposurePlane?.snapshot(grid: grid, elapsed: time)
    }

    /// Chooses the cells whose pressure is recorded every step. Clears existing histories. With
    /// `points`, one per cell, a gauge whose cell is refined reads the fine cell holding its point.
    public func setGauges(cells: [(i: Int, j: Int, k: Int)], points: [SIMD3<Float>]? = nil) {
        precondition(cells.count <= Self.maxGauges, "At most \(Self.maxGauges) gauges are supported")
        let pointer = gaugeCellBuffer.contents().bindMemory(to: UInt32.self, capacity: Self.maxGauges)
        for (n, cell) in cells.enumerated() {
            precondition(grid.contains(cell.i, cell.j, cell.k), "Gauge outside the grid")
            pointer[n] = UInt32(grid.index(cell.i, cell.j, cell.k))
        }
        gaugeCount = cells.count
        gaugeHistories = Array(repeating: [], count: gaugeCount)
        gaugePoints = (0..<cells.count).map { points?[$0] }
        let placed = gaugePointBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.maxGauges)
        for n in 0..<Self.maxGauges {
            placed[n] = n < gaugePoints.count ? gaugePoints[n].map { SIMD4($0, 1) } ?? .zero : .zero
        }
        updateGaugeChildren()
    }

    /// Moves the gauges set by `setGauges` to new cells and points, keeping what they have recorded:
    /// for gauges that follow a moving face.
    public func moveGauges(cells: [(i: Int, j: Int, k: Int)], points: [SIMD3<Float>]) {
        precondition(cells.count == gaugeCount && points.count == gaugeCount, "Move every gauge")
        let pointer = gaugeCellBuffer.contents().bindMemory(to: UInt32.self, capacity: Self.maxGauges)
        let placed = gaugePointBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.maxGauges)
        for (n, cell) in cells.enumerated() {
            precondition(grid.contains(cell.i, cell.j, cell.k), "Gauge outside the grid")
            pointer[n] = UInt32(grid.index(cell.i, cell.j, cell.k))
            placed[n] = SIMD4(points[n], 1)
        }
        gaugePoints = points
        updateGaugeChildren()
    }

    /// Binds the second level's patches, cells and outline for the gauges (any buffer without).
    func encodeFinerGaugeBuffers(_ encoder: MTLComputeCommandEncoder) {
        if let deep = finerRefinement, let parent = deep.parent {
            encoder.setBuffer(parent.patchOfTile, offset: deep.patchOffset * 4, index: 12)
            encoder.setBuffer(
                parent.fine[0], offset: deep.cellOffset * MemoryLayout<CellState>.stride, index: 13)
            encoder.setBuffer(parent.fineMask, offset: deep.cellOffset, index: 14)
        } else {
            for index in 12...14 { encoder.setBuffer(refinementPlaceholder, offset: 0, index: index) }
        }
    }

    /// Which finest cell of its cell each gauge reads, for the current refinement.
    func updateGaugeChildren() {
        let pointer = gaugeChildBuffer.contents().bindMemory(to: UInt32.self, capacity: Self.maxGauges)
        let cells = gaugeCellBuffer.contents().bindMemory(to: UInt32.self, capacity: Self.maxGauges)
        for n in 0..<Self.maxGauges {
            pointer[n] = .max
            guard refinement != nil, n < gaugePoints.count, let point = gaugePoints[n] else { continue }
            let index = Int(cells[n])
            let cell = SIMD3(index % grid.nx, (index / grid.nx) % grid.ny, index / (grid.nx * grid.ny))
            let r = refinementLevels.reduce(1) { $0 * $1.ratio }
            let within = simd_clamp(
                point / grid.cellSize - SIMD3<Float>(cell), .zero, SIMD3(repeating: 0.999))
            var child = SIMD3<Int>((within * Float(r)).rounded(.down))
            if let terrain, let cut = refinement?.coarseCut {
                // On cut cells, a fine cell at least half air, as on the coarse grid (`surfaceCells`).
                let fine = { cell &* r &+ child }
                while child.z < r - 1,
                    TerrainCutGeometry.share(
                        of: fine(), cellSize: grid.cellSize / Float(r), terrain: terrain,
                        samples: max(cut.geometry.samples / r, 1))
                        < TerrainCutGeometry.receivingShare
                {
                    child.z += 1
                }
            }
            pointer[n] = UInt32(child.x + r * (child.y + r * child.z))
        }
    }

    /// Puts `samples` in front of gauge `index`'s history.
    func prependGaugeHistory(_ index: Int, _ samples: [GaugeSample]) {
        guard gaugeHistories.indices.contains(index) else { return }
        gaugeHistories[index] = samples + gaugeHistories[index]
    }

    /// Puts `samples` in a gauge's history in place of what it recorded from `start` through `end`,
    /// in order of time.
    func spliceGaugeHistory(_ index: Int, _ samples: [GaugeSample], from start: Double, through end: Double) {
        guard gaugeHistories.indices.contains(index) else { return }
        let history = gaugeHistories[index]
        gaugeHistories[index] =
            history.filter { $0.time < start } + samples + history.filter { $0.time > end }
    }

    func encodeExposure(_ encoder: MTLComputeCommandEncoder, initial: Bool) {
        guard let plane = exposurePlane else { return }
        var uniforms = makeUniforms()
        var probe = SIMD4<Float>(Float(plane.layer), plane.threshold, Float(time), initial ? 1 : 0)
        var weight = plane.weight
        var sampling = SIMD4<Float>(Float(plane.nx), Float(plane.ny), plane.spacing, 0)
        encoder.setComputePipelineState(plane.pipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(maskBuffer, offset: 0, index: 1)
        encoder.setBuffer(controlBuffer, offset: 0, index: 2)
        encoder.setBuffer(plane.buffer, offset: 0, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 4)
        encoder.setBytes(&probe, length: 16, index: 5)
        encoder.setBytes(&weight, length: 4, index: 6)
        encoder.setBytes(&sampling, length: 16, index: 7)
        // Where the air is refined, the finest cell holding each point.
        bindRefinedAir(encoder, from: 8)
        encoder.dispatchThreads(
            MTLSize(width: plane.nx, height: plane.ny, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    }
}
