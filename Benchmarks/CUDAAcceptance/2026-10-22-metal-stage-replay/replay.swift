import CryptoKit
import Foundation
import Metal

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func run() throws {
    guard CommandLine.arguments.count == 3 else {
        throw NSError(domain: "usage: replay manifest.json receipt.json", code: 1)
    }
    let manifestData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let manifest = try JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
    let receiptURL = URL(fileURLWithPath: CommandLine.arguments[2])
    guard !FileManager.default.fileExists(atPath: receiptURL.path),
        let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
    else { throw NSError(domain: "fresh receipt and Metal device required", code: 1) }
    let sourceData = try Data(contentsOf: URL(fileURLWithPath: manifest["source"] as! String))
    let source = String(decoding: sourceData, as: UTF8.self)
    let constants = MTLFunctionConstantValues()
    var idealGas: UInt32 = 0
    constants.setConstantValue(&idealGas, type: .uint, index: 2)
    var pipelines: [String: MTLComputePipelineState] = [:]
    var sourceHashes: [String: String] = [:]
    for policy in ["default", "unfused"] {
        let text = (policy == "unfused" ? "#pragma METAL fp contract(off)\n" : "") + source
        let library = try device.makeLibrary(source: text, options: nil)
        let function = try library.makeFunction(name: "replayStencil", constantValues: constants)
        pipelines[policy] = try device.makeComputePipelineState(function: function)
        sourceHashes[policy] = digest(Data(text.utf8))
    }
    var rows: [[String: Any]] = []
    for item in manifest["cases"] as! [[String: Any]] {
        var row: [String: Any] = ["label": item["label"]!, "status": "failed"]
        do {
            let folder = URL(fileURLWithPath: item["folder"] as! String, isDirectory: true)
            let inputFolder = URL(fileURLWithPath: item["inputFolder"] as! String, isDirectory: true)
            let output = folder.appendingPathComponent("replayed.bin")
            let count = item["count"] as! Int
            guard count > 0, count <= Int(UInt32.max),
                !FileManager.default.fileExists(atPath: output.path),
                let pipeline = pipelines[item["policy"] as! String]
            else { throw NSError(domain: "invalid replay case or existing output", code: 1) }
            var buffers: [MTLBuffer] = []
            var inputs: [String: String] = [:]
            for (name, bytes) in [
                ("state.bin", count * 5 * 20), ("signs.bin", count * 5 * 4),
                ("lambda.bin", count * 4), ("uniforms.bin", item["uniformBytes"] as! Int),
            ] {
                let data = try Data(contentsOf: inputFolder.appendingPathComponent(name))
                guard data.count == bytes,
                    let buffer = data.withUnsafeBytes({ ptr in
                        device.makeBuffer(bytes: ptr.baseAddress!, length: bytes, options: .storageModeShared)
                    })
                else { throw NSError(domain: "input size or allocation", code: 1) }
                buffers.append(buffer)
                inputs[name] = digest(data)
            }
            guard let out = device.makeBuffer(length: count * 91 * 4, options: .storageModeShared),
                let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder()
            else { throw NSError(domain: "command allocation", code: 1) }
            encoder.setComputePipelineState(pipeline)
            for (i, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: i) }
            encoder.setBuffer(out, offset: 0, index: 4)
            var n = UInt32(count)
            encoder.setBytes(&n, length: 4, index: 5)
            encoder.dispatchThreads(
                MTLSize(width: count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: min(128, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            if let error = command.error { throw error }
            let data = Data(bytes: out.contents(), count: count * 91 * 4)
            try data.write(to: output, options: .withoutOverwriting)
            row.merge(["status": "complete", "inputSHA256": inputs, "outputSHA256": digest(data), "count": count]) { _, new in new }
        } catch { row["error"] = String(describing: error) }
        rows.append(row)
    }
    let binary = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))
    let report: [String: Any] = [
        "status": "complete-all-outcomes", "recordWords": 91, "rows": rows, "sourceSHA256": sourceHashes,
        "manifestSHA256": digest(manifestData), "binarySHA256": digest(binary),
        "device": device.name, "registryID": String(device.registryID),
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "compileOptions": "nil; unfused prefix contract(off); function constant2 UInt32=0",
        "scope": "Separate stencil recomputation, not production intermediate observation or instruction attestation",
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: receiptURL, options: .withoutOverwriting)
}

do { try run() } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
