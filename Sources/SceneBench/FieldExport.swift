import BlastCore
import CryptoKit
import Foundation
import Metal
import simd

/// `scenebench field-export <district-scene's inputs> [--radius 1024] [--dx 4] [--height m]
/// [--until s] [--above 2] [--edge 4] [--ground saturated] [--balloon] [--first-phase] [--id name]
/// [--layout name] [--phase-timings] [--cuda-job --cuda-source generated.cu] --out folder`: one training pair for the learned field model (docs/learned-models.md). The
/// district is laid out as `district-scene` lays it out, the air is run on the recommended
/// configuration until the blast has passed the domain's corners, and the run's own peak
/// overpressure and positive impulse fields are read at a fixed height above the ground on the
/// air's plan grid. No envelope histories are recorded, so it costs the air alone.
///
/// The folder gets `inputs.npy` (channels × rows × columns: the buildings' heights over the ground,
/// the ground, the distance from the charge, its scaled distance and Kingery–Bulmash's incident
/// peak and impulse there), `targets.npy` (peak overpressure, Pa, and positive impulse, Pa s),
/// `mask.npy` (1 where the target is air at that height and away from the side faces), all
/// little-endian float32 `.npy` files, and `meta.json`. Rows run north (y), columns east (x).
///
/// `--first-phase` adds a third target, the first positive phase's impulse by the façade
/// recorder's rule (`FirstPhaseColumns`), recorded at the same height as the run goes. It is off
/// unless asked for, and it only observes: the run is the same to the bit either way.
///
/// `district-compare --export-field folder` writes the same files from its own run.
enum FieldExport {
    /// The channels of `inputs.npy`, in order, with their units.
    static let inputChannels: [(name: String, units: String)] = [
        ("height", "m above the ground: the tallest block over the cell's centre, 0 for none"),
        ("ground", "m, the ground at the cell's centre above the ground under the charge"),
        ("distance", "m, in plan from the charge to the cell's centre"),
        ("logScaledDistance", "ln(Z), Z = max(distance, cell / 2) / W^(1/3) in m/kg^(1/3)"),
        ("kingeryBulmashPeak", "Pa, incident peak overpressure of a hemispherical surface burst at Z"),
        ("kingeryBulmashImpulse", "Pa s, incident positive impulse at Z"),
    ]
    static let targetChannels: [(name: String, units: String)] = [
        ("peakOverpressure", "Pa, the run's largest overpressure in the cell at the height"),
        ("impulse", "Pa s, the run's positive-phase impulse in the cell at the height"),
    ]
    /// The target `--first-phase` adds.
    static let firstPhaseChannel = (
        name: "firstPhaseImpulse",
        units:
            "Pa s, the first positive phase's impulse at the height, by the façade recorder's rule: from the start until the overpressure first falls below nothing after reaching half its peak"
    )

    struct Meta: Codable {
        struct Channel: Codable {
            var name: String
            var units: String
        }
        struct ChargeInfo: Codable {
            var massKg: Double
            var yieldKt: Double
            var positionM: [Float]
            var cell: [Int]
        }
        var format = "bombcad-field-1"
        var id: String
        var layout: String?
        var index =
            "[channel, row, column]: rows from the south going north (y), columns from the west going east (x)"
        var cellSizeM: Float
        var rows: Int
        var columns: Int
        var originM: [Float] = [0, 0]
        var domainM: [Float]
        var cells: Int
        /// The solver's memory, bytes: for sizing the runs' memory declarations.
        var solverBytes: Int
        var heightAboveGroundM: Float
        var edgeCells: Int
        var charge: ChargeInfo
        var buildings: Int
        var inputs: [Channel]
        var targets: [Channel]
        var mask = "1 where the target is air at the height and at least edgeCells from the side faces"
        var configuration: String
        var ground: String?
        var untilS: Double
        var steps: Int
        var wallS: Double
        var stable: Bool
        var maskedShare: Double
        var sourceRevision: String?
        var arguments: [String]?
        var made: String
    }

    // MARK: - The subcommand

