import BlastModel
import Foundation
import simd

extension RunCost {
    /// The expected cost of running `scenario` on cells of `cellSize` under `configuration` for
    /// `duration` seconds.
    public static func estimate(
        _ scenario: Scenario, cellSize: Float, configuration: SolverConfiguration, duration: Double
    ) -> RunCostEstimate {
        let grid = scenario.grid(cellSize: cellSize)
        let burning = configuration.afterburning
        let share = burning ? burningStepShare : stepShare
        let soundSpeed: Float = 343
        let dt = Double(share * configuration.cfl * cellSize / soundSpeed)
        let steps = max(1, Int((duration / max(dt, 1e-9)).rounded(.up)))

        // The air each step sweeps: every cell from shortly before the blast reaches it, so a
        // cell swept for the share of the run after its arrival. The refined shell holds a cell
        // for the time the shock takes to cross it, while the shock is strong enough to refine.
        let samples = SIMD3(24, 24, 12)
        let domain = scenario.domainSize
        let charges = [scenario.charge] + (scenario.additionalCharges ?? [])
        let reach =
            configuration.refinement > 1 ? refinementReach(threshold: configuration.refinementThreshold) : 0
        let finerReach =
            configuration.refinementLevels > 1
            ? refinementReach(
                threshold: configuration.refinementFinerThreshold ?? configuration.refinementThreshold)
            : .infinity
        var swept = 0.0
        let levelCells = [Double(cellSize), Double(cellSize) / Double(max(configuration.refinement, 1))]
        // The refined air over the run, in bins of time: how many samples each level holds on
        // average through each bin.
        let bins = 256
        let binWidth = duration / Double(bins)
        var held = [[Double]](repeating: [Double](repeating: 0, count: bins), count: 2)
        // Bins held throughout, as differences: +1 where a run of them starts and -1 past its end.
        var whole = [[Double]](repeating: [Double](repeating: 0, count: bins + 1), count: 2)
        func hold(_ level: Int, from start: Double, for length: Double) {
            let low = max(start, 0)
            let high = min(start + length, duration)
            guard high > low else { return }
            let first = min(max(Int(low / binWidth), 0), bins - 1)
            let last = min(Int(high / binWidth), bins - 1)
            guard last > first else {
                held[level][first] += (high - low) / binWidth
                return
            }
            held[level][first] += (Double(first + 1) * binWidth - low) / binWidth
            held[level][last] += max(high - Double(last) * binWidth, 0) / binWidth
            whole[level][first + 1] += 1
            whole[level][last] -= 1
        }
        let count = samples.x * samples.y * samples.z
        for k in 0..<samples.z {
            for j in 0..<samples.y {
                for i in 0..<samples.x {
                    let point =
                        (SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5) / SIMD3<Float>(samples) * domain
                    var arrival = Double.infinity
                    var overpressure = 0.0
                    // Until when each level is held near a charge, past the shell (`coreRange`).
                    var core = SIMD2<Double>.zero
                    for charge in charges where charge.mass > 0 {
                        let range = Double(simd_distance(point, charge.position))
                        let blast = Self.blast(range: range, mass: Double(charge.mass))
                        arrival = min(arrival, blast.arrival)
                        overpressure = max(overpressure, blast.overpressure)
                        let scale = cbrt(Double(charge.mass))
                        for level in 0..<2 where range < coreRange(cell: levelCells[level], scale: scale) {
                            core[level] = max(core[level], coreTime * scale)
                        }
                    }
                    guard arrival < duration else { continue }
                    swept += 1 - arrival / duration
                    // Above the refinement's ceiling over the ground, nothing is refined.
                    let capped =
                        configuration.refinementCeiling.map {
                            point.z > (scenario.terrain?.height(at: SIMD2(point.x, point.y)) ?? 0) + $0
                        } ?? false
                    if Float(overpressure) >= reach && configuration.refinement > 1 && !capped {
                        hold(
                            0, from: arrival,
                            for: max(Double(shellCells * cellSize / soundSpeed), core.x - arrival))
                        if Float(overpressure) >= finerReach {
                            hold(
                                1, from: arrival,
                                for: max(
                                    Double(
                                        shellCells * cellSize / Float(configuration.refinement) / soundSpeed),
                                    core.y - arrival))
                        }
                    }
                }
            }
        }
        for level in 0..<2 {
            var running = 0.0
            for bin in 0..<bins {
                running += whole[level][bin]
                held[level][bin] += running
            }
        }
        let cells = Double(grid.cellCount)
        let coarseUpdates = cells * Double(steps) * swept / Double(count)
        // The refined coarse cells each bin, no more than the pool of blocks holds (a third of it
        // for the first level and two thirds for the second when there are two), times each
        // level's cells to a coarse cell and the steps it takes to each coarse one.
        let r = Double(configuration.refinement)
        var fineUpdates = 0.0
        var refinedShare = SIMD2<Double>.zero
        var peakRefined = SIMD2<Double>.zero
        if configuration.refinement > 1 {
            let levels = configuration.refinementLevels > 1 ? 2 : 1
            let blocks = Double(configuration.refinementMemory) / blockBytes
            let block = Double(AirRefinement.patchSize)
            let capacity = [
                (levels == 2 ? blocks / 3 : blocks) * block * block * block,
                blocks * 2 / 3 * block * block * block / (r * r * r),
            ]
            let perCoarse = [r * r * r * r, r * r * r * r * r * r * r * r]
            for level in 0..<levels {
                for bin in 0..<bins {
                    peakRefined[level] = max(peakRefined[level], cells * held[level][bin] / Double(count))
                    let refined = min(cells * held[level][bin] / Double(count), capacity[level])
                    fineUpdates += refined * perCoarse[level] * binWidth / dt
                    refinedShare[level] += refined / cells / Double(bins)
                }
            }
        }

        // The structure's elements, each taking the substeps its critical step asks of the air's.
        var elements = 0.0
        var elementStep = Double.infinity
        for structure in scenario.structuralObjects.compactMap(\.structure) {
            let h = Double(structure.elementSize)
            for (index, solid) in structure.solids.enumerated() {
                let size = SIMD3<Double>(solid.max - solid.min)
                elements +=
                    structure.elementKind(of: index) == .shell
                    ? size.x * size.y * size.z / max(size.min(), h) / (h * h)
                    : size.x * size.y * size.z / (h * h * h)
            }
            // About h / 7,000 m/s for concrete solids and shells alike (docs/performance.md).
            elementStep = min(elementStep, h / 7000)
        }
        let substeps =
            elements > 0
            ? min(max((Double(configuration.cfl * cellSize) / (0.8 * 343) / elementStep).rounded(.up), 1), 96)
            : 0
        let elementUpdates = elements * substeps * Double(steps)

        // Each pool from the blocks of its busiest bin, a level's block of coarse cells holding
        // r^3 of its own per level above it, and never less than it starts with.
        var pools = 0
        if configuration.refinement > 1 {
            let block = Double(AirRefinement.patchSize * AirRefinement.patchSize * AirRefinement.patchSize)
            let patch = Double(
                AirRefinement.bytesPerPatch(
                    ratio: configuration.refinement, species: burning,
                    cut: configuration.cutsTerrain(of: scenario, cellSize: grid.cellSize)))
            let wanted =
                (peakRefined.x / block * poolShares.x + peakRefined.y * r * r * r / block * poolShares.y)
                * patch
            let start = configuration.refinementStartMemory ?? configuration.refinementMemory
            pools = Int(max(wanted, Double(min(start, configuration.refinementMemory))))
        }
        let memory = coarseMemory(grid, configuration: configuration) + pools
        let updateCost =
            (burning ? afterburningUpdateCost : 1)
            * (configuration.cutsTerrain(of: scenario, cellSize: grid.cellSize) ? terrainCutUpdateCost : 1)
            * (configuration.radiativeCooling == nil ? 1 : radiativeCoolingUpdateCost)
        let twoLevels = configuration.refinement > 1 && configuration.refinementLevels > 1
        let overhead = Double(steps) * (stepOverhead + (twoLevels ? twoLevelStepOverhead : 0))
        if configuration.refinement > 1 && configuration.refinementOwnSteps {
            fineUpdates *= ownStepsShare(scenario, duration: duration)
        }
        let seconds =
            (coarseUpdates + fineUpdates * fineUpdateCost) * updateCost / cellUpdatesPerSecond
            + elementUpdates / elementUpdatesPerSecond + overhead
            + mappedStartSeconds(scenario, cellSize: cellSize, configuration: configuration)
        return RunCostEstimate(
            cells: grid.cellCount, steps: steps, coarseUpdates: coarseUpdates, fineUpdates: fineUpdates,
            elementUpdates: elementUpdates, memory: memory, seconds: seconds, refinedShare: refinedShare,
            peakRefinedCells: peakRefined, refinementMemory: pools)
    }
}
