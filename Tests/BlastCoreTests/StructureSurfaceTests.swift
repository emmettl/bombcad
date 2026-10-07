import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

@Suite("Structure surface and USD export")
struct StructureSurfaceTests {
    let device: MTLDevice

    private static let concrete = StructureMaterial.concrete(name: "Concrete", compressiveStrength: 30e6)

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    private func solver(_ structure: StructureModel) throws -> BlastSolver {
        let scenario = Scenario(
            name: "Surface", domainSize: SIMD3(4, 4, 4),
            boxes: [Box(min: SIMD3(3, 3, 0), max: SIMD3(3.5, 3.5, 1))],
            charge: Charge(mass: 0, position: SIMD3(0.5, 0.5, 0.5)), structure: structure)
        return try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
    }

    /// Volume enclosed by outward faces, by the divergence theorem; negative if they face inward.
    private func volume(_ surface: StructureSurface) -> Float {
        stride(from: 0, to: surface.quads.count, by: 4).reduce(Float(0)) { total, start in
            let p = surface.quads[start..<start + 4].map { surface.points[Int($0)] }
            return total + (dot(p[0], cross(p[1], p[2])) + dot(p[0], cross(p[2], p[3]))) / 6
        }
    }

    /// Every edge of a closed surface belongs to exactly two faces, once each way round.
    private func isClosed(_ surface: StructureSurface) -> Bool {
        var edges: [SIMD2<Int32>: Int] = [:]
        for start in stride(from: 0, to: surface.quads.count, by: 4) {
            for n in 0..<4 {
                edges[SIMD2(surface.quads[start + n], surface.quads[start + (n + 1) % 4]), default: 0] += 1
            }
        }
        return edges.allSatisfy { edge, count in count == 1 && edges[SIMD2(edge.y, edge.x)] == 1 }
    }

    @Test("A solid block's surface is its outer faces, closed, outward and enclosing its volume")
    func solidBlock() throws {
        let solver = try solver(
            StructureModel(
                solids: [Box(min: SIMD3(1, 1, 1), max: SIMD3(2, 1.5, 1.5))], material: Self.concrete,
                elementSize: 0.125,
                fixedBase: false))
        let structure = try #require(solver.structure)
        let surface = try #require(solver.structureSurface())
        let faces = 2 * (8 * 4 + 8 * 4 + 4 * 4)
        let points = 9 * 5 * 5 - 7 * 3 * 3
        #expect(surface.faceCount == faces)
        #expect(surface.points.count == points)
        #expect(abs(volume(surface) - 0.25) < 1e-4)
        #expect(isClosed(surface))
        #expect(surface.damage.count == surface.faceCount && surface.material.allSatisfy { $0 == 0 })
        #expect(surface.materials.map(\.name) == [Self.concrete.name])

        // A failed corner element leaves its neighbours' faces showing, and becomes rubble.
        let h = structure.model.elementSize
        let corner = structure.elementIndex(0, 0, 0)
        structure.flagBuffer.contents().storeBytes(
            of: ElementFlag.eroded.rawValue, toByteOffset: corner, as: UInt8.self)
        let broken = try #require(solver.structureSurface())
        #expect(broken.faceCount == surface.faceCount + 6)
        let rubble = 0.6 * h
        #expect(abs(volume(broken) - (0.25 - h * h * h + rubble * rubble * rubble)) < 1e-4)
        #expect(broken.damage.filter { $0 == 1 }.count == 6)
        #expect(broken.rubble.filter { $0 }.count == 6 && !surface.rubble.contains(true))
    }

