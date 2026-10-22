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
    let resolutions = flag("fine") ? [512, 1024, 2048] : [128, 256, 512]
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
                var pair: [[String: Any]] = []
                let modes = flag("trace-updates") ? ["plain", "pressure", "updates"] : ["plain", "pressure"]
                for mode in modes {
                    let observed = mode != "plain"
                    let updates = mode == "updates"
                    let outputMode = updates ? "updates" : (observed ? "observed" : "plain")
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
                    try solver.configureFirstPhaseColumns(Array(repeating: SIMD4(0, 0, 0, 1), count: nx))
                    if observed { try solver.configureFirstPhaseDiagnostics(indices, capturePressure: true) }
                    if updates {
                        try solver.configureSweepUpdateDiagnostics([
                            0, nx / 4, nx / 2 - 1, nx / 2, nx / 2 + 1,
                        ])
                    }
                    let initialPressure = (0..<nx).map {
                        solver.primitive($0, 0, 0).pressure - configuration.ambientPressure
                    }
                    let initialConserved = solver.withState { cells in
                        (0..<nx).map { i in [cells[i].density, cells[i].momentumX, cells[i].energy] }
                    }
                    let initial = solver.firstPhaseDiagnosticStateHashes()
                    let advanced = solver.advance(until: reference.stopTime)
                    let final = solver.firstPhaseDiagnosticStateHashes()
                    let records = solver.firstPhaseSnapshot() ?? []
                    let row: [String: Any] = [
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
                    pair.append(row)
                    try write(row, "\(name)-\(outputMode).json")
                    if observed {
                        let trace = try solver.firstPhasePressureTrace()
                        let traceRow: [String: Any] = [
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
                        try write(
                            traceRow, updates ? "\(name)-update-pressure-trace.json" : "\(name)-trace.json")
                    }
                    if updates {
                        let trace = try solver.sweepUpdateTrace()
                        let row: [String: Any] = [
                            "format": "bombcad-production-sweep-updates-1",
                            "complete": advanced.isStable && solver.time >= reference.stopTime * (1 - 1e-6),
                            "fields": SweepUpdateTrace.fields, "valueEncoding": "uint32-ieee754-binary32",
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
                        try write(row, "\(name)-update-trace.json")
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
