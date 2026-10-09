import BlastCore
import Foundation
import Metal

struct StreetBodySample: Codable {
    var timeS: Double
    var displacementM: Float
    var damage: Float
    var activeElements: Int
    var removedElements: Int
}

struct StreetBodyHistory: Codable {
    var id: UUID
    var name: String
    var samples: [StreetBodySample] = []
}

struct StreetGauge: Codable {
    var name: String
    var positionM: [Float]
    var coarseCellCentreM: [Float]
    var fineCellCentreM: [Float]?
    var peakPa: Float
    var positiveImpulsePaS: Double
    var arrivalS: Double?
    var samples: [[Double]]
}

struct StreetRun: Codable {
    var id: String
    var layout: String
    var purpose: String
    var cellSizeM: Float
    var refinement: Int
    var cfl: Float
    var sourceRadiusM: Float
    var sourceMassKg: Float
    var reflectiveFaces: UInt32
    var durationS: Double
    var steps: Int
    var setupWallS: Double
    var runWallS: Double
    var commandGPUS: Double
    var profile: BatchGPUProfile?
    var solverBytes: Int
    var coupling: CouplingStatistics
    var maximumRefinedPatches: Int
    var massInitialKg: Double
    var massFinalKg: Double
    var energyInitialJ: Double
    var energyFinalJ: Double
    var gaugeObservations: [StreetGauge]
    var bodies: [StreetBodyHistory]
    var mapFile: String
    var stable: Bool
}

struct StreetReport: Codable {
    var schemaVersion = 1
    var sourceRevision: String
    var device: String
    var system: String
    var planeHeightM: Float = 1.5
    var arrivalThresholdPa: Float = 1000
    var sourceDepositionRadiusM: Float = 1
    var structuralElementSizeM: Float = 0.5
    var durationS: Double
    var completeMatrix: Bool
    var notes = [
        "Invented RC shell buildings; conventional 2 kg TNT-equivalent source; no measured validation.",
        "Fixed 1 m energy-deposition radius is a numerical control, not a resolved detonation.",
        "Maps use x-fast coarse cell averages, vertically interpolated pressure at 1.5 m; fine state is restricted.",
        "Positive map impulse uses right endpoints; arrival is first endpoint >= 1000 Pa, without interpolation.",
        "Masked-at-any-time points and unreached arrivals are null; map peak/impulse include the whole finite window.",
        "Gauge histories use containing-cell centres (fine child where present); gauge impulse is trapezoidal.",
        "Bodies are sampled at batch endpoints; reported displacement includes gravity and is not an exact stepwise peak.",
        "Open-boundary inventory changes are not conservation residuals. Closed clamped companions test stationary-wall conservation.",
        "Throughput runs have exposure recording enabled and stage profiling disabled; separate profiled replays include encoder overhead.",
    ]
    var observations: [StreetRun]
}

enum StreetBenchmark {
    struct Setting {
        var name: String
        var dx: Float
        var refinement = 1
        var cfl: Float = 0.45
    }

