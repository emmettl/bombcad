import BlastCore
import Foundation
import Metal
import simd

/// `scenebench field-export <district-scene's inputs> [--radius 1024] [--dx 4] [--height m]
/// [--until s] [--above 2] [--edge 4] [--ground saturated] [--balloon] [--id name] [--layout name]
/// --out folder`: one training pair for the learned field model (docs/learned-models.md). The
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
        let solver = try BlastSolver(
            device: device, scenario: scene, cellSize: dx, configuration: configuration)
        print(
            String(
                format: "%d × %d × %d cells (%.1f M), %.0f m top, %.0f kg, to %.2f s", solver.grid.nx,
                solver.grid.ny, solver.grid.nz, Double(solver.grid.cellCount) / 1e6, scene.domainSize.z, mass,
                until))
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
        print(String(format: "Ran to %.3f s in %d steps, %.0f s", solver.time, steps, wall))
        let folder = URL(filePath: out)
        try write(
            solver: solver, scene: scene, folder: folder, id: value("id") ?? folder.lastPathComponent,
            layout: value("layout"), buildings: report.placed.count,
            above: Float(value("above").flatMap(Double.init) ?? 2),
            edgeCells: value("edge").flatMap(Int.init) ?? 4,
            configuration: args.contains("--balloon") ? "recommended, balloon start" : "recommended",
            ground: value("ground"), steps: steps, wallS: wall, stable: stable, arguments: args)
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

    /// Writes the training pair for `solver`'s run of `scene` into `folder`.
    static func write(
        solver: BlastSolver, scene: Scenario, folder: URL, id: String, layout: String?, buildings: Int,
        above: Float, edgeCells: Int, configuration: String, ground: String?, steps: Int, wallS: Double,
        stable: Bool, arguments: [String]?
    ) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let grid = solver.grid
        let dx = grid.cellSize
        let (nx, ny, nz) = (grid.nx, grid.ny, grid.nz)
        let plan = nx * ny
        let charge = scene.charge.position
        let chargeGround = scene.terrain?.height(at: SIMD2(charge.x, charge.y)) ?? 0
        let mass = Double(scene.charge.mass)
        let root = cbrt(mass)
        func groundAt(_ i: Int, _ j: Int) -> Float {
            scene.terrain?.height(at: SIMD2((Float(i) + 0.5) * dx, (Float(j) + 0.5) * dx)) ?? 0
        }
        var groundMap = [Float](repeating: 0, count: plan)
        for j in 0..<ny {
            for i in 0..<nx { groundMap[i + nx * j] = groundAt(i, j) }
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
        var inputs = [Float](repeating: 0, count: inputChannels.count * plan)
        var targets = [Float](repeating: 0, count: targetChannels.count * plan)
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
                let s = (g + above) / dx - 0.5
                let k0 = max(0, min(nz - 1, Int(s.rounded(.down))))
                let k1 = min(nz - 1, k0 + 1)
                let t = max(0, min(1, s - Float(k0)))
                let open0 = !solver.isSolid(i, j, k0)
                let open1 = !solver.isSolid(i, j, k1)
                var peak: Float
                var impulse: Float
                if open0 && open1 {
                    peak = (1 - t) * solver.peakOverpressure(i, j, k0) + t * solver.peakOverpressure(i, j, k1)
                    impulse = (1 - t) * solver.impulse(i, j, k0) + t * solver.impulse(i, j, k1)
                } else if open0 || open1 {
                    let k = open0 ? k0 : k1
                    peak = solver.peakOverpressure(i, j, k)
                    impulse = solver.impulse(i, j, k)
                } else {
                    continue
                }
                guard peak.isFinite, impulse.isFinite else { continue }
                targets[0 * plan + n] = peak
                targets[1 * plan + n] = impulse
                mask[n] = 1
            }
        }
        try NPY.write(inputs, shape: [inputChannels.count, ny, nx], to: folder.appending(path: "inputs.npy"))
        try NPY.write(
            targets, shape: [targetChannels.count, ny, nx], to: folder.appending(path: "targets.npy"))
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
            targets: targetChannels.map { Meta.Channel(name: $0.name, units: $0.units) },
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
