import BlastCore
import Foundation
import Metal
import simd

#if canImport(Darwin)
    import Darwin
#endif

/// The explorer's Beirut dragged without a window, its learned response and live wave timed, to see
/// whether an iPad can be a live estimator on its own (emmettl/bombcad-work#119): `BombCAD
/// live-bench` on a Mac, and the iPad viewer launched with `BOMBCAD_VIEWER_LIVE_BENCH=1`
/// (docs/spatial-viewer.md). Beirut's port is laid out as the explorer lays it out
/// (`ExplorerModel.document`), on the cells the app takes for it; then, as the explorer drags on its
/// glass layer:
///
/// - the drag preview by the learned response (`livePreview`, the glass's chances on 10 draws, kept
///   on the networks as the explorer keeps Beirut), and the walls' and roofs' (20 draws);
/// - the live wave on cells four times its own, unrefined, as the explorer drags it, and on its own
///   cells refined, as on let-go; and on 8 m cells refined, as the workbench drags;
/// - then both together for `sustainSeconds`, the charge going to and fro, to see the device warm;
/// - and once, the full estimate that follows on let-go (100 draws, on the CPU).
///
/// Each figure is the median and 90th percentile of the frames after the first, with the memory in
/// use and the thermal state. Nothing is drawn: the view's own time is the viewer's measure.
enum LiveBench {
    struct Options: Sendable {
        var frames = 21
        var stepM: Float = 5
        var sustainSeconds = 60.0
        var fullEstimate = true
        /// The app's own, read on the main actor (`app`): the preview's draws, and the wave's cells
        /// while dragging (`SimulationModel.liveWaveCell`).
        var draws = (glass: 10, structure: 20)
        var coarsening: Float = 4
        var dragCells = 500_000

        @MainActor static var app: Options {
            var options = Options()
            options.draws = SimulationModel.previewDraws
            options.coarsening = ExplorerModel.dragCoarsening
            options.dragCells = SimulationModel.liveWaveDragCells
            return options
        }
    }