    static func run(_ args: [String]) throws {
        guard let destination = args.first, !destination.hasPrefix("--") else {
            throw BlastError.allocationFailed("street output directory")
        }
        let directory = URL(filePath: destination)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let device = MTLCreateSystemDefaultDevice() else { throw BlastError.allocationFailed("Metal") }
        let quick = args.contains("--quick")
        let duration = quick ? 0.012 : 0.12
        let settings =
            quick
            ? [Setting(name: "coarse", dx: 1)]
            : [
                Setting(name: "coarse", dx: 1), Setting(name: "medium", dx: 0.5),
                Setting(name: "fine", dx: 0.25), Setting(name: "adaptive", dx: 0.5, refinement: 2),
                Setting(name: "half-cfl", dx: 0.25, cfl: 0.225),
            ]
        var observations: [StreetRun] = []
        for layout in StreetInteractionStudy.Layout.allCases {
            let scene = try StreetInteractionStudy.make(layout)
            try write(scene, to: directory.appending(path: "\(layout.rawValue)-layout.json"))
            for setting in settings {
                let id = "\(layout.rawValue)-\(setting.name)"
                let observation = try execute(
                    device: device, scene: scene, layout: layout.rawValue, setting: setting,
                    id: id, purpose: "interaction", duration: duration, directory: directory)
                observations.append(observation)
                try write(observations, to: directory.appending(path: "progress.json"))
            }
        }
        if !quick {
            var scene = try StreetInteractionStudy.make(.street, clamped: true)
            scene.reflectiveFaces = .all
            for setting in settings.prefix(3) {
                observations.append(
                    try execute(
                        device: device, scene: scene, layout: "street", setting: setting,
                        id: "closed-\(setting.name)", purpose: "closed-conservation", duration: 0.06,
                        directory: directory))
            }
            let sceneWithGravity = try StreetInteractionStudy.make(.street)
            var sceneWithoutBlast = sceneWithGravity
            sceneWithoutBlast.charge.mass = 0
            observations.append(
                try execute(
                    device: device, scene: sceneWithoutBlast, layout: "street", setting: settings[2],
                    id: "gravity-control", purpose: "gravity-control", duration: duration,
                    directory: directory))
            observations.append(
                try execute(
                    device: device, scene: sceneWithGravity, layout: "street", setting: settings[2],
                    id: "profiled-street", purpose: "stage-profile", duration: duration,
                    directory: directory, profile: true))
        }
        try write(
            StreetReport(
                sourceRevision: args.first { $0.hasPrefix("--source-revision=") }.map {
                    String($0.dropFirst(18))
                } ?? "working-tree",
                device: device.name, system: ProcessInfo.processInfo.operatingSystemVersionString,
                durationS: duration, completeMatrix: !quick, observations: observations),
            to: directory.appending(path: "report.json"))
        try? FileManager.default.removeItem(at: directory.appending(path: "progress.json"))
    }

