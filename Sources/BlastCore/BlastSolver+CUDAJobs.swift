import BlastModel
import CryptoKit
import Foundation
import Metal

extension BlastSolver {
    /// Exports the actual initial grid, including the mapped radial start, for the uniform CUDA
    /// dataset worker. Unsupported physics is refused; no scenario setting is silently changed.
    /// The shader digest identifies the generated CUDA source, supplied by the caller.
    public func exportUniformCUDAJob(
        to folder: URL, sourceSHA256: String, until: Double, above: Float = 2
    ) throws {
        func refuse(_ why: String) throws -> Never {
            throw BlastError.allocationFailed("CUDA job: \(why)")
        }
        guard !batchInFlight, stepCount == 0 else { try refuse("export before the first grid step") }
        guard until > time, until.isFinite, above.isFinite, above >= 0,
            above < Float(grid.nz) * grid.cellSize
        else { try refuse("invalid end time or receiver height") }
        guard sourceSHA256.count == 64, sourceSHA256.allSatisfy({ $0.isHexDigit }) else {
            try refuse("expected a generated-source SHA-256")
        }
        guard !hasBody, experimentalBoxes.isEmpty else { try refuse("moving or deformable bodies") }
        guard refinement == nil, finerRefinement == nil else { try refuse("refined grids") }
        guard structureCut == nil else { try refuse("structural cut cells") }
        guard !hasFlame, congestion == nil else {
            try refuse("deflagration or congestion")
        }
        guard configuration.gravity == nil, configuration.mixing == nil,
            configuration.afterburnLimit == nil, configuration.afterburnMixing == nil,
            !configuration.periodicSides
        else { try refuse("gravity, mixing, burning limits or periodic boundaries") }
        guard pendingFirings.isEmpty, envelopeVenting == nil else { try refuse("delayed events or venting") }
        guard let phase = firstPhaseColumns else {
            try refuse("configure first-phase receiver columns first")
        }
        guard phase.layers == 1 else { try refuse("first-phase columns in more than one layer") }
        guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("job.json").path) else {
            try refuse("job already exists")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let uniforms = makeUniforms()
        let allowed: Set<String> = [
            "dx", "gamma", "cfl", "ambientPressure", "densityFloor", "pressureFloor", "limiterTheta",
            "riemannSolver", "boundaryFlags", "afterburnEnergy", "oxygenPerFuel", "stillOxygen",
            "afterburnRate", "airModel", "stillRho", "stillMx", "stillMy", "stillMz", "stillEnergy",
            "maxStep", "gaugeWalls", "refineMargin",
        ]
        var values: [String: Any] = [:]
        for child in Mirror(reflecting: uniforms).children {
            guard let name = child.label, allowed.contains(name) else { continue }
            if let value = child.value as? Float {
                values[name] = value
            } else if let value = child.value as? UInt32 {
                values[name] = value
            }
        }
        var hashes: [String: String] = [:]
        func write(_ data: Data, _ name: String) throws {
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            hashes[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        func write(_ buffer: MTLBuffer, _ name: String) throws {
            try write(Data(bytes: buffer.contents(), count: buffer.length), name)
        }
        try write(stateBuffers[current], "state.bin")
        try write(maskBuffer, "mask.bin")
        if hasSpecies {
            try write(speciesBuffers[current], "species.bin")
        } else {
            try write(Data(count: grid.cellCount * 8), "species.bin")
        }
        try write(peakBuffer, "peak.bin")
        try write(impulseBuffer, "impulse.bin")
        try write(phase.columns, "columns.bin")
        try write(phase.records, "records.bin")
        try write(phase.open, "open.bin")
        if let cut = terrainCut {
            func geometryBuffer(_ buffer: MTLBuffer, _ activeBytes: Int, _ name: String) throws {
                if activeBytes == 0 {
                    try write(Data(count: 16), name)
                } else {
                    var data = Data(bytes: buffer.contents(), count: activeBytes)
                    if data.count < 16 { data.append(Data(count: 16 - data.count)) }
                    try write(data, name)
                }
            }
            try geometryBuffer(cut.columns, cut.geometry.columns.count * 16, "cut-columns.bin")
            try geometryBuffer(cut.records, cut.geometry.records.count * 16, "cut-records.bin")
            try geometryBuffer(cut.walls, cut.geometry.walls.count * 16, "cut-walls.bin")
            try geometryBuffer(cut.defects, cut.geometry.records.count * 32, "cut-defects.bin")
            try geometryBuffer(cut.cutColumns, cut.geometry.cutColumns.count * 4, "cut-list.bin")
            try geometryBuffer(
                cut.ceilings, cut.geometry.tileCeilings(tileSize: Self.tileSize).count * 4, "cut-ceilings.bin"
            )
        }
        let axes = [grid.nx, grid.ny, grid.nz].enumerated().filter { $0.element > 1 }.map(\.offset)
        var metadata: [String: Any] = [
            "format": "bombcad-cuda-job-1", "sourceSHA256": sourceSHA256,
            "shape": [grid.nx, grid.ny, grid.nz], "uniforms": values,
            "steps": 10_000_000, "duration": until - time, "startTime": time,
            "startStep": stepCount, "startupSteps": max(configuration.startupSteps, 1),
            "above": above, "axes": axes, "files": hashes,
            "description": "BombCAD initial grid; mapped start retained where used",
        ]
        if let cut = terrainCut {
            metadata["terrain"] = [
                "records": cut.geometry.records.count, "cutColumnCount": cut.geometry.cutColumns.count,
            ]
        }
        if let settings = configuration.radiativeCooling {
            let model: AirModel = configuration.airModel == .idealGas ? .idealGas : .thermallyPerfect
            let energy = model.internalEnergy(
                density: 1, pressure: 287.05 * settings.luminousTemperature, gamma: configuration.gamma)
            metadata["cooling"] =
                [
                    "interval": max(settings.interval, 1), "luminous": settings.luminousTemperature,
                    "absorption": settings.absorption, "sootAbsorption": settings.sootAbsorption,
                    "hasSpecies": hasSpecies && configuration.afterburning ? 1 : 0,
                    "largestShare": settings.largestShare, "luminousEnergy": 0.999 * energy,
                    "capacity": 0,
                ] as [String: Any]
        }
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("job.json"), options: .atomic)
    }
}
