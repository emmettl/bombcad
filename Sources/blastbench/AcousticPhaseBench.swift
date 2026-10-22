import BlastCore
import Foundation
import Metal
import simd

/// A fixed weak-wave/reflection/resolution diagnostic. Reports errors; it sets no acceptance gate.
func runAcousticPhase() throws {
    guard let destination = option("out") else {
        throw BlastError.allocationFailed("acoustic-phase requires --out NEW-DIRECTORY")
    }
    let cflText = option("cfl") ?? "0.45"
    guard let cfl = Float(cflText), [Float(0.45), 0.225].contains(cfl) else {
        throw BlastError.allocationFailed("acoustic-phase --cfl takes 0.45 or 0.225")
    }
    let componentText = option("compensated")
    let components = componentText.flatMap(CompensatedSweepComponents.init(rawValue:))
    let discardResiduals = flag("discard-compensation")
    guard (!flag("compensated") || components != nil) && (!discardResiduals || components != nil) else {
        throw BlastError.allocationFailed(
            "acoustic-phase --compensated takes density, energy or both; --discard-compensation requires it")
    }
    let methodName = discardResiduals ? "protected-update-no-carry-v1" : "protected-kahan-v1"
    let sourceStencils = flag("trace-source-stencils")
    guard !sourceStencils || (flag("trace-updates") && components != nil) else {
        throw BlastError.allocationFailed(
            "acoustic-phase --trace-source-stencils requires --trace-updates and --compensated")
    }
    let resolutions = flag("fine") ? [512, 1024, 2048] : [128, 256, 512]
    let onlyCase = option("only-case")
    let caseNames = Set(
        [1, 10, 100].flatMap { amplitude in
            resolutions.flatMap { nx in
                ["a\(amplitude)-n\(nx)-full", "a\(amplitude)-n\(nx)-tiled"]
            }
        })
    guard !flag("only-case") || onlyCase.map({ caseNames.contains($0) }) == true else {
        throw BlastError.allocationFailed(
            "acoustic-phase --only-case requires an exact case in the selected resolution matrix")
    }
    let out = URL(fileURLWithPath: destination)
    guard !FileManager.default.fileExists(atPath: out.path) else {
        throw BlastError.allocationFailed("acoustic-phase refuses to overwrite output")
    }
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    func write(_ value: Any, _ name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appending(path: name), options: .atomic)
    }
    var results: [[String: Any]] = []
    for amplitude in [1.0, 10, 100] {
        for nx in resolutions {
            let reference = AcousticPhaseReference(amplitude: amplitude)
            let dx = Float(16) / Float(nx)
            let indices = [Int(4 / dx), 0]
            for tiled in [false, true] {
                let name = "a\(Int(amplitude))-n\(nx)-\(tiled ? "tiled" : "full")"
                if let onlyCase, onlyCase != name { continue }
                var pair: [[String: Any]] = []
                let modes =
                    sourceStencils
                    ? ["plain", "pressure", "updates", "sources"]
                    : (flag("trace-updates") ? ["plain", "pressure", "updates"] : ["plain", "pressure"])
                for mode in modes {
                    let observed = mode != "plain"
                    let sources = mode == "sources"
                    let updates = mode == "updates" || sources
                    let outputMode =
                        sources ? "sources" : (updates ? "updates" : (observed ? "observed" : "plain"))
                    var configuration = SolverConfiguration()
                    configuration.reflectiveFaces = [.xMin, .yMin, .yMax, .zMin, .zMax]
                    configuration.skipStillAir = tiled
                    configuration.cfl = cfl
                    let solver = try BlastSolver(
                        device: device, grid: Grid(nx: nx, ny: 1, nz: 1, cellSize: dx),
                        configuration: configuration)
                    solver.fill { i, _, _ in
                        let x = Double(Float(i) + 0.5) * Double(dx)
                        let p = reference.pressure(x: x, time: 0)
                        return Primitive(
                            density: Float(reference.density + p / pow(reference.soundSpeed, 2)),
                            velocity: SIMD3(Float(reference.velocity(x: x, time: 0)), 0, 0),
                            pressure: Float(reference.ambientPressure + p))
                    }
                    if let components {
                        try solver.configureCompensatedSweep(components, retainResiduals: !discardResiduals)
                    }
                    try solver.configureFirstPhaseColumns(Array(repeating: SIMD4(0, 0, 0, 1), count: nx))
                    if observed { try solver.configureFirstPhaseDiagnostics(indices, capturePressure: true) }
                    if updates {
                        var cells = [0, nx / 4, nx / 2 - 1, nx / 2, nx / 2 + 1]
                        if components != nil { cells.append(nx - 1) }
                        try solver.configureSweepUpdateDiagnostics(cells, captureHostSources: sources)
                    }
                    let initialPressure = (0..<nx).map {
                        solver.primitive($0, 0, 0).pressure - configuration.ambientPressure
                    }
                    let initialConserved = solver.withState { cells in
                        (0..<nx).map { i in [cells[i].density, cells[i].momentumX, cells[i].energy] }
                    }
                    let initial = solver.firstPhaseDiagnosticStateHashes()
                    let initialResidual = solver.compensatedSweepState()
                    let started = ContinuousClock.now
                    let advanced = solver.advance(until: reference.stopTime)
                    let duration = started.duration(to: .now)
                    let final = solver.firstPhaseDiagnosticStateHashes()
                    let records = solver.firstPhaseSnapshot() ?? []
                    var row: [String: Any] = [
                        "initialHostProjectedOverpressurePa": initialPressure,
                        "initialConservedRhoMxEnergy": initialConserved, "gamma": configuration.gamma,
                        "cfl": cfl,
                        "observed": observed, "sweepUpdatesObserved": updates, "stable": advanced.isStable,
                        "steps": advanced.steps,
                        "time": solver.time, "initialHashes": initial, "finalHashes": final,
                        "records": indices.map { i in
                            [records[i].x, records[i].y, records[i].z, records[i].w]
                        },
                    ]
                    if let components, let initialResidual, let finalResidual = solver.compensatedSweepState()
                    {
                        row["experimentalMethod"] =
                            discardResiduals ? "protected-update-no-carry-v1" : "protected-kahan-v1"
                        row["compensationComponents"] = components.rawValue
                        row["initialResidualBits"] = initialResidual.map {
                            [$0.x, $0.y, $0.z, $0.w].map(\.bitPattern)
                        }
                        row["finalResidualBits"] = finalResidual.map {
                            [$0.x, $0.y, $0.z, $0.w].map(\.bitPattern)
                        }
                        row["finalConservedRhoMxEnergy"] = solver.withState { cells in
                            (0..<nx).map { i in [cells[i].density, cells[i].momentumX, cells[i].energy] }
                        }
                        row["heldGPUBufferBytes"] = solver.memoryFootprint
                        row["advanceWallSeconds"] =
                            Double(duration.components.seconds) + Double(duration.components.attoseconds)
                            / 1e18
                    }
                    if sources { row["hostSourceObserved"] = true }
                    pair.append(row)
                    try write(row, "\(name)-\(outputMode).json")
                    if observed {
                        let trace = try solver.firstPhasePressureTrace()
                        var traceRow: [String: Any] = [
                            "format": "bombcad-acoustic-phase-trace-1",
                            "complete": advanced.isStable && solver.time >= reference.stopTime * (1 - 1e-6),
                            "amplitudePa": amplitude, "nx": nx, "dx": dx, "tiled": tiled, "cfl": cfl,
                            "columns": indices, "x": indices.map { Double(Float($0) + 0.5) * Double(dx) },
                            "seedRecords": trace.seedRecords, "steps": trace.samples.map(\.step),
                            "times": trace.samples.map(\.time), "values": trace.samples.map(\.values),
                            "analyticPeak": indices.map {
                                reference.peak(x: Double(Float($0) + 0.5) * Double(dx))!
                            },
                            "analyticFirstImpulse": indices.map {
                                reference.firstImpulse(x: Double(Float($0) + 0.5) * Double(dx))!
                            },
                            "soundSpeed": reference.soundSpeed,
                        ]
                        if let components {
                            traceRow["experimentalMethod"] = methodName
                            traceRow["compensationComponents"] = components.rawValue
                        }
                        try write(
                            traceRow,
                            sources
                                ? "\(name)-source-pressure-trace.json"
                                : (updates ? "\(name)-update-pressure-trace.json" : "\(name)-trace.json"))
                    }
                    if updates {
                        let trace = try solver.sweepUpdateTrace()
                        var row: [String: Any] = [
                            "format": sources
                                ? "bombcad-compensated-source-stencil-1"
                                : (components == nil
                                    ? "bombcad-production-sweep-updates-1"
                                    : "bombcad-compensated-sweep-updates-1"),
                            "complete": advanced.isStable && solver.time >= reference.stopTime * (1 - 1e-6),
                            "fields": trace.capturedFields, "valueEncoding": "uint32-ieee754-binary32",
                            "indices": trace.indices,
                            "initialStates": trace.initialStates, "finalStates": trace.finalStates,
                            "steps": trace.samples.map(\.step), "times": trace.samples.map(\.time),
                            "dt": trace.samples.map(\.dt), "executed": trace.samples.map(\.executed),
                            "valueBits": trace.samples.map { sample in
                                sample.values.map { $0.map(\.bitPattern) }
                            },
                            "initialStateBits": trace.initialStates.map { $0.map(\.bitPattern) },
                            "finalStateBits": trace.finalStates.map { $0.map(\.bitPattern) },
                        ]
                        if let components {
                            row["experimentalMethod"] = methodName
                            row["compensationComponents"] = components.rawValue
                        }
                        if sources {
                            let source = try solver.sweepSourceStencilTrace()
                            row["sourceObservation"] = "host-physical-cells-before-blocking-part"
                            row["sourcePhysicalIndices"] = source.physicalIndices
                            row["sourceGhostVelocitySigns"] = source.ghostVelocitySigns
                            row["sourceConservedBits"] = source.samples.map(\.conservedBits)
                            row["sourceResidualBits"] = source.samples.map(\.residualBits)
                            row["sourceConservedFields"] = ["rho", "mx", "my", "mz", "energy"]
                            row["sourceResidualFields"] = ["rhoError", "energyError", "mask", "floorEvents"]
                            row["sourceConfiguration"] = [
                                "gamma": configuration.gamma, "dx": dx,
                                "densityFloor": configuration.densityFloor,
                                "pressureFloor": configuration.pressureFloor,
                                "limiterTheta": configuration.limiterTheta,
                            ]
                        }
                        try write(row, sources ? "\(name)-source-stencil.json" : "\(name)-update-trace.json")
                    }
                }
                results.append(["case": name, "runs": pair])
                print("acoustic-phase: \(name) complete")
            }
        }
    }
    try write(
        ["scope": "Fixed ideal-gas linear-acoustic diagnostic; no gate or default change", "cases": results],
        "runs.json")
}