    static func run(_ args: [String]) throws {
        func value(_ name: String) -> String? {
            args.firstIndex(of: "--\(name)").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        let timingStart = ContinuousClock.now
        var phaseSeconds: [String: Double] = [:]
        func writeTimings(folder: URL, mode: String, solve: Double, outputStart: ContinuousClock.Instant)
            throws
        {
            guard args.contains("--phase-timings") else { return }
            phaseSeconds["solveSeconds"] = solve
            phaseSeconds["outputSeconds"] = (ContinuousClock.now - outputStart) / .seconds(1)
            let report: [String: Any] = [
                "format": "bombcad-field-phases-1", "mode": mode, "clock": "Swift ContinuousClock",
                "seconds": phaseSeconds,
                "totalSecondsBeforeTimingReceipt": (ContinuousClock.now - timingStart) / .seconds(1),
                "scope":
                    "Scene preparation; solver setup including shader compilation, allocation and initial state; recorder setup; solve; output. Excludes process startup, gpu-slot waiting and this receipt write. Compilation is included in solver setup, not isolated.",
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appending(path: "phase-timings.json"), options: .withoutOverwriting)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let out = value("out"), let device = MTLCreateSystemDefaultDevice() else {
            throw BlastError.allocationFailed("--out folder and a Metal device")
        }
        let inputs = try DistrictInputs.read(args)
        let radius = Float(value("radius").flatMap(Double.init) ?? 1024)
        let dx = inputs.cellSize
        var layout = DistrictLayout(buildings: inputs.buildings, charge: inputs.centre, mass: inputs.mass)
        layout.ground = inputs.ground
        layout.heights = inputs.heights
        layout.seaBase = inputs.seaBase
        layout.attributions = inputs.attributions
        // The top by the open-face rule (`DistrictLayout.top`) unless `--height` is given.
        let (built, report) = try layout.scene(
            halfSide: radius, cellSize: dx, height: value("height").flatMap(Float.init),
            name: value("id"))
        var scene = built
        scene.gauges = []
        print(report.summary)
        guard !scene.chargeIsBlocked else { throw BlastError.chargeBlocked(scene.charge.position) }
        let mass = Double(scene.charge.mass)
        let until = value("until").flatMap(Double.init) ?? duration(halfSide: radius, mass: mass)
        var configuration =
            args.contains("--balloon")
            ? SolverConfiguration.recommended.balloonStart : SolverConfiguration.recommended
        if let name = value("ground") {
            guard let type = GroundType(rawValue: name) else {
                throw BlastError.allocationFailed("--ground \(name)")
            }
            configuration.ground = type
        }
        guard !(args.contains("--full-grid-diagnostic") && args.contains("--all-tiles-diagnostic")) else {
            throw BlastError.allocationFailed("choose full-grid or all-tiles diagnostic, not both")
        }
        guard
            !args.contains("--cuda-job")
                || !(args.contains("--full-grid-diagnostic") || args.contains("--all-tiles-diagnostic"))
        else {
            throw BlastError.allocationFailed(
                "execution-path diagnostics require a production run, not --cuda-job")
        }
        if args.contains("--full-grid-diagnostic") { configuration.skipStillAir = false }
        if value("trace-columns") != nil && (args.contains("--cuda-job") || !args.contains("--first-phase")) {
            throw BlastError.allocationFailed(
                "production --trace-columns requires --first-phase and excludes --cuda-job")
        }
        let solverSetupStart = ContinuousClock.now
        phaseSeconds["scenePreparationSeconds"] = (solverSetupStart - timingStart) / .seconds(1)
        let solver = try BlastSolver(
            device: device, scenario: scene, cellSize: dx, configuration: configuration)
        let recorderSetupStart = ContinuousClock.now
        phaseSeconds["solverSetupIncludingCompileSeconds"] =
            (recorderSetupStart - solverSetupStart) / .seconds(1)
        if args.contains("--all-tiles-diagnostic") { try solver.activateAllAirTilesForDiagnostics() }
        let above = Float(value("above").flatMap(Double.init) ?? 2)
        if args.contains("--first-phase") || args.contains("--cuda-job") {
            try recordFirstPhase(solver: solver, scene: scene, above: above)
        }
        let traceIndices: [Int]
        if let text = value("trace-columns") {
            let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            traceIndices = parts.compactMap { Int($0) }
            guard traceIndices.count == parts.count else {
                throw BlastError.allocationFailed("comma-separated integer trace columns")
            }
            try solver.configureFirstPhaseDiagnostics(traceIndices)
        } else {
            traceIndices = []
        }
        phaseSeconds["recorderSetupSeconds"] = (ContinuousClock.now - recorderSetupStart) / .seconds(1)
        print(
            String(
                format: "%d × %d × %d cells (%.1f M), %.0f m top, %.0f kg, to %.2f s", solver.grid.nx,
                solver.grid.ny, solver.grid.nz, Double(solver.grid.cellCount) / 1e6, scene.domainSize.z, mass,
                until))
        if args.contains("--cuda-job") {
            let outputStart = ContinuousClock.now
            guard let shader = value("cuda-source") else {
                throw BlastError.allocationFailed("--cuda-source generated.cu is required with --cuda-job")
            }
            let shaderBytes = try Data(contentsOf: URL(filePath: shader))
            let hash = SHA256.hash(data: shaderBytes).map { String(format: "%02x", $0) }.joined()
            let folder = URL(filePath: out)
            guard !FileManager.default.fileExists(atPath: folder.path) else {
                throw BlastError.allocationFailed("a new output folder for the CUDA job")
            }
            // Export first: refusal must not leave an apparently usable training pair.
            try solver.exportUniformCUDAJob(to: folder, sourceSHA256: hash, until: until, above: above)
            try write(
                solver: solver, scene: scene, folder: folder, id: value("id") ?? folder.lastPathComponent,
                layout: value("layout"), buildings: report.placed.count, above: above,
                edgeCells: value("edge").flatMap(Int.init) ?? 4, configuration: "recommended; awaiting CUDA",
                ground: value("ground"), steps: 0, wallS: 0, stable: false, arguments: args)
            if !args.contains("--first-phase") {
                let metaURL = folder.appendingPathComponent("meta.json")
                var meta = try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as! [String: Any]
                meta["targets"] = Array((meta["targets"] as! [[String: Any]]).prefix(2))
                try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
                    .write(to: metaURL)
            }
            try FileManager.default.removeItem(at: folder.appendingPathComponent("targets.npy"))
            let jobURL = folder.appendingPathComponent("job.json")
            var job = try JSONSerialization.jsonObject(with: Data(contentsOf: jobURL)) as! [String: Any]
            var templates: [String: String] = [:]
            for name in ["inputs.npy", "mask.npy", "meta.json"] {
                let bytes = try Data(contentsOf: folder.appendingPathComponent(name))
                templates[name] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }
            job["dataset"] = templates
            try JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys]).write(
                to: jobURL)
            print(
                "CUDA job ready at \(folder.path); no grid simulation or training targets generated on this Mac"
            )
            try writeTimings(folder: folder, mode: "cuda-prepare", solve: 0, outputStart: outputStart)
            return
        }
        let start = ContinuousClock.now
        var steps = 0
        var stable = true
        var lastReport = 0.0
        while solver.time < until {
            let batch = solver.advance(until: until)
            steps += batch.steps
            guard batch.steps > 0 else { break }
            guard batch.isStable else {
                print("Unstable at t \(solver.time) s")
                stable = false
                break
            }
            if solver.time - lastReport >= 0.5 {
                lastReport = solver.time
                print(
                    String(
                        format: "  t %.2f s, %d steps, %.0f s", solver.time, steps,
                        DistrictBenchmark.seconds(start)))
            }
        }
        let wall = DistrictBenchmark.seconds(start)
        let outputStart = ContinuousClock.now
        print(String(format: "Ran to %.3f s in %d steps, %.0f s", solver.time, steps, wall))
        let folder = URL(filePath: out)
        try write(
            solver: solver, scene: scene, folder: folder, id: value("id") ?? folder.lastPathComponent,
            layout: value("layout"), buildings: report.placed.count, above: above,
            edgeCells: value("edge").flatMap(Int.init) ?? 4,
            configuration: (args.contains("--balloon") ? "recommended, balloon start" : "recommended")
                + (args.contains("--full-grid-diagnostic") ? "; full-grid diagnostic" : "")
                + (args.contains("--all-tiles-diagnostic") ? "; all-tiles diagnostic" : ""),
            ground: value("ground"), steps: steps, wallS: wall, stable: stable, arguments: args)
        if !traceIndices.isEmpty {
            let samples = solver.firstPhaseDiagnosticSamples()
            try NPY.write(
                samples.flatMap { $0.values.flatMap { $0 } },
                shape: [samples.count, traceIndices.count, 8],
                to: folder.appending(path: "production-trace.npy"))
            let info: [String: Any] = [
                "format": "bombcad-production-phase-trace-1",
                "columns": traceIndices, "steps": samples.map(\.step), "times": samples.map(\.time),
                "fields": [
                    "peak", "allPositiveImpulse", "firstPhaseImpulse", "phasePeak", "open",
                    "accumulatedPeak", "accumulatedImpulse", "dt",
                ],
                "sampling":
                    "after every active step; normal logical batches preserved; no new shaders; initial sample omitted",
                "skipStillAir": configuration.skipStillAir,
                "allTilesInitiallyActive": args.contains("--all-tiles-diagnostic"),
            ]
            try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appending(path: "production-trace.json"))
        }
        try writeTimings(folder: folder, mode: "metal", solve: wall, outputStart: outputStart)
        guard stable else { throw BlastError.allocationFailed("a stable run (written with stable: false)") }
    }

    /// How long a run must go for every cell of a square of half side `halfSide` about a charge of
    /// `mass` kg to have seen its positive phase: Kingery–Bulmash's arrival at the corners and the
    /// positive duration there, a tenth more, to a hundredth of a second.
    static func duration(halfSide: Float, mass: Double) -> Double {
        let root = cbrt(mass)
        let corner = Double(halfSide) * 2.squareRoot()
        let z = corner / root
        let arrival: Double
        let positive: Double
        if z <= 40, let a = KingeryBulmash.scaledArrival(at: z), let d = KingeryBulmash.scaledDuration(at: z)
        {
            arrival = a * root
            positive = d * root
        } else {
            // Beyond the fits, the shock is nearly sound.
            arrival = (KingeryBulmash.scaledArrival(at: 40) ?? 0) * root + (corner - 40 * root) / 343
            positive = (KingeryBulmash.scaledDuration(at: 40) ?? 0) * root
        }
        return ((arrival + positive) * 1.1 * 100).rounded(.up) / 100
    }

    /// Kingery–Bulmash's incident peak (Pa) and impulse (Pa s) at scaled distance `z` for `mass`
    /// kg: held at its fits' near end (0.2 m/kg^(1/3)) and carried on beyond the far end (40) by
    /// the slope of its last stretch in log-log.
    static func kingeryBulmash(z: Double, mass: Double) -> (peak: Double, impulse: Double) {
        func at(_ z: Double) -> (Double, Double) {
            guard let p = KingeryBulmash.point(at: z) else { return (0, 0) }
            return (p.incidentPressure, p.incidentImpulse(mass: mass))
        }
        if z < 0.2 { return at(0.2) }
        if z <= 40 { return at(z) }
        let (p40, i40) = at(40)
        let (p36, i36) = at(36)
        let span = log(40.0 / 36)
        let sp = log(p40 / p36) / span
        let si = log(i40 / i36) / span
        return (p40 * pow(z / 40, sp), i40 * pow(z / 40, si))
    }

    // MARK: - The files

    /// The two cells over plan cell (`i`, `j`) whose centres span `height` m (the ground's there
    /// plus the height over it), and the share of the upper: both when both are air, else the one
    /// that is (`both` false); nil when neither is.
    static func readCells(solver: BlastSolver, i: Int, j: Int, height: Float) -> (
        k0: Int, k1: Int, share: Float, both: Bool
    )? {
        let grid = solver.grid
        let s = height / grid.cellSize - 0.5
        let k0 = max(0, min(grid.nz - 1, Int(s.rounded(.down))))
        let k1 = min(grid.nz - 1, k0 + 1)
        let t = max(0, min(1, s - Float(k0)))
        let open0 = !solver.isSolid(i, j, k0)
        let open1 = !solver.isSolid(i, j, k1)
        if open0 && open1 { return (k0, k1, t, true) }
        if open0 || open1 {
            let k = open0 ? k0 : k1
            return (k, k, 0, false)
        }
        return nil
    }

    /// The ground's height under plan cell (`i`, `j`)'s centre.
    static func groundAt(_ scene: Scenario, _ i: Int, _ j: Int, cellSize dx: Float) -> Float {
        scene.terrain?.height(at: SIMD2((Float(i) + 0.5) * dx, (Float(j) + 0.5) * dx)) ?? 0
    }

    /// Sets `solver` to record the first positive phase's impulse `above` m over the ground in every
    /// plan cell's column, between the cells `write` reads the fields from (`--first-phase`).
    static func recordFirstPhase(solver: BlastSolver, scene: Scenario, above: Float) throws {
        let grid = solver.grid
        var columns = [SIMD4<Float>](repeating: .zero, count: grid.nx * grid.ny)
        for j in 0..<grid.ny {
            for i in 0..<grid.nx {
                let height = groundAt(scene, i, j, cellSize: grid.cellSize) + above
                if let cells = readCells(solver: solver, i: i, j: j, height: height) {
                    columns[i + grid.nx * j] = SIMD4(Float(cells.k0), Float(cells.k1), cells.share, 1)
                }
            }
        }
        try solver.configureFirstPhaseColumns(columns)
    }

    /// Writes the training pair for `solver`'s run of `scene` into `folder`.
    static func write(
        solver: BlastSolver, scene: Scenario, folder: URL, id: String, layout: String?, buildings: Int,
        above: Float, edgeCells: Int, configuration: String, ground: String?, steps: Int, wallS: Double,
        stable: Bool, arguments: [String]?
    ) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let grid = solver.grid
        let dx = grid.cellSize
        let (nx, ny) = (grid.nx, grid.ny)
        let plan = nx * ny
        let charge = scene.charge.position
        let chargeGround = scene.terrain?.height(at: SIMD2(charge.x, charge.y)) ?? 0
        let mass = Double(scene.charge.mass)
        let root = cbrt(mass)
        var groundMap = [Float](repeating: 0, count: plan)
        for j in 0..<ny {
            for i in 0..<nx { groundMap[i + nx * j] = groundAt(scene, i, j, cellSize: dx) }
        }
        // The buildings' tops over the cells whose centres their blocks cover, as the air holds them.
        var top = [Float](repeating: -.greatestFiniteMagnitude, count: plan)
        let blocks = scene.envelopeObjects.flatMap { $0.envelope?.blocks ?? [] } + scene.boxes
        for block in blocks {
            let i0 = max(0, Int((block.min.x / dx - 0.5).rounded(.up)))
            let i1 = min(nx - 1, Int((block.max.x / dx - 0.5).rounded(.up)) - 1)
            let j0 = max(0, Int((block.min.y / dx - 0.5).rounded(.up)))
            let j1 = min(ny - 1, Int((block.max.y / dx - 0.5).rounded(.up)) - 1)
            guard i0 <= i1, j0 <= j1 else { continue }
            for j in j0...j1 {
                for i in i0...i1 { top[i + nx * j] = max(top[i + nx * j], block.max.z) }
            }
        }
        // `--first-phase`: the first phase's impulse, recorded between the same cells.
        let firstPhase = solver.firstPhaseSnapshot()
        let targetNames = targetChannels + (firstPhase == nil ? [] : [firstPhaseChannel])
        var inputs = [Float](repeating: 0, count: inputChannels.count * plan)
        var targets = [Float](repeating: 0, count: targetNames.count * plan)
        var mask = [Float](repeating: 0, count: plan)
        for j in 0..<ny {
            for i in 0..<nx {
                let n = i + nx * j
                let g = groundMap[n]
                let height = top[n] > g ? top[n] - g : 0
                let x = (Float(i) + 0.5) * dx
                let y = (Float(j) + 0.5) * dx
                let distance = Double(simd_distance(SIMD2(x, y), SIMD2(charge.x, charge.y)))
                let z = max(distance, Double(dx) / 2) / root
                let kb = kingeryBulmash(z: z, mass: mass)
                inputs[0 * plan + n] = height
                inputs[1 * plan + n] = g - chargeGround
                inputs[2 * plan + n] = Float(distance)
                inputs[3 * plan + n] = Float(log(z))
                inputs[4 * plan + n] = Float(kb.peak)
                inputs[5 * plan + n] = Float(kb.impulse)
                // The fields at `above` over the ground: between the two cells whose centres span the
                // height, or the nearer open one; none in a building or within the edge.
                guard height == 0, i >= edgeCells, j >= edgeCells, i < nx - edgeCells, j < ny - edgeCells
                else {
                    continue
                }
                guard let (k0, k1, t, both) = readCells(solver: solver, i: i, j: j, height: g + above) else {
                    continue
                }
                let peak: Float
                let impulse: Float
                if both {
                    peak = (1 - t) * solver.peakOverpressure(i, j, k0) + t * solver.peakOverpressure(i, j, k1)
                    impulse = (1 - t) * solver.impulse(i, j, k0) + t * solver.impulse(i, j, k1)
                } else {
                    peak = solver.peakOverpressure(i, j, k0)
                    impulse = solver.impulse(i, j, k0)
                }
                guard peak.isFinite, impulse.isFinite else { continue }
                if let firstPhase {
                    let first = firstPhase[n].z
                    guard first.isFinite else { continue }
                    targets[2 * plan + n] = first
                }
                targets[0 * plan + n] = peak
                targets[1 * plan + n] = impulse
                mask[n] = 1
            }
        }
        try NPY.write(inputs, shape: [inputChannels.count, ny, nx], to: folder.appending(path: "inputs.npy"))
        try NPY.write(targets, shape: [targetNames.count, ny, nx], to: folder.appending(path: "targets.npy"))
        try NPY.write(mask, shape: [ny, nx], to: folder.appending(path: "mask.npy"))
        let ci = Int(charge.x / dx)
        let cj = Int(charge.y / dx)
        let meta = Meta(
            id: id, layout: layout, cellSizeM: dx, rows: ny, columns: nx,
            domainM: [scene.domainSize.x, scene.domainSize.y, scene.domainSize.z], cells: grid.cellCount,
            solverBytes: solver.memoryFootprint, heightAboveGroundM: above, edgeCells: edgeCells,
            charge: Meta.ChargeInfo(
                massKg: mass, yieldKt: mass / 1e6, positionM: [charge.x, charge.y, charge.z], cell: [ci, cj]),
            buildings: buildings,
            inputs: inputChannels.map { Meta.Channel(name: $0.name, units: $0.units) },
            targets: targetNames.map { Meta.Channel(name: $0.name, units: $0.units) },
            configuration: configuration, ground: ground, untilS: solver.time, steps: steps, wallS: wallS,
            stable: stable, maskedShare: Double(mask.reduce(0, +)) / Double(plan),
            sourceRevision: ProcessInfo.processInfo.environment["BOMBCAD_SOURCE_REVISION"],
            arguments: arguments,
            made: ISO8601DateFormatter().string(from: Date()))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: folder.appending(path: "meta.json"))
        print(
            String(
                format: "Wrote %@: %d × %d, %.0f%% of cells in the mask, peak %.1f kPa at most",
                folder.path, nx, ny, 100 * meta.maskedShare,
                Double(targets[0..<plan].max() ?? 0) / 1000))
    }
}

