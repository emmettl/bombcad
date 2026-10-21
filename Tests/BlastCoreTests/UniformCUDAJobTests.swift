import CryptoKit
import Foundation
import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

@Suite("Portable uniform CUDA jobs", .serialized, .gpuThreads)
struct UniformCUDAJobTests {
    func solver() throws -> BlastSolver {
        try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()),
            scenario: Scenario(
                name: "CUDA export", domainSize: SIMD3(8, 8, 4), boxes: [],
                charge: Charge(mass: 1, position: SIMD3(2, 4, 0))),
            cellSize: 0.5, configuration: .recommended)
    }

    @Test("An exported job preserves initial state, species, cooling and receiver records")
    func preservesState() throws {
        let solver = try solver()
        let columns = Array(repeating: SIMD4<Float>(1, 2, 0.25, 1), count: solver.grid.nx * solver.grid.ny)
        try solver.configureFirstPhaseColumns(columns)
        let initial = Data(
            bytes: solver.stateBuffers[solver.current].contents(), count: solver.grid.cellCount * 20)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try solver.exportUniformCUDAJob(
            to: folder, sourceSHA256: String(repeating: "a", count: 64), until: 0.02)
        #expect(try Data(contentsOf: folder.appendingPathComponent("state.bin")) == initial)
        #expect(solver.stepCount == 0)
        let metadata = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("job.json")))
                as? [String: Any])
        #expect(metadata["cooling"] != nil)
        let files = try #require(metadata["files"] as? [String: String])
        #expect(files.count == 8)
        for (name, hash) in files {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == hash)
        }
        #expect(
            try Data(contentsOf: folder.appendingPathComponent("species.bin")).count == solver.grid.cellCount
                * 8)
    }

    @Test("A mapped-start job keeps its nonzero hand-over time and seeded receiver history")
    func mappedStart() throws {
        var configuration = SolverConfiguration.recommended
        configuration.radiativeCooling = nil
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()),
            scenario: Scenario(
                name: "Mapped CUDA", domainSize: SIMD3(24, 24, 12), boxes: [],
                charge: Charge(mass: 1, position: SIMD3(12, 12, 0))),
            cellSize: 0.5, configuration: configuration)
        #expect(solver.time > 0)
        try solver.configureFirstPhaseColumns(
            Array(repeating: SIMD4<Float>(0, 1, 0.5, 1), count: solver.grid.nx * solver.grid.ny))
        let seeded = try #require(solver.firstPhaseSnapshot())
        #expect(seeded.contains { $0.x > 0 && $0.z > 0 })
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try solver.exportUniformCUDAJob(
            to: folder, sourceSHA256: String(repeating: "a", count: 64), until: solver.time + 0.02)
        let meta = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("job.json")))
                as? [String: Any])
        let decodedTime = try #require(meta["startTime"] as? Double)
        // Foundation's JSON number parser may move a Double by one ULP. The wire clock's
        // contract is the GPU tick, while the binary state and receiver history remain exact.
        #expect(abs(decodedTime - solver.time) <= StepControl.tick)
        let bytes = seeded.withUnsafeBytes { Data($0) }
        #expect(try Data(contentsOf: folder.appendingPathComponent("records.bin")) == bytes)
    }

    @Test("Unsupported physics and unconfigured receivers are refused before writing a job")
    func refusesUnsupported() throws {
        let solver = try solver()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: (any Error).self) {
            try solver.exportUniformCUDAJob(
                to: folder, sourceSHA256: String(repeating: "a", count: 64), until: 0.02)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        try solver.configureFirstPhaseColumns(
            Array(repeating: SIMD4<Float>(1, 2, 0, 1), count: solver.grid.nx * solver.grid.ny))
        solver.configuration.periodicSides = true
        #expect(throws: (any Error).self) {
            try solver.exportUniformCUDAJob(
                to: folder, sourceSHA256: String(repeating: "a", count: 64), until: 0.02)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
