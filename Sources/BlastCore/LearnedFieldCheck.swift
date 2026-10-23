import Foundation
import Metal

/// Whether the learned field model runs on this Mac (emmettl/bombcad-work#69): the downloaded
/// networks loaded and run twice each on a built-in district of `cells` × `cells` 4 m cells (5 km
/// square at 1,250, larger than Beirut's plan), timed, with the process's peak memory, against
/// the GPU's recommended working set. The app's **Check on this Mac** runs it as
/// `BombCAD field-model check` in a process of its own, so that its memory is its own.
public enum LearnedFieldCheck {
    /// The plan's side, cells: 5 km of 4 m cells.
    public static let defaultCells = 1250

    public struct Report: Sendable {
        public struct Timing: Sendable {
            public var name: String
            public var loadS: Double
            public var firstS: Double
            public var secondS: Double
        }

        public var gpu: String
        public var recommendedWorkingSet: UInt64
        public var physicalMemory: UInt64
        public var cells: Int
        public var timings: [Timing] = []
        /// The process's memory footprint before the check and its peak during it, bytes.
        public var footprintBefore: UInt64 = 0
        public var footprintPeak: UInt64 = 0
        /// Why the networks could not be run, if they could not.
        public var problem: String?

        /// The check's rise in memory: its peak over the footprint before it.
        public var rise: UInt64 { footprintPeak > footprintBefore ? footprintPeak - footprintBefore : 0 }

        /// Whether it fits: run, and its rise within half the recommended working set, leaving the
        /// other half for the scene and the app.
        public var fits: Bool { problem == nil && !timings.isEmpty && rise <= recommendedWorkingSet / 2 }

        public var lines: [String] {
            func gb(_ bytes: UInt64) -> String { String(format: "%.2f GB", Double(bytes) / 1e9) }
            var lines = [
                "GPU: \(gpu); recommended working set \(gb(recommendedWorkingSet)); memory \(gb(physicalMemory)).",
                "Plan: \(cells) × \(cells) cells of 4 m, a built-in district.",
            ]
            for t in timings {
                lines.append(
                    String(
                        format: "%@: loaded in %.2f s; first run %.2f s, second %.2f s.", t.name, t.loadS,
                        t.firstS, t.secondS))
            }
            lines.append(
                "Peak memory of the check's process: \(gb(footprintPeak)) (\(gb(footprintBefore)) before it)."
            )
            // The largest square plan the app lets run with the GPU otherwise idle
            // (`LearnedFieldNetwork.bytesNeeded`).
            let fixed: UInt64 = LearnedFieldNetwork.bytesNeeded(rows: 0, columns: 0)
            if recommendedWorkingSet > fixed {
                let side = Int((Double(recommendedWorkingSet - fixed) / 2_000).squareRoot()) / 16 * 16
                lines.append(
                    String(
                        format:
                            "The option runs plans up to about %d × %d cells here (%.1f km square) with the GPU otherwise idle; a larger one is left to the surrogate, saying so.",
                        side, side, Double(side) * Double(LearnedField.cellSize) / 1000))
            }
            if let problem {
                lines.append("It does not run here: \(problem)")
            } else if fits {
                lines.append(
                    "It fits: the networks' \(gb(rise)) is within half of the \(gb(recommendedWorkingSet)) "
                        + "the GPU is recommended to use.")
            } else if rise <= recommendedWorkingSet {
                lines.append(
                    "It fits, tightly: the networks' \(gb(rise)) is more than half of the "
                        + "\(gb(recommendedWorkingSet)) the GPU is recommended to use, so a large scene beside it "
                        + "may leave the option on the surrogate alone.")
            } else {
                lines.append(
                    "It does not fit: the networks' \(gb(rise)) is more than the \(gb(recommendedWorkingSet)) "
                        + "the GPU is recommended to use.")
            }
            return lines
        }
    }

    /// Loads the weights at `ground` (and `levels`, field model 2's second file, if given) and
    /// runs each twice on the built-in district.
    public static func run(ground: URL, levels: URL?, cells: Int = defaultCells) -> Report {
        let before = footprint()
        guard let device = MTLCreateSystemDefaultDevice() else {
            var report = Report(
                gpu: "none", recommendedWorkingSet: 0, physicalMemory: ProcessInfo.processInfo.physicalMemory,
                cells: cells)
            report.problem = "this Mac has no Metal GPU."
            return report
        }
        var report = Report(
            gpu: device.name, recommendedWorkingSet: device.recommendedMaxWorkingSetSize,
            physicalMemory: ProcessInfo.processInfo.physicalMemory, cells: cells)
        report.footprintBefore = before.now
        let raw = district(cells: cells)
        do {
            for (name, url) in [("Ground floor's network", ground)]
                + (levels.map { [("Levels network", $0)] } ?? [])
            {
                var clock = ContinuousClock.now
                let network = try LearnedFieldNetwork(
                    weights: LearnedField.Weights(contentsOf: url), device: device)
                let loadS = seconds(since: clock)
                let header = network.header
                let (inputs, rows, columns, _) = LearnedField.networkInputs(
                    exportChannels: raw, rows: cells, columns: cells, header: header)
                var times: [Double] = []
                for _ in 0..<2 {
                    clock = .now
                    if header.levels == nil {
                        _ = try network.peakChannel(inputs: inputs, rows: rows, columns: columns)
                    } else {
                        _ = try network.peakChannels(inputs: inputs, rows: rows, columns: columns)
                    }
                    times.append(seconds(since: clock))
                }
                report.timings.append(.init(name: name, loadS: loadS, firstS: times[0], secondS: times[1]))
            }
        } catch {
            report.problem = "\(error)"
        }
        report.footprintPeak = max(footprint().peak, before.now)
        return report
    }

    /// A built-in district's six export channels (`LearnedField.Plan.exportChannels`) on
    /// `cells` × `cells` 4 m cells: blocks 20 m square every 40 m, 6–30 m tall, on flat ground,
    /// with 500 kg at the middle.
    public static func district(cells: Int) -> [Float] {
        let plan = cells * cells
        let cell = LearnedField.cellSize
        let mass = 500.0
        let middle = Float(cells) * cell / 2
        var raw = [Float](repeating: 0, count: 6 * plan)
        for j in 0..<cells {
            for i in 0..<cells {
                let n = i + cells * j
                let (x, y) = ((Float(i) + 0.5) * cell, (Float(j) + 0.5) * cell)
                let built = i % 10 >= 5 && j % 10 >= 5 && abs(x - middle) + abs(y - middle) > 40
                let distance = Double(
                    ((x - middle) * (x - middle) + (y - middle) * (y - middle)).squareRoot())
                let z = max(distance, Double(cell) / 2) / cbrt(mass)
                let kb = LearnedField.kingeryBulmash(z: z, mass: mass)
                raw[n] = built ? Float(6 + 4 * ((i / 10 + 3 * (j / 10)) % 7)) : 0
                raw[2 * plan + n] = Float(distance)
                raw[3 * plan + n] = Float(log(z))
                raw[4 * plan + n] = Float(kb.peak)
                raw[5 * plan + n] = Float(kb.impulse)
            }
        }
        return raw
    }

    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let took = start.duration(to: .now)
        return Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
    }

    /// The process's memory footprint and its peak so far, bytes.
    static func footprint() -> (now: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak)))
    }
}
