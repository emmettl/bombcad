import Foundation
import Testing
import simd

@testable import BlastModel

@Suite("Structure surface and USD export")
struct StructureSurfaceTests {
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
