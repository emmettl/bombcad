import CryptoKit
import Foundation
import Metal

func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func run() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let stage = CommandLine.arguments[2]
    guard ["baseline", "safe-precise"].contains(stage), let device = MTLCreateSystemDefaultDevice(),
        let queue = device.makeCommandQueue()
    else { throw NSError(domain: "native replay device/stage", code: 1) }
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("preparation.json"))) as! [String: Any]
    for (path, h) in manifest["pins"] as! [String: String] {
        guard try sha(Data(contentsOf: URL(fileURLWithPath: path))) == h else {
            throw NSError(domain: "frozen input changed: \(path)", code: 1)
        }
    }
    if stage == "safe-precise" {
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("metal-baseline/receipt.json"))) as! [String: Any]
        guard receipt["allBaselineWordsExact"] as! Bool else { throw NSError(domain: "complete baseline gate required", code: 1) }
    }
    let output = root.appendingPathComponent("metal-\(stage)")
    guard !FileManager.default.fileExists(atPath: output.path) else { throw NSError(domain: "fresh stage required", code: 1) }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    let source = try Data(contentsOf: root.appendingPathComponent("analysis/producer-main.metal"))
    let options = MTLCompileOptions()
    let defaults: [String: Any] = ["mathMode": options.mathMode.rawValue,
        "mathFloatingPointFunctions": options.mathFloatingPointFunctions.rawValue,
        "languageVersion": options.languageVersion.rawValue]
    if stage == "safe-precise" {
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
    }
    let effective: [String: Any] = ["mathMode": options.mathMode.rawValue,
        "mathFloatingPointFunctions": options.mathFloatingPointFunctions.rawValue,
        "languageVersion": options.languageVersion.rawValue]
    let library = try device.makeLibrary(source: String(decoding: source, as: UTF8.self), options: stage == "baseline" ? nil : options)
    let function = try library.makeFunction(name: "prepareStep", constantValues: MTLFunctionConstantValues())
    let pipeline = try device.makeComputePipelineState(function: function)
    func buffer(_ data: Data) -> MTLBuffer {
        data.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: data.count, options: .storageModeShared)! }
    }
    var rows: [[String: Any]] = []
    for item in manifest["rows"] as! [[String: Any]] {
        let label = item["label"] as! String
        let folder = root.appendingPathComponent(item["folder"] as! String)
        let frames = item["frames"] as! Int
        let cb = item["controlBytes"] as! Int, ub = item["uniformBytes"] as! Int
        guard cb == 72, ub == 276 else { throw NSError(domain: "captured scalar layout", code: 1) }
        func read(_ name: String) throws -> Data { try Data(contentsOf: folder.appendingPathComponent(name + ".bin")) }
        let control = buffer(try read("control")), speed = buffer(try read("speed")), tiles = buffer(try read("tiles"))
        let uniforms = try read("uniforms")
        let dummy = buffer(Data(repeating: 0, count: 4096))
        guard control.length == frames * cb, speed.length == frames * 8,
            tiles.length == frames * 16, uniforms.count == frames * ub
        else { throw NSError(domain: "complete native buffers", code: 1) }
        for first in stride(from: 0, to: frames, by: 256) {
            let command = queue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline)
            for n in 0..<18 { encoder.setBuffer(dummy, offset: 0, index: n) }
            for i in first..<min(first + 256, frames) {
                encoder.setBuffer(control, offset: i * cb, index: 0)
                encoder.setBuffer(speed, offset: i * 8, index: 1)
                uniforms.withUnsafeBytes { encoder.setBytes($0.baseAddress! + i * ub, length: ub, index: 5) }
                encoder.setBuffer(tiles, offset: i * 16, index: 6)
                encoder.setBuffer(tiles, offset: i * 16 + 4, index: 7)
                encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            }
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
        }
        let c = control.contents().bindMemory(to: UInt32.self, capacity: frames * 18)
        let s = speed.contents().bindMemory(to: UInt32.self, capacity: frames * 2)
        let t = tiles.contents().bindMemory(to: UInt32.self, capacity: frames * 4)
        var actual: [UInt32] = []; actual.reserveCapacity(frames * 24)
        for i in 0..<frames {
            actual.append(contentsOf: UnsafeBufferPointer(start: c + i * 18, count: 18))
            actual.append(contentsOf: UnsafeBufferPointer(start: s + i * 2, count: 2))
            actual.append(contentsOf: UnsafeBufferPointer(start: t + i * 4, count: 4))
        }
        let dest = output.appendingPathComponent(label)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        let data = actual.withUnsafeBytes { Data($0) }
        try data.write(to: dest.appendingPathComponent("outputs.bin"), options: .withoutOverwriting)
        var row: [String: Any] = ["label": label, "frames": frames, "outputWords": actual.count, "outputSHA256": sha(data)]
        let expectedData = try read("expected-metal")
        let expected = expectedData.withUnsafeBytes { raw in
            (0..<actual.count).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) }
        }
        guard expectedData.count == data.count else { throw NSError(domain: "complete baseline expected bytes", code: 1) }
        let differences = actual.indices.filter { actual[$0] != expected[$0] }
        row["baselineWordDifferences"] = differences.count
        row["firstBaselineDifferences"] = differences.prefix(16).map { ["index": $0, "actual": Int(actual[$0]), "expected": Int(expected[$0])] }
        rows.append(row)
    }
    let report: [String: Any] = ["status": "complete-all-outcomes", "stage": stage, "rows": rows,
        "allBaselineWordsExact": stage == "baseline" && rows.count == 6 && rows.allSatisfy { $0["baselineWordDifferences"] as! Int == 0 },
        "nilOptions": stage == "baseline", "defaultOptionsReadback": defaults, "effectiveOptionsReadback": effective,
        "sourceSHA256": sha(source), "device": device.name,
        "binarySHA256": try sha(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
        "context": "original untransformed full main producer; empty constants; SDK15; conditional scalar replay only"]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("receipt.json"), options: .withoutOverwriting)
}

do { try run() } catch { fputs("\(error)\n", stderr); exit(1) }
