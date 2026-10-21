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

    @Test("Terrain jobs preserve the production cut geometry and checksums")
    func terrainGeometry() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var scenario = Scenario(
            name: "CUDA terrain", domainSize: SIMD3(8, 8, 4), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(2, 4, 0)))
        scenario.replaceTerrain(with: .slope(domain: scenario.domainSize, spacing: 0.5, foot: 1, angle: 15))
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.5, configuration: .recommended)
        try solver.configureFirstPhaseColumns(
            Array(repeating: SIMD4<Float>(2, 3, 0.5, 1), count: solver.grid.nx * solver.grid.ny))
        let cut = try #require(solver.terrainCut)
        #expect(!cut.geometry.records.isEmpty)
        #expect(!cut.geometry.cutColumns.isEmpty)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try solver.exportUniformCUDAJob(
            to: folder, sourceSHA256: String(repeating: "a", count: 64), until: 0.02)
        let meta = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("job.json")))
                as? [String: Any])
        let terrain = try #require(meta["terrain"] as? [String: Int])
        #expect(terrain["records"] == cut.geometry.records.count)
        #expect(terrain["cutColumnCount"] == cut.geometry.cutColumns.count)
        let expected = cut.geometry.records.withUnsafeBytes { Data($0) }
        #expect(try Data(contentsOf: folder.appendingPathComponent("cut-records.bin")) == expected)
        let files = try #require(meta["files"] as? [String: String])
        #expect(files.count == 14)
        for (name, hash) in files {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == hash)
        }
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