    /// The bench, run through; `emit` is given each line as it is made. Returns the whole report.
    static func run(
        beirut: URL, waveWeights: URL?, options: Options, emit: @Sendable (String) -> Void
    ) throws -> String {
        var lines: [String] = []
        func say(_ line: String) {
            lines.append(line)
            emit(line)
        }
        func seconds(_ start: ContinuousClock.Instant) -> Double { start.duration(to: .now) / .seconds(1) }
        func ms(_ s: Double) -> String { String(format: "%.1f", 1000 * s) }
        /// "median, p90 (least–most), n" of the frames after the first.
        func summary(_ times: [Double]) -> String {
            let later = Array(times.dropFirst()).sorted()
            guard !later.isEmpty else { return times.first.map { "\(ms($0)) ms (one frame)" } ?? "none" }
            let p90 = later[min(later.count - 1, Int((Double(later.count) * 0.9).rounded(.up)) - 1)]
            return
                "median \(ms(later[later.count / 2])) ms, p90 \(ms(p90)) ms (\(ms(later[0]))–\(ms(later.last!))), "
                + "\(later.count) frames after a first of \(ms(times[0])) ms"
        }
        var peak: UInt64 = 0
        func memory() -> String {
            let now = footprint()
            peak = max(peak, now)
            var text = String(
                format: "memory in use %.0f MB (at most %.0f MB)", Double(now) / 1e6, Double(peak) / 1e6)
            #if os(iOS)
                let available = os_proc_available_memory()
                if available > 0 {
                    text += String(
                        format: " of the %.0f MB the app may use", Double(available + Int(now)) / 1e6)
                }
            #endif
            return text + "; thermal \(thermal())"
        }

        let device = MTLCreateSystemDefaultDevice()
        say(
            "Live bench on \(machine()) (\(device?.name ?? "no GPU")), \(ProcessInfo.processInfo.operatingSystemVersionString), "
                + String(
                    format: "%.1f GB, GPU working set %.1f GB",
                    Double(ProcessInfo.processInfo.physicalMemory) / 1e9,
                    Double(device?.recommendedMaxWorkingSetSize ?? 0) / 1e9)
                + (ProcessInfo.processInfo.isLowPowerModeEnabled ? ", low power mode" : "")
                + "; \(memory())")

        // Beirut's port, laid out as the explorer lays it out.
        var clock = ContinuousClock.now
        let document = try ExplorerModel.document(
            for: .beirut, memory: Int(ProcessInfo.processInfo.physicalMemory), asset: beirut)
        let scene = document.scenario
        let cellSize =
            document.runSettings.flatMap { Resolution(rawValue: $0.resolution)?.cellSize }
            ?? ExplorerScene.beirut.cellSizeM ?? 6
        let mass = Double(scene.charge.mass)
        say(
            String(
                format: "Beirut laid out: %d buildings on %.0f × %.0f m, %.0f m cells, %.0f t, in %.2f s; %@",
                scene.envelopeObjects.count, scene.domainSize.x, scene.domainSize.y, cellSize, mass / 1000,
                seconds(clock), memory()))
        clock = .now
        var layout = scene
        layout.charge.position = .zero
        let terms = FacadeLoadSurrogate.TermSet.adopted
        let prepared = FacadeLoadSurrogate.Prepared(
            scene: layout, cellSize: cellSize, incidence: terms.coefficients.incidence)
        say(
            String(
                format: "The district prepared: %d components in %.2f s; %@", prepared.componentCount,
                seconds(clock), memory()))
        let (made, problem) = SimulationModel.makeLiveModel()
        guard let live = made else { throw BlastError.allocationFailed(problem ?? "no learned response") }
        say("The learned response on the \(live.engine.label)")

        // The drag preview, as the explorer's: each frame the charge moved `stepM` east.
        let start = scene.charge.position
        func charge(_ n: Int) -> SIMD3<Float> {
            var c = start
            c.x += Float(n) * options.stepM
            return c
        }
        func uncertainty(_ samples: Int) -> FacadeLoadSurrogate.Uncertainty {
            var u = FacadeLoadSurrogate.Uncertainty(
                yieldLogSD: log(1.5) / 1.645, loadScatter: terms.loadScatter, samples: samples)
            u.stratified = true
            return u
        }
        func preview(_ n: Int, parts: FacadeLoadSurrogate.Prepared.Parts) throws -> (
            seconds: Double, stages: FacadeLoadSurrogate.Prepared.LiveStages,
            look: FacadeLoadSurrogate.Prepared.Look
        ) {
            let clock = ContinuousClock.now
            let samples =
                parts == .glass ? options.draws.glass : options.draws.structure
            guard
                let made = try prepared.livePreview(
                    charge: charge(n), mass: mass, uncertainty: uncertainty(samples), parts: parts,
                    terms: terms,
                    model: live, leavesUntrainedToCPU: !ExplorerScene.beirut.keepsLearnedResponse)
            else { throw BlastError.allocationFailed("the learned response does not know Beirut") }
            return (seconds(clock), made.stages, made.look)
        }
        for (title, parts) in [
            ("glass's chances", FacadeLoadSurrogate.Prepared.Parts.glass), ("walls' and roofs'", .structure),
        ] {
            var frames: [Double] = []
            var stages: [FacadeLoadSurrogate.Prepared.LiveStages] = []
            var digest = ""
            for n in 0..<options.frames {
                // Each frame in its own pool, as each of the app's runs in a task of its own: Metal's
                // buffers' contents are autoreleased.
                let (s, stage, look) = try autoreleasepool { try preview(n, parts: parts) }
                frames.append(s)
                stages.append(stage)
                // The first frame's answers, to set beside another machine's.
                if n == 0 {
                    let sides = Double(max(1, look.glass.count))
                    digest = String(
                        format: "%d glazed sides, mean some broken %.4f, blown out %.4f; %d buildings' walls",
                        look.glass.count, look.glass.reduce(0) { $0 + $1.someBroken } / sides,
                        look.glass.reduce(0) { $0 + $1.blownOut } / sides, look.structure.count)
                }
            }
            func stage(_ key: KeyPath<FacadeLoadSurrogate.Prepared.LiveStages, Double>) -> String {
                let later = stages.dropFirst().map { $0[keyPath: key] }.sorted()
                return later.isEmpty ? "-" : ms(later[later.count / 2])
            }
            say("Drag preview, the \(title): \(summary(frames)); \(memory())")
            say("  its first frame: \(digest)")
            say(
                "  its stages' medians, ms: choice \(stage(\.choice)), loads \(stage(\.loads)), rows \(stage(\.inputs)), "
                    + "networks \(stage(\.networks)), answers \(stage(\.answers)), of which the GPU's \(stage(\.gpu))"
            )
        }

        // The live wave: the plan's own cells, and four times them while dragging as the explorer does.
        let fine = LiveWave.Plan.cellSize(for: layout)
        let fineCells = Double(layout.domainSize.x / fine) * Double(layout.domainSize.y / fine)
        let coarse = fineCells > Double(options.dragCells) ? options.coarsening * fine : fine
        var refinement: LiveWave.Refinement?
        if let waveWeights {
            clock = .now
            refinement = try SimulationModel.loadLiveWaveRefinement(waveWeights)
            say(String(format: "The wave's refinement read in %.2f s; %@", seconds(clock), memory()))
        } else {
            say("No weights for the wave's refinement: the plain wave alone")
        }
        func wave(cell: Float, refined: Bool, label: String) throws -> [Double] {
            clock = .now
            let plan = LiveWave.Plan(scene: layout, cell: cell)
            let planS = seconds(clock)
            var frames: [Double] = []
            var networks: [Double] = []
            var digest = ""
            for n in 0..<options.frames {
                let clock = ContinuousClock.now
                let field = try autoreleasepool {
                    let field = LiveWave.field(plan: plan, charge: charge(n), mass: mass)
                    guard refined, let refinement else { return field }
                    return try refinement.refined(field, plan: plan, charge: charge(n), mass: mass)
                }
                frames.append(seconds(clock))
                networks.append(field.refinementSeconds)
                if n == 0 {
                    let reached = field.peak.filter { $0.isFinite && $0 > 0 }
                    let meanLog = reached.reduce(0.0) { $0 + log(Double($1)) } / Double(max(1, reached.count))
                    digest = String(
                        format: "; its first: last arrival %.4f s, %d cells reached, mean ln peak %.4f",
                        field.lastArrival, reached.count, meanLog)
                }
            }
            let later = networks.dropFirst().sorted()
            say(
                String(
                    format: "Live wave, %@, on %.0f m cells (%d × %d, %.2f M; plan %.0f ms): ", label, cell,
                    plan.columns, plan.rows, Double(plan.columns * plan.rows) / 1e6, 1000 * planS)
                    + summary(frames)
                    + (refined && refinement != nil && !later.isEmpty
                        ? "; the network \(ms(later[later.count / 2])) ms median" : "")
                    + digest + "; \(memory())")
            return frames
        }
        _ = try wave(cell: coarse, refined: false, label: "dragging as the explorer")
        if refinement != nil {
            // The refinement refuses a plan the GPU has too little memory for (in the Simulator, none).
            for (cell, label) in [(fine, "let go, refined"), (8, "dragging as the workbench, refined")] {
                do {
                    _ = try wave(cell: cell, refined: true, label: label)
                } catch {
                    say("Live wave, \(label), on \(Int(cell)) m cells: not run, \(error)")
                }
            }
        } else {
            _ = try wave(cell: fine, refined: false, label: "let go")
        }

        // Both together, as the explorer's glass layer drags, for a while: to and fro over 100 m.
        if options.sustainSeconds > 0 {
            let plan = LiveWave.Plan(scene: layout, cell: coarse)
            let begun = ContinuousClock.now
            var block: [Double] = []
            var blockStart = ContinuousClock.now
            var n = 0
            var all: [Double] = []
            say(
                String(
                    format: "Sustained: the glass's preview and the wave together, for %.0f s",
                    options.sustainSeconds))
            while seconds(begun) < options.sustainSeconds {
                let place = n % 40 < 20 ? n % 20 : 20 - n % 20
                let clock = ContinuousClock.now
                try autoreleasepool {
                    _ = try preview(place, parts: .glass)
                    _ = LiveWave.field(plan: plan, charge: charge(place), mass: mass)
                }
                let s = seconds(clock)
                block.append(s)
                all.append(s)
                n += 1
                if seconds(blockStart) >= 10 || seconds(begun) >= options.sustainSeconds {
                    let sorted = block.sorted()
                    say(
                        String(
                            format: "  to %3.0f s: %d frames, median %@ ms, p90 %@ ms; %@", seconds(begun),
                            block.count,
                            ms(sorted[sorted.count / 2]),
                            ms(sorted[min(sorted.count - 1, sorted.count * 9 / 10)]),
                            memory()))
                    block = []
                    blockStart = .now
                }
            }
            say("Sustained in all: \(summary(all))")
        }
        // Let go: the full estimate the explorer makes once the charge stops, on the CPU, once.
        if options.fullEstimate {
            var full = FacadeLoadSurrogate.Uncertainty(
                yieldLogSD: log(1.5) / 1.645, loadScatter: terms.loadScatter, samples: 100)
            full.stratified = false
            let clock = ContinuousClock.now
            let look = autoreleasepool {
                prepared.look(
                    charge: start, mass: mass, constructions: { scene.envelopeConstruction(for: $0) },
                    uncertainty: full, terms: terms)
            }
            say(
                String(
                    format:
                        "Let go, the full estimate on the CPU (100 draws, %d cores): %.2f s, %d glazed sides; %@",
                    ProcessInfo.processInfo.activeProcessorCount, seconds(clock), look.glass.count, memory()))
        }
        say("Done; \(memory())")
        return lines.joined(separator: "\n")
    }

