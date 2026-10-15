import Foundation
import simd

/// What a run of a scene is expected to cost: its cells, steps and updates, the GPU memory it
/// holds and the time it takes on an unloaded M4 Max, from the throughput measured in
/// docs/performance.md and checked against timed runs there and in docs/large-scenes.md. A
/// loaded Mac takes longer; the estimate is good to about a factor of two (see
/// `RunCost.calibration`).
public struct RunCostEstimate: Sendable, Equatable {
    /// The coarse grid's cells, and its steps over the run.
    public var cells: Int
    public var steps: Int
    /// Coarse cell-updates swept, the still air skipped left out.
    public var coarseUpdates: Double
    /// Refined cell-updates, each a fine cell's sweep in one of its level's own steps.
    public var fineUpdates: Double
    /// Structural element-updates, each an element's substep.
    public var elementUpdates: Double
    /// GPU memory held, in bytes.
    public var memory: Int
    /// Seconds on an unloaded M4 Max.
    public var seconds: Double
    /// The share of the domain each level of refinement's patches hold, first and second, on
    /// average over the run; zero unrefined.
    public var refinedShare: SIMD2<Double> = .zero
}

public enum RunCost {
    /// Coarse cell-updates a second, each three directional sweeps: 2.1 to 2.6 billion on the
    /// street when every cell is swept (docs/performance.md, "Air solver"), 1.8 billion with the
    /// rest of a step's work, as the unrefined runs there take on average.
    public static let cellUpdatesPerSecond = 1.8e9
    /// A fine cell's update with its ghost cells against a coarse one's (docs/performance.md,
    /// "Refinement").
    public static let fineUpdateCost = 1.6
    /// Afterburning and hot air against an ideal gas, per cell-update: the street at 0.25 m takes
    /// twice as long, of which a shorter step is part (docs/performance.md, "Air solver").
    public static let afterburningUpdateCost = 1.6
    /// Element-updates a second with contact (docs/performance.md, "Structural solver").
    public static let elementUpdatesPerSecond = 3.0e8
    /// The time step against still air's: about a third, from the fireball's hot gas (0.34 on the
    /// street, 0.32 to 0.42 at 500 t), and less with afterburning.
    public static let stepShare: Float = 0.36
    public static let burningStepShare: Float = 0.31
    /// The refined air's thickness about a shock, in the coarse cells of the first level and the
    /// first level's cells of the second. The patches over the street's shock on 0.25 m cells
    /// (4,000 to 5,000 blocks of 4 cells) make about 7, but the refined runs on record take 2.2
    /// to 3.4 times what that shell alone would cost: patches flagged behind the shock, kept
    /// where outlines differ, and their ghost cells; 18 matches them.
    public static let shellCells: Float = 18
    /// Seconds a step costs whatever the grid (launching its kernels, the tiles' list, the
    /// gauges), and more with two levels of refinement (their patches' bookkeeping): fitted to every
    /// run of `blastbench advise --calibrate --time` on a quiet Mac (load under 2), on which a step
    /// of its own costs nothing measurable and a step in two levels 1.2 ms.
    public static let stepOverhead = 0.0
    public static let twoLevelStepOverhead = 0.0012
    /// Close in, the patches do not move on with the shock: the fireball, the secondary shock and
    /// the ground's reflections keep the air refined from the shock's arrival until `coreTime`
    /// s/kg^(1/3) after the burst, within `coreRange` m/kg^(1/3) of the charge for a level of
    /// cells 0.04 m/kg^(1/3) across, and as the square root of the cells' size within a level of
    /// finer ones (0.57 for 0.02 m/kg^(1/3)), where the smooth air between the jumps differs less
    /// from cell to cell. Fitted to the refined share of 1 kg 0.5 m above rigid ground in domains
    /// 1.5 to 6 m across (`blastbench profile --closein --width`, refined once and twice from
    /// 0.04 m and once from 0.02 m; docs/performance.md, "Uniform when the patches cover most").
    /// Coarser cells than those are held at `coreRange`: the open ground's refined runs show
    /// nothing more.
    public static let coreTime = 0.006
    public static let coreRange = 0.8
    public static let coreRangeExponent = 0.5

    /// The scaled range within which a level of cells of `cell` m is held close in, for a charge
    /// of `scale` kg^(1/3), in metres.
    static func coreRange(cell: Double, scale: Double) -> Double {
        coreRange * min(1, pow(cell / scale / 0.04, coreRangeExponent)) * scale
    }

    /// GPU memory a block of refined air takes, ratio 2 (`SolverConfiguration.refinementMemory`).
    public static let blockBytes = 63_000.0
    /// Air bytes a cell: 57, with the fuel and oxygen 73 (docs/large-scenes.md).
    public static let bytesPerCell = 57
    public static let burningBytesPerCell = 73

    /// The overpressure, in pascals, above which the refined cells follow a shock flagged at
    /// `threshold`, as `ValidationTables.refinementReach` has it.
    public static func refinementReach(threshold: Float, ambient: Float = 101_325) -> Float {
        Float(ValidationTables.refinementReach(threshold: Double(threshold), ambient: Double(ambient)))
    }

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
                    if Float(overpressure) >= reach && configuration.refinement > 1 {
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
            for solid in structure.solids {
                let size = SIMD3<Double>(solid.max - solid.min)
                elements +=
                    structure.elementKind == .shell
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

        let perCell = burning ? burningBytesPerCell : bytesPerCell
        let memory =
            grid.cellCount * perCell + (configuration.refinement > 1 ? configuration.refinementMemory : 0)
        let updateCost = burning ? afterburningUpdateCost : 1
        let twoLevels = configuration.refinement > 1 && configuration.refinementLevels > 1
        let overhead = Double(steps) * (stepOverhead + (twoLevels ? twoLevelStepOverhead : 0))
        let seconds =
            (coarseUpdates + fineUpdates * fineUpdateCost) * updateCost / cellUpdatesPerSecond
            + elementUpdates / elementUpdatesPerSecond + overhead
        return RunCostEstimate(
            cells: grid.cellCount, steps: steps, coarseUpdates: coarseUpdates, fineUpdates: fineUpdates,
            elementUpdates: elementUpdates, memory: memory, seconds: seconds, refinedShare: refinedShare)
    }

    /// The blast's arrival time (s) and incident overpressure (Pa) at `range` from a surface burst
    /// of `mass` kg, from the Kingery–Bulmash curves; beyond their reach the shock travels at the
    /// speed of sound and weakens as the curves' last decade does.
    static func blast(range: Double, mass: Double) -> (arrival: Double, overpressure: Double) {
        let scale = cbrt(max(mass, 1e-9))
        let z = range / scale
        if z < 0.2 { return (0, .infinity) }
        if let point = KingeryBulmash.point(at: min(z, 40)) {
            if z <= 40 { return (point.scaledArrival * scale, point.incidentPressure) }
            return (
                point.scaledArrival * scale + (range - 40 * scale) / 343,
                point.incidentPressure * pow(40 / z, 1.4)
            )
        }
        return (range / 343, 0)
    }
}