/// NumPy's `.npy` format, version 1.0, for little-endian float32 arrays in C order: the magic
/// string, the version, the header's length and a Python dict literal padded with spaces to a
/// multiple of 64 bytes, then the values.
enum NPY {
    static func header(shape: [Int]) -> Data {
        let dims = shape.map(String.init).joined(separator: ", ") + (shape.count == 1 ? "," : "")
        var text = "{'descr': '<f4', 'fortran_order': False, 'shape': (\(dims)), }"
        // Magic (6), version (2) and length (2), then the dict and a newline, to a multiple of 64.
        let unpadded = 10 + text.utf8.count + 1
        text += String(repeating: " ", count: (64 - unpadded % 64) % 64) + "\n"
        var data = Data([0x93] + Array("NUMPY".utf8) + [1, 0])
        let length = UInt16(text.utf8.count)
        data.append(contentsOf: [UInt8(length & 0xff), UInt8(length >> 8)])
        data.append(contentsOf: Array(text.utf8))
        return data
    }

    static func write(_ values: [Float], shape: [Int], to url: URL) throws {
        precondition(values.count == shape.reduce(1, *), "the values fill the shape")
        var data = header(shape: shape)
        data.reserveCapacity(data.count + 4 * values.count)
        #if _endian(little)
            values.withUnsafeBytes { data.append(contentsOf: $0) }
        #else
            for value in values {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
        #endif
        try data.write(to: url)
    }
}
