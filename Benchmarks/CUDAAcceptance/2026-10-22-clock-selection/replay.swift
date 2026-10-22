import CryptoKit
import Foundation
import Metal

func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func run() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let stage = CommandLine.arguments[2]
    guard ["own", "cross"].contains(stage), let device = MTLCreateSystemDefaultDevice(),
        let queue = device.makeCommandQueue()
    else { throw NSError(domain: "stage and Metal device", code: 1) }
    let manifest = try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("preparation.json"))) as! [String: Any]
    if stage == "cross" {
        for backend in ["metal", "cuda"] {
            let receipt = try JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent("\(backend)-own/receipt.json"))) as! [String: Any]
            guard receipt["allFirstDTGatesPass"] as! Bool else {
                throw NSError(domain: "native first-dt gate failed", code: 1)
            }
        }
    }
    for (path, expected) in manifest["pins"] as! [String: String] {
        guard try sha(Data(contentsOf: URL(fileURLWithPath: path))) == expected else {
            throw NSError(domain: "input pin: \(path)", code: 1)
        }
    }
    let output = root.appendingPathComponent("metal-\(stage)", isDirectory: true)
    guard !FileManager.default.fileExists(atPath: output.path) else {
        throw NSError(domain: "fresh output required", code: 1)
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    let source = try Data(contentsOf: root.appendingPathComponent("analysis/producer-library.metal"))
    let library = try device.makeLibrary(source: String(decoding: source, as: UTF8.self), options: nil)
    func pipeline(_ name: String) throws -> MTLComputePipelineState {
        let function = try library.makeFunction(name: name, constantValues: MTLFunctionConstantValues())
        return try device.makeComputePipelineState(function: function)
    }
    let measure = try pipeline("measureWaveSpeed")
    let prepare = try pipeline("prepareStep")
    func buffer(_ data: Data) -> MTLBuffer {
        data.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: data.count, options: .storageModeShared)! }
    }
    func command(_ encode: (MTLComputeCommandEncoder) throws -> Void) throws {
        let cb = queue.makeCommandBuffer()!
        let encoder = cb.makeComputeCommandEncoder()!
        try encode(encoder)
        encoder.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
    }
    var rows: [[String: Any]] = []
    for item in manifest["rows"] as! [[String: Any]] {
        let name = item["id"] as! String
        let folder = root.appendingPathComponent("cases/\(name)")
        let input = URL(fileURLWithPath: item["localInput"] as! String)
        let dest = output.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        let physical = item["physicalFiles"] as! [String: String]
        let stateData = try Data(contentsOf: input.appendingPathComponent("state.bin"))
        let maskData = try Data(contentsOf: input.appendingPathComponent("mask.bin"))
        guard sha(stateData) == physical["state.bin"], sha(maskData) == physical["mask.bin"] else {
            throw NSError(domain: "physical input hash", code: 1)
        }
        let state = buffer(stateData), mask = buffer(maskData)
        let speed = buffer(Data(repeating: 0, count: 8))
        let measureUniforms = buffer(try Data(contentsOf: folder.appendingPathComponent("measure-metal.bin")))
        if stage == "own" {
            let shape = item["shape"] as! [Int]
            try command { encoder in
                encoder.setComputePipelineState(measure)
                for (i, b) in [state, mask, speed, measureUniforms].enumerated() {
                    encoder.setBuffer(b, offset: 0, index: i)
                }
                encoder.dispatchThreads(
                    MTLSize(width: shape[0], height: shape[1], depth: shape[2]),
                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4))
            }
            try Data(bytes: speed.contents(), count: 8).write(
                to: dest.appendingPathComponent("measured-speed.bin"), options: .withoutOverwriting)
        }
        let origins = stage == "own" ? ["metal"] : ["metal", "cuda"]
        for origin in origins {
            let speedData = stage == "own" ? Data(bytes: speed.contents(), count: 8)
                : try Data(contentsOf: root.appendingPathComponent("\(origin)-own/\(name)/measured-speed.bin"))
            speedData.withUnsafeBytes { speed.contents().copyMemory(from: $0.baseAddress!, byteCount: 8) }
            let control = buffer(try Data(contentsOf: folder.appendingPathComponent("control-metal.bin")))
            let uniforms = buffer(try Data(contentsOf: folder.appendingPathComponent("prepare-metal.bin")))
            let dummy = buffer(Data(repeating: 0, count: 4096))
            try command { encoder in
                encoder.setComputePipelineState(prepare)
                for i in 0..<18 { encoder.setBuffer(dummy, offset: 0, index: i) }
                for (i, b) in [(0, control), (1, speed), (2, state), (5, uniforms), (16, mask)] {
                    encoder.setBuffer(b, offset: 0, index: i)
                }
                encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            }
            let controls = Data(bytes: control.contents(), count: control.length)
            try controls.write(to: dest.appendingPathComponent("selected-\(origin).bin"), options: .withoutOverwriting)
            let dt = control.contents().load(as: UInt32.self)
            let expected = (item["expectedFirstDT"] as! [String: NSNumber])["metal"]!.uint32Value
            rows.append(["id": name, "speedOrigin": origin, "dtWord": dt,
                "expectedNativeWord": expected, "nativeFirstDTGate": stage == "own" ? dt == expected : true,
                "speedWords": speedData.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) },
                "controlSHA256": sha(controls)])
        }
    }
    let report: [String: Any] = ["status": "complete-all-outcomes", "stage": stage, "rows": rows,
        "allFirstDTGatesPass": rows.allSatisfy { $0["nativeFirstDTGate"] as! Bool },
        "sourceSHA256": sha(source), "device": device.name,
        "binarySHA256": try sha(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
        "compileOptions": "nil; original full archived producer; empty function constants",
        "scope": "Native initial measurement/selection; unused tiles/gauges disabled; no PDE evolution"]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("receipt.json"), options: .withoutOverwriting)
}

do { try run() } catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
