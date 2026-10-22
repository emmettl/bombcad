import CryptoKit
import Foundation
import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

/// Explicit experiment inputs only; ordinary CI does not read external experiment data.
@Suite(
    "Step selector actual scalar banks", .serialized, .gpuThreads,
    .enabled(if: ProcessInfo.processInfo.environment["BOMBCAD_SELECTOR_BANKS"] != nil))
struct StepSelectorBankReplayTests {
    @Test("Actual solver pipelines reproduce every archived nil and safe/precise output word")
    func actualBanks() throws {
        let root = URL(filePath: try #require(ProcessInfo.processInfo.environment["BOMBCAD_SELECTOR_BANKS"]))
        let manifest =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appending(path: "bank-preparation.json"))) as! [String: Any]
        func sha(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        for (path, hash) in manifest["pins"] as! [String: String] {
            try #require(sha(Data(contentsOf: URL(filePath: path))) == hash)
        }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let solver = try BlastSolver(device: device, grid: Grid(nx: 4, ny: 4, nz: 4, cellSize: 1))
        try solver.configureStepSelectorDiagnostics()
        let diagnostic = try #require(solver.stepSelectorDiagnostic)
        try #require(diagnostic.info.sourceSHA256 == manifest["sourceSHA256"] as! String)
        let queue = solver.commandQueue
        var report: [[String: Any]] = []
        for (mode, pipeline) in [("baseline", solver.preparePipeline), ("precise", diagnostic.pipeline)] {
            for row in manifest["rows"] as! [[String: Any]] {
                let label = row["label"] as! String
                let n = row["frames"] as! Int
                let folder = root.appending(path: row["folder"] as! String)
                func read(_ name: String) throws -> Data {
                    try Data(contentsOf: folder.appending(path: name + ".bin"))
                }
                func buffer(_ data: Data) throws -> MTLBuffer {
                    try #require(
                        data.withUnsafeBytes {
                            device.makeBuffer(
                                bytes: $0.baseAddress!, length: data.count, options: .storageModeShared)
                        })
                }
                let control = try buffer(read("control"))
                let speed = try buffer(read("speed"))
                let tiles = try buffer(read("tiles"))
                let uniforms = try read("uniforms")
                let dummy = try buffer(Data(repeating: 0, count: 4096))
                try #require(
                    control.length == n * 72 && speed.length == n * 8 && tiles.length == n * 16
                        && uniforms.count == n * 276)
                for first in stride(from: 0, to: n, by: 256) {
                    let command = try #require(queue.makeCommandBuffer())
                    let encoder = try #require(command.makeComputeCommandEncoder())
                    encoder.setComputePipelineState(pipeline)
                    for index in 0..<18 { encoder.setBuffer(dummy, offset: 0, index: index) }
                    for i in first..<min(first + 256, n) {
                        encoder.setBuffer(control, offset: i * 72, index: 0)
                        encoder.setBuffer(speed, offset: i * 8, index: 1)
                        uniforms.withUnsafeBytes {
                            encoder.setBytes($0.baseAddress! + i * 276, length: 276, index: 5)
                        }
                        encoder.setBuffer(tiles, offset: i * 16, index: 6)
                        encoder.setBuffer(tiles, offset: i * 16 + 4, index: 7)
                        encoder.dispatchThreads(
                            MTLSize(width: 1, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
                    }
                    encoder.endEncoding()
                    command.commit()
                    command.waitUntilCompleted()
                    try #require(command.error == nil)
                }
                let c = control.contents().bindMemory(to: UInt32.self, capacity: n * 18)
                let s = speed.contents().bindMemory(to: UInt32.self, capacity: n * 2)
                let t = tiles.contents().bindMemory(to: UInt32.self, capacity: n * 4)
                var actual: [UInt32] = []
                for i in 0..<n {
                    actual.append(contentsOf: UnsafeBufferPointer(start: c + i * 18, count: 18))
                    actual.append(contentsOf: UnsafeBufferPointer(start: s + i * 2, count: 2))
                    actual.append(contentsOf: UnsafeBufferPointer(start: t + i * 4, count: 4))
                }
                let expected = try read("expected-" + mode)
                let data = actual.withUnsafeBytes { Data($0) }
                try data.write(
                    to: root.appending(path: mode + "-" + label + ".bin"), options: .withoutOverwriting)
                report.append([
                    "mode": mode, "label": label, "words": actual.count, "allWordsExact": data == expected,
                    "sha256": sha(data),
                ])
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appending(path: "bank-results.json"))
                try #require(data == expected, "Preserved bank failure is a stop; no numerical retry")
            }
        }
    }
}
