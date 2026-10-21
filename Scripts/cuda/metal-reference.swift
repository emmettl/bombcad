// Standalone acceptance runner: same uniform job and generated numerical source as CUDA.
import Foundation
import Metal

func run() throws {
    let args = CommandLine.arguments
    guard args.count == 4, let device = MTLCreateSystemDefaultDevice(),
        let queue = device.makeCommandQueue()
    else { throw NSError(domain: "usage: metal-reference job source.metal output", code: 1) }
    let folder = URL(fileURLWithPath: args[1], isDirectory: true)
    let source = try String(contentsOfFile: args[2], encoding: .utf8)
    let meta =
        try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("job.json")))
        as! [String: Any]
    let dims = meta["shape"] as! [Int]
    let count = dims.reduce(1, *)
    let values = meta["uniforms"] as! [String: NSNumber]
    func layout(_ name: String) throws -> [(String, String)] {
        let pattern = "struct " + name + "\\s*\\{([\\s\\S]*?)\\};"
        let re = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        let m = re.firstMatch(in: source, range: range)!
        let body = String(source[Range(m.range(at: 1), in: source)!])
        let field = try NSRegularExpression(pattern: "(?m)^\\s*(float|uint)\\s+(\\w+)\\s*;")
        return field.matches(in: body, range: NSRange(body.startIndex..., in: body)).map {
            (String(body[Range($0.range(at: 1), in: body)!]), String(body[Range($0.range(at: 2), in: body)!]))
        }
    }
    let fields = try layout("SolverUniforms")
    var uniformWords = fields.map { type, name -> UInt32 in
        let value = values[name] ?? 0
        return type == "float" ? value.floatValue.bitPattern : value.uint32Value
    }
    func set(_ name: String, _ value: UInt32) { uniformWords[fields.firstIndex { $0.1 == name }!] = value }
    set("nx", UInt32(dims[0]))
    set("ny", UInt32(dims[1]))
    set("nz", UInt32(dims[2]))
    func buffer(_ data: Data) throws -> MTLBuffer {
        guard
            let b = data.withUnsafeBytes({ bytes in
                device.makeBuffer(bytes: bytes.baseAddress!, length: data.count, options: .storageModeShared)
            })
        else { throw NSError(domain: "buffer allocation", code: 1) }
        return b
    }
    func read(_ name: String) throws -> MTLBuffer {
        try buffer(Data(contentsOf: folder.appendingPathComponent(name + ".bin")))
    }
    func zeros(_ bytes: Int) throws -> MTLBuffer { try buffer(Data(count: bytes)) }
    func words(_ a: [UInt32]) throws -> MTLBuffer { try buffer(a.withUnsafeBytes { Data($0) }) }
    var state = try read("state")
    var other = try read("state")
    var species = try read("species")
    var otherSpecies = try read("species")
    let mask = try read("mask")
    let peak = try read("peak")
    let impulse = try read("impulse")
    let speed = try zeros(8)
    var controlWords = [UInt32](repeating: 0, count: try layout("StepControl").count)
    controlWords[2] = (meta["duration"] as! NSNumber).floatValue.bitPattern
    let control = try words(controlWords)
    let uniform = try words(uniformWords)
    let axes = meta["axes"] as! [Int]
    let variants = try [axes, Array(axes.reversed())].map { order in
        try order.enumerated().map { n, axis -> MTLBuffer in
            set("axis", UInt32(axis))
            set("finalSweep", n == order.count - 1 ? 1 : 0)
            return try words(uniformWords)
        }
    }
    let columns = try read("columns")
    let records = try read("records")
    let opened = try read("open")
    let cooling = meta["cooling"] as? [String: NSNumber]
    let radiationWords = try layout("RadiationUniforms").map { type, name -> UInt32 in
        let value = cooling?[name] ?? 0
        return type == "float" ? value.floatValue.bitPattern : value.uint32Value
    }
    let radiation = try words(radiationWords)
    let medium = try zeros(count * 8)
    let loss = try zeros(count * 4)
    let box = try words([0, 0, 0, 0, UInt32(dims[0] - 1), UInt32(dims[1] - 1), UInt32(dims[2] - 1), 0])
    let elapsedCooling = try zeros(4)
    let directions: [[Int32]] = [
        [1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 0], [1, -1, 0], [1, 0, 1], [1, 0, -1],
        [0, 1, 1], [0, 1, -1], [1, 1, 1], [1, 1, -1], [1, -1, 1], [1, -1, -1],
    ]
    let rays = try directions.enumerated().map { i, d in
        try words((d + [i == 0 ? 1 : 0]).map { UInt32(bitPattern: $0) })
    }
    let terrain = meta["terrain"] as? [String: Int]
    let dummy = try zeros(16)
    let cutColumns = try terrain == nil ? dummy : read("cut-columns")
    let cutRecords = try terrain == nil ? dummy : read("cut-records")
    let cutWalls = try terrain == nil ? dummy : read("cut-walls")
    let cutDefects = try terrain == nil ? dummy : read("cut-defects")
    let cutList = try terrain == nil ? dummy : read("cut-list")
    let cutCeilings = try terrain == nil ? dummy : read("cut-ceilings")
    let cutCount = try words([UInt32(terrain?["cutColumnCount"] ?? 0)])
    let constants = MTLFunctionConstantValues()
    if terrain != nil {
        var enabled = true
        constants.setConstantValue(&enabled, type: .bool, index: 13)
    }
    let options = MTLCompileOptions()
    options.mathMode = .safe
    let library = try device.makeLibrary(
        source: "#pragma METAL fp contract(off)\n" + source, options: options)
    var pipelines: [String: MTLComputePipelineState] = [:]
    for name in [
        "referenceSweep", "referencePrepare", "referenceMeasure", "referenceFirstPhase",
        "referenceCoolingClock", "referenceCoolingReset", "referenceCoolingMedium", "referenceCoolingLines",
        "referenceCoolingApply", "referenceRedistribute",
    ] {
        pipelines[name] = try device.makeComputePipelineState(
            function: library.makeFunction(name: name, constantValues: constants))
    }
    func launch(_ encoder: MTLComputeCommandEncoder, _ name: String, _ buffers: [MTLBuffer], _ n: Int) {
        let pipeline = pipelines[name]!
        encoder.setComputePipelineState(pipeline)
        for (i, b) in buffers.enumerated() { encoder.setBuffer(b, offset: 0, index: i) }
        encoder.dispatchThreads(
            MTLSize(width: n, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: min(128, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
    }
    func command(_ body: (MTLComputeCommandEncoder) -> Void) throws {
        let command = queue.makeCommandBuffer()!
        let encoder = command.makeComputeCommandEncoder()!
        body(encoder)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
    }
    try command {
        launch(
            $0, "referenceFirstPhase", [state, control, columns, records, opened, uniform], dims[0] * dims[1])
        launch($0, "referenceMeasure", [state, mask, speed, uniform], count)
    }
    var timesteps: [Float] = []
    for _ in 0..<(meta["steps"] as! Int) {
        try command { encoder in
            let ramp = min(
                1,
                Float((meta["startStep"] as? Int ?? 0) + timesteps.count + 1)
                    / Float(meta["startupSteps"] as? Int ?? 1))
            var prepareWords = uniformWords
            prepareWords[fields.firstIndex { $0.1 == "cfl" }!] = (values["cfl"]!.floatValue * ramp).bitPattern
            let prepareUniform = try! words(prepareWords)
            launch(encoder, "referencePrepare", [control, speed, prepareUniform], 1)
            for variant in variants[((meta["startStep"] as? Int ?? 0) + timesteps.count) % 2] {
                launch(
                    encoder, "referenceSweep",
                    [
                        state, other, mask, peak, impulse, control, speed, variant, species, otherSpecies,
                        cutColumns, cutRecords, cutWalls, cutDefects, cutCeilings,
                    ], count
                )
                swap(&state, &other)
                swap(&species, &otherSpecies)
            }
            if let terrain, terrain["cutColumnCount"]! > 0 {
                launch(
                    encoder, "referenceRedistribute",
                    [
                        state, species, cutColumns, cutRecords, uniform,
                        control, peak, speed, cutDefects, cutList, cutCount, mask,
                    ], terrain["cutColumnCount"]!)
            }
            if let cooling {
                launch(encoder, "referenceCoolingClock", [control, elapsedCooling], 1)
                if ((meta["startStep"] as? Int ?? 0) + timesteps.count + 1) % cooling["interval"]!.intValue
                    == 0
                {
                    launch(
                        encoder, "referenceCoolingMedium",
                        [state, mask, species, uniform, radiation, medium], count)
                    for ray in rays {
                        launch(
                            encoder, "referenceCoolingLines", [medium, mask, loss, box, uniform, ray], count)
                    }
                    launch(
                        encoder, "referenceCoolingApply",
                        [state, medium, loss, box, elapsedCooling, uniform, radiation, control], count)
                    launch(encoder, "referenceCoolingReset", [control, elapsedCooling], 1)
                }
            }
            launch(
                encoder, "referenceFirstPhase", [state, control, columns, records, opened, uniform],
                dims[0] * dims[1])
        }
        let c = control.contents().bindMemory(to: UInt32.self, capacity: controlWords.count)
        if c[8] == 3 { throw NSError(domain: "nonphysical wave speed", code: 3) }
        let dt = Float(bitPattern: c[0])
        if dt > 0 { timesteps.append(dt) }
        if c[8] == 2 { break }
        if c[8] == 1 {
            c[8] = 0
            c[3] = 0
            c[1] = 0
            let remaining =
                (meta["duration"] as! NSNumber).doubleValue - timesteps.reduce(0) { $0 + Double($1) }
            c[2] = Float(max(remaining, 0)).bitPattern
        }
    }
    let output = URL(fileURLWithPath: args[3], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    for (name, b) in [
        ("state", state), ("species", species), ("peak", peak), ("impulse", impulse),
        ("first-phase", records),
    ] {
        try Data(bytes: b.contents(), count: b.length).write(to: output.appendingPathComponent(name + ".bin"))
    }
    try timesteps.withUnsafeBytes { try Data($0).write(to: output.appendingPathComponent("dt.bin")) }
    print("Metal reference: \(device.name), \(timesteps.count) steps, \(count) cells")
}
try run()