    /// The memory the process has in use as the system counts it against its limit.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// The hardware's model, e.g. "iPad14,3" or "Mac16,9".
    static func machine() -> String {
        // The Mac's model is hw.model ("Mac16,9"); an iPad's is hw.machine ("iPad14,3").
        #if os(macOS)
            let key = "hw.model"
        #else
            let key = "hw.machine"
        #endif
        var size = 0
        sysctlbyname(key, nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname(key, &name, &size, nil, 0)
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: On a Mac

    static let usage = """
        Usage: BombCAD live-bench [--beirut <explorer-beirut-port-1500m-1.json>]
                                  [--wave-weights <live-wave-unet-1.bcfw> | --no-refinement]
                                  [--frames 21] [--sustain 60] [--no-full] [--out <report.txt>]

        Lays out the explorer's Beirut and times its drag preview by the learned response and its live
        wave, frame by frame, as the explorer drags (emmettl/bombcad-work#119); the iPad viewer does
        the same when launched with BOMBCAD_VIEWER_LIVE_BENCH=1. Beirut's file and the wave's weights
        default to where the app keeps them.
        """

    @MainActor static func main(_ arguments: [String]) -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: "--\(name)").flatMap {
                $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
            }
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        var options = Options.app
        if let frames = value("frames").flatMap(Int.init) { options.frames = max(2, frames) }
        if let sustain = value("sustain").flatMap(Double.init) { options.sustainSeconds = sustain }
        if arguments.contains("--no-full") { options.fullEstimate = false }
        let beirut = value("beirut").map { URL(filePath: $0) } ?? ExplorerModel.beirutURL
        let weights =
            arguments.contains("--no-refinement")
            ? nil : value("wave-weights").map { URL(filePath: $0) } ?? LiveWave.Refinement.defaultWeightsURL
        do {
            let report = try run(beirut: beirut, waveWeights: weights, options: options) { print($0) }
            if let out = value("out") {
                try (report + "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
            return 0
        } catch {
            print("live-bench: \(error)")
            return 1
        }
    }
}

#if !os(macOS)
    import UIKit

    extension LiveBench {
        /// The bench on the iPad, when the viewer is launched with `BOMBCAD_VIEWER_LIVE_BENCH=1`
        /// (`devicectl device process launch -e`, or `SIMCTL_CHILD_` in the Simulator): Beirut's file
        /// and the wave's weights from the app's Documents if they were copied there, else downloaded
        /// from their releases and checked against their pinned SHA-256, as the Mac's explorer fetches
        /// them. Each line goes to `Documents/live-bench.log` as it is made, and the whole report to
        /// `Documents/live-bench.txt` at the end. `BOMBCAD_VIEWER_LIVE_BENCH_FRAMES` and `_SUSTAIN`
        /// (seconds) set its length.
        @MainActor static func onDevice(status: @escaping @MainActor (String) -> Void) {
            let environment = ProcessInfo.processInfo.environment
            var options = Options.app
            if let frames = environment["BOMBCAD_VIEWER_LIVE_BENCH_FRAMES"].flatMap(Int.init) {
                options.frames = max(2, frames)
            }
            if let sustain = environment["BOMBCAD_VIEWER_LIVE_BENCH_SUSTAIN"].flatMap(Double.init) {
                options.sustainSeconds = sustain
            }
            // A bench that sleeps with the screen would time nothing.
            UIApplication.shared.isIdleTimerDisabled = true
            let documents = URL.documentsDirectory
            let logURL = documents.appending(path: "live-bench.log")
            try? FileManager.default.removeItem(at: logURL)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let handle = try? FileHandle(forWritingTo: logURL)
            @Sendable func log(_ line: String) {
                handle?.write(Data((line + "\n").utf8))
                try? handle?.synchronize()
                Task { @MainActor in status(line) }
            }
            let appBeirut = ExplorerModel.beirutItem
            Task.detached(priority: .userInitiated) {
                do {
                    var beirutItem = appBeirut
                    let copied = documents.appending(path: ExplorerScene.Beirut.fileName)
                    if FileManager.default.fileExists(atPath: copied.path) { beirutItem.destination = copied }
                    var waveItem = LearnedFieldDownload.Item(
                        LiveWave.Refinement.Release.asset, to: LiveWave.Refinement.defaultWeightsURL)
                    let copiedWave = documents.appending(path: LiveWave.Refinement.fileName)
                    if FileManager.default.fileExists(atPath: copiedWave.path) {
                        waveItem.destination = copiedWave
                    }
                    let missing = LearnedFieldDownload.missing([beirutItem, waveItem])
                    if !missing.isEmpty {
                        for item in missing {
                            try FileManager.default.createDirectory(
                                at: item.destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
                        }
                        let clock = ContinuousClock.now
                        log(
                            "Downloading "
                                + missing.map { "\($0.source.absoluteString) (\($0.bytes) bytes)" }.joined(
                                    separator: ", "))
                        try await LearnedFieldDownload.install(missing)
                        log(
                            String(
                                format: "Downloaded and checked in %.1f s",
                                clock.duration(to: .now) / .seconds(1)))
                    } else {
                        log("Beirut's file and the wave's weights already here, with their pinned SHA-256")
                    }
                    let report = try run(
                        beirut: beirutItem.destination, waveWeights: waveItem.destination, options: options,
                        emit: log)
                    try (report + "\n").write(
                        to: documents.appending(path: "live-bench.txt"), atomically: true, encoding: .utf8)
                } catch {
                    log("live-bench failed: \(error)")
                }
                try? handle?.close()
                await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
            }
        }
    }
#endif