    static func execute(
        device: MTLDevice, scene: Scenario, layout: String, setting: Setting, id: String,
        purpose: String, duration: Double, directory: URL, profile: Bool = false
    ) throws -> StreetRun {
        var config = SolverConfiguration()
        config.refinement = setting.refinement
        config.refinementMemory = 128 << 20
        config.refinementThreshold = 0.05
        config.cfl = setting.cfl
        config.minimumBalloonCells = Float(setting.refinement) / setting.dx
        config.airSleepThreshold = 0
        config.airSleepCrossings = 0
        let setupStart = ProcessInfo.processInfo.systemUptime
        let solver = try BlastSolver(
            device: device, scenario: scene, cellSize: setting.dx, configuration: config)
        try solver.configureExposurePlane(heightM: 1.5, arrivalThresholdPa: 1000)
        if profile { try solver.enableGPUProfiling(true) }
        let setup = ProcessInfo.processInfo.systemUptime - setupStart
        let initial = solver.totals()
        var histories = solver.bodies.map { StreetBodyHistory(id: $0.id, name: $0.name) }
        var gpu = 0.0
        var stages = BatchGPUProfile()
        var maxPatches = 0
        var stable = true
        let start = ProcessInfo.processInfo.systemUptime
        while duration - solver.time > 1e-7 * duration {
            guard let command = solver.encodeBatch(steps: 8, timeLimit: duration) else {
                throw BlastError.allocationFailed("\(id) stopped encoding at \(solver.time)")
            }
            command.commit()
            command.waitUntilCompleted()
            let result = solver.completeBatch()
            gpu += command.gpuEndTime - command.gpuStartTime
            maxPatches = max(maxPatches, result.refinedTiles)
            stable =
                stable && result.isStable && !result.unsupportedInteraction
                && !result.couplingCapacityExceeded && command.error == nil
            if profile {
                guard let sample = solver.lastBatchGPUProfile else {
                    throw BlastError.allocationFailed("GPU counter resolve")
                }
                stages.airS += sample.airS
                stages.mechanicsS += sample.mechanicsS
                stages.couplingS += sample.couplingS
                stages.observationS += sample.observationS
            }
            for index in histories.indices {
                guard let body = solver.body(id: histories[index].id), let summary = body.summary() else {
                    continue
                }
                stable = stable && !summary.hasBlownUp
                histories[index].samples.append(
                    StreetBodySample(
                        timeS: solver.time, displacementM: summary.maxDisplacement,
                        damage: summary.maxDamage, activeElements: summary.activeElements,
                        removedElements: summary.erodedElements))
            }
            if result.steps == 0 || !stable { break }
        }
        let wall = ProcessInfo.processInfo.systemUptime - start
        guard stable, abs(solver.time - duration) < 1e-7 else {
            throw BlastError.allocationFailed("\(id) incomplete or unstable")
        }
        let final = solver.totals()
        var gauges: [StreetGauge] = []
        for (index, gauge) in scene.gauges.enumerated() {
            let samples = solver.gaugeHistories[index]
            let peak = max(
                0, (samples.map(\.pressure).max() ?? scene.atmosphere.pressure) - scene.atmosphere.pressure)
            let impulse = zip(samples, samples.dropFirst()).reduce(0.0) { total, pair in
                total + (pair.1.time - pair.0.time)
                    * Double(max(0, 0.5 * (pair.0.pressure + pair.1.pressure) - scene.atmosphere.pressure))
            }
            let cell = solver.grid.cell(containing: gauge.position)
            let centre = solver.grid.cellCentre(cell.i, cell.j, cell.k)
            gauges.append(
                StreetGauge(
                    name: gauge.name, positionM: [gauge.position.x, gauge.position.y, gauge.position.z],
                    coarseCellCentreM: [centre.x, centre.y, centre.z],
                    fineCellCentreM: setting.refinement > 1
                        ? [gauge.position.x, gauge.position.y, gauge.position.z].map {
                            (floor($0 / (setting.dx / Float(setting.refinement))) + 0.5) * setting.dx
                                / Float(setting.refinement)
                        } : nil,
                    peakPa: peak,
                    positiveImpulsePaS: impulse,
                    arrivalS: samples.first { $0.pressure - scene.atmosphere.pressure >= 1000 }?.time,
                    samples: samples.map { [$0.time, Double($0.pressure - scene.atmosphere.pressure)] }))
        }
        let mapFile = "\(id)-map.json"
        guard let map = solver.exposureSnapshot() else { throw BlastError.allocationFailed("exposure map") }
        try write(map, to: directory.appending(path: mapFile), pretty: false)
        let result = StreetRun(
            id: id, layout: layout, purpose: purpose, cellSizeM: setting.dx, refinement: setting.refinement,
            cfl: setting.cfl, sourceRadiusM: solver.balloonRadius(for: scene.charge),
            sourceMassKg: scene.charge.mass,
            reflectiveFaces: scene.reflectiveFaces.rawValue, durationS: solver.time,
            steps: solver.stepCount, setupWallS: setup, runWallS: wall, commandGPUS: gpu,
            profile: profile ? stages : nil, solverBytes: solver.memoryFootprint,
            coupling: solver.couplingStatistics,
            maximumRefinedPatches: maxPatches, massInitialKg: initial.mass, massFinalKg: final.mass,
            energyInitialJ: initial.energy, energyFinalJ: final.energy, gaugeObservations: gauges,
            bodies: histories, mapFile: mapFile, stable: stable)
        print("\(id): \(solver.stepCount) steps to \(solver.time) s, \(wall) s wall, \(gpu) s GPU")
        return result
    }

    static func write<T: Encodable>(_ value: T, to url: URL, pretty: Bool = true) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