    @Test("Shells become closed boxes their thickness through")
    func shellWall() throws {
        var model = StructureModel(
            solids: [Box(min: SIMD3(1, 1, 0), max: SIMD3(3, 1.2, 1))], material: Self.concrete,
            elementSize: 0.25,
            fixedBase: true)
        model.elementKind = ElementKind.shell
        let solver = try solver(model)
        let shells = try #require(solver.shells)
        let surface = try #require(solver.structureSurface())
        #expect(surface.faceCount == 6 * (shells.elementCount + shells.beamCount))
        #expect(abs(volume(surface) - 2 * 0.2 * 1) < 0.01)
        #expect(isClosed(surface))
    }

    @Test("Numbers are written in fixed point, shortest first")
    func numbers() {
        var text = Text()
        for value: Float in [0, 1, -1, 1.05, 0.0001, -0.00001, 12.3456789, 100, -3.5] {
            text.append(value)
            text.append(" ")
        }
        text.append(0.5, decimals: 3)
        text.append(" ")
        text.appendList([0, 7, -12, 1_234_567])
        #expect(
            String(decoding: text.bytes, as: UTF8.self)
                == "0 1 -1 1.05 0.0001 0 12.3457 100 -3.5 0.5 0, 7, -12, 1234567")
    }

    @Test("The writer joins frames into one layer, writing topology only when it changes")
    func writer() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "usd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let scenario = Scenario(
            name: "Writer \"test\"", domainSize: SIMD3(10, 10, 5),
            boxes: [Box(min: .zero, max: SIMD3(1, 1, 1))],
            charge: Charge(mass: 1, position: SIMD3(5, 5, 1)), gauges: [Gauge("A", at: SIMD3(2, 2, 1))])
        var cube = StructureSurface()
        cube.appendBox(
            (0..<8).map { SIMD3(Float($0 & 1), Float(($0 >> 1) & 1), Float(($0 >> 2) & 1)) },
            faces: StructureSurface.bitCubeFaces, damage: 0, material: 0)
        cube.materials = [.init(name: "Concrete", isTransparent: false)]

        let url = folder.appending(path: "scene.usda")
        let writer = try USDSceneWriter(
            url: url, scenario: scenario, frameInterval: 0.002,
            camera: .init(eye: SIMD3(20, 20, 10), target: SIMD3(5, 5, 0), verticalFieldOfView: 0.75))
        try writer.append(cube)
        var moved = cube
        moved.points = moved.points.map { $0 + SIMD3(0, 0, 0.5) }
        try writer.append(moved)
        var smaller = moved
        smaller.quads.removeLast(4)
        smaller.damage.removeLast()
        smaller.material.removeLast()
        try writer.append(smaller)
        try writer.finish()

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("#usda 1.0\n"))
        #expect(text.contains("endTimeCode = 2\n") && text.contains("simulatedSecondsPerFrame = 0.002"))
        #expect(text.contains(#"string scenario = "Writer \"test\"""#))
        #expect(text.contains("def Mesh \"Blocks\"") && text.contains("def Sphere \"Gauge_0\""))
        #expect(text.contains("def Camera \"Camera\""))
        let counts = try #require(text.range(of: "faceVertexCounts.timeSamples"))
        let indices = try #require(text.range(of: "faceVertexIndices.timeSamples"))
        let topology = text[counts.upperBound..<indices.lowerBound]
        #expect(
            topology.contains("            0: [4, 4, 4, 4, 4, 4]")
                && topology.contains("            2: [4, 4, 4, 4, 4]"))
        #expect(!topology.contains("            1: "))
        #expect(text.contains("            1: [(0, 0, 0.5), (1, 0, 0.5)"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["scene.usda"])

        // macOS ships usdchecker; check the file against USD itself where it is installed.
        let checker = URL(filePath: "/usr/bin/usdchecker")
        if FileManager.default.isExecutableFile(atPath: checker.path) {
            let process = Process()
            process.executableURL = checker
            process.arguments = [url.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        let abandoned = try USDSceneWriter(
            url: folder.appending(path: "gone.usda"), scenario: scenario, frameInterval: 0.001)
        try abandoned.append(cube)
        abandoned.discard()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["scene.usda"])
    }
}
