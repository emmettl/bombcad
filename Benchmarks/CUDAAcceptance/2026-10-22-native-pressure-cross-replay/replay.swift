import CryptoKit
import Foundation
import Metal

enum BlastError: Error { case missingShader(String) }
enum ShaderLibrary {
    // INSERT_FROZEN_PRESSURE_TRANSFORM
}

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func run() throws {
    guard CommandLine.arguments.count == 3 else {
        throw NSError(domain: "replay manifest.json receipt.json", code: 1)
    }
    let manifestData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let manifest = try JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
    let receiptURL = URL(fileURLWithPath: CommandLine.arguments[2])
    guard !FileManager.default.fileExists(atPath: receiptURL.path),
        let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
    else { throw NSError(domain: "fresh receipt, Metal device and queue required", code: 1) }
    let prefix = try String(contentsOfFile: manifest["prefix"] as! String, encoding: .utf8)
    let fragments = try (manifest["fragments"] as! [String]).map {
        try String(contentsOfFile: $0, encoding: .utf8)
    }
    let source = try ShaderLibrary.addingFirstPhasePressureCapture(
        to: prefix + "\n" + fragments.joined(separator: "\n"))
    let sourceData = Data(source.utf8)
    let sourceURL = URL(fileURLWithPath: manifest["compiledSource"] as! String)
    if FileManager.default.fileExists(atPath: sourceURL.path) {
        guard try Data(contentsOf: sourceURL) == sourceData else {
            throw NSError(domain: "producer source changed", code: 1)
        }
    } else { try sourceData.write(to: sourceURL, options: .withoutOverwriting) }
    let library = try device.makeLibrary(source: source, options: nil)
    let function = try library.makeFunction(
        name: "sampleFirstPhasePressure", constantValues: MTLFunctionConstantValues())
    let pipeline = try device.makeComputePipelineState(function: function)
    var rows: [[String: Any]] = []
    for item in manifest["cases"] as! [[String: Any]] {
        var row: [String: Any] = ["label": item["label"]!, "status": "failed"]
        do {
            let folder = URL(fileURLWithPath: item["folder"] as! String, isDirectory: true)
            let output = folder.appendingPathComponent("metal-pressure.bin")
            let frames = item["frames"] as! Int
            let columns = item["columns"] as! [Int]
            let shape = item["shape"] as! [Int]
            let nx = shape[0], ny = shape[1], nz = shape[2], plane = nx * ny
            let qCount = columns.count
            let inputs = try Data(contentsOf: folder.appendingPathComponent("inputs.bin"))
            let recordsBefore = try Data(contentsOf: folder.appendingPathComponent("records-before.bin"))
            let controls = try Data(contentsOf: folder.appendingPathComponent("controls.bin"))
            let uniforms = try Data(contentsOf: folder.appendingPathComponent("uniforms-metal.bin"))
            let controlBytes = item["controlBytes"] as! Int
            guard frames > 0, qCount > 0, qCount <= 64,
                inputs.count == frames * qCount * 64,
                recordsBefore.count == frames * qCount * 20,
                controls.count == frames * controlBytes,
                !FileManager.default.fileExists(atPath: output.path),
                let state = device.makeBuffer(length: plane * nz * 20, options: .storageModeShared),
                let control = device.makeBuffer(length: controlBytes, options: .storageModeShared),
                let descriptors = device.makeBuffer(length: plane * 16, options: .storageModeShared),
                let records = device.makeBuffer(length: plane * 16, options: .storageModeShared),
                let opened = device.makeBuffer(length: plane * 4, options: .storageModeShared),
                let slots = device.makeBuffer(length: plane * 4, options: .storageModeShared),
                let trace = device.makeBuffer(length: qCount * 64, options: .storageModeShared)
            else { throw NSError(domain: "valid replay buffers and fresh output", code: 1) }
            for buffer in [state, descriptors, records, opened, slots, trace] {
                memset(buffer.contents(), 0, buffer.length)
            }
            var cellIndices: [[Int]] = []
            for (q, n) in columns.enumerated() {
                guard n >= 0 && n < plane else { throw NSError(domain: "column bound", code: 1) }
                inputs.withUnsafeBytes { data in
                    descriptors.contents().advanced(by: n * 16).copyMemory(
                        from: data.baseAddress!.advanced(by: q * 64), byteCount: 16)
                }
                let descriptor = descriptors.contents().advanced(by: n * 16).load(as: SIMD4<Float>.self)
                guard descriptor.w > 0, descriptor.x >= 0, descriptor.y >= 0,
                    descriptor.x < Float(nz), descriptor.y < Float(nz),
                    descriptor.z >= 0, descriptor.z <= 1
                else { throw NSError(domain: "enabled descriptor bound", code: 1) }
                cellIndices.append([n + plane * Int(descriptor.x), n + plane * Int(descriptor.y)])
                slots.contents().advanced(by: n * 4).storeBytes(of: UInt32(q + 1), as: UInt32.self)
            }
            var result = [UInt32](repeating: 0, count: frames * qCount)
            for frame in 0..<frames {
                controls.withUnsafeBytes { data in
                    control.contents().copyMemory(
                        from: data.baseAddress!.advanced(by: frame * controlBytes), byteCount: controlBytes)
                }
                for (q, n) in columns.enumerated() {
                    inputs.withUnsafeBytes { data in
                        for side in 0..<2 {
                            state.contents().advanced(by: cellIndices[q][side] * 20).copyMemory(
                                from: data.baseAddress!.advanced(by: (frame * qCount + q) * 64 + 24 + side * 20),
                                byteCount: 20)
                        }
                    }
                    recordsBefore.withUnsafeBytes { data in
                        let source = data.baseAddress!.advanced(by: (frame * qCount + q) * 20)
                        records.contents().advanced(by: n * 16).copyMemory(from: source, byteCount: 16)
                        opened.contents().advanced(by: n * 4).copyMemory(
                            from: source.advanced(by: 16), byteCount: 4)
                    }
                }
                guard let command = queue.makeCommandBuffer(),
                    let encoder = command.makeComputeCommandEncoder()
                else { throw NSError(domain: "command allocation", code: 1) }
                var parameters = SIMD4<UInt32>(UInt32(nx), UInt32(ny), frame == 0 ? 1 : 0, 0)
                encoder.setComputePipelineState(pipeline)
                for (i, buffer) in [state, control, descriptors, records, opened].enumerated() {
                    encoder.setBuffer(buffer, offset: 0, index: i)
                }
                uniforms.withUnsafeBytes { data in
                    encoder.setBytes(data.baseAddress!, length: uniforms.count, index: 5)
                }
                encoder.setBytes(&parameters, length: 16, index: 6)
                encoder.setBuffer(slots, offset: 0, index: 7)
                encoder.setBuffer(trace, offset: 0, index: 8)
                encoder.dispatchThreads(
                    MTLSize(width: nx, height: ny, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                encoder.endEncoding()
                command.commit()
                command.waitUntilCompleted()
                if let error = command.error { throw error }
                let words = trace.contents().bindMemory(to: UInt32.self, capacity: qCount * 16)
                for q in 0..<qCount { result[frame * qCount + q] = words[q * 16 + (frame == 0 ? 0 : 8)] }
            }
            let data = result.withUnsafeBytes { Data($0) }
            try data.write(to: output, options: .withoutOverwriting)
            row.merge([
                "status": "complete", "frames": frames, "columns": columns,
                "inputSHA256": digest(inputs), "controlSHA256": digest(controls),
                "uniformSHA256": digest(uniforms), "outputSHA256": digest(data),
            ]) { _, new in new }
        } catch { row["error"] = String(describing: error) }
        rows.append(row)
    }
    let report: [String: Any] = [
        "status": "complete-all-outcomes", "rows": rows, "sourceSHA256": digest(sourceData),
        "binarySHA256": digest(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
        "manifestSHA256": digest(manifestData), "device": device.name,
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "compileOptions": "nil; original sampleFirstPhasePressure; empty function constants",
        "scope": "Sparse original-geometry replay; own-input pressure-word parity required; no PDE evolution",
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: receiptURL, options: .withoutOverwriting)
}

do { try run() } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
