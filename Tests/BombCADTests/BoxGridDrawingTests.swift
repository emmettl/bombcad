import BlastCore
import Foundation
import Metal
import SceneView
import Testing
import simd

@testable import BlastRender

/// A district's many blocks drawn through the grid of columns look as they do tested one by one.
@MainActor @Suite("Drawing many blocks")
struct BoxGridDrawingTests {
    @Test("Through the grid, 400 blocks draw as they do tested one by one, from above and low down")
    func gridMatchesLoop() throws {
        // A town of 400 blocks of varied size and height, some touching, some overlapping.
        var generator = SplitMix(seed: 7)
        let boxes = (0..<400).map { _ -> Box in
            let x = Float(generator.next() % 190)
            let y = Float(generator.next() % 190)
            let w = Float(4 + generator.next() % 12)
            let d = Float(4 + generator.next() % 12)
            let h = Float(3 + generator.next() % 30)
            return Box(min: SIMD3(x, y, 0), max: SIMD3(min(x + w, 199), min(y + d, 199), h))
        }
        let scene = Scenario(
            name: "Town", domainSize: SIMD3(200, 200, 40), boxes: boxes,
            charge: Charge(mass: 1, position: SIMD3(100, 100, 0.5)))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 2)
        func draw(grid: Bool, _ camera: OrbitCamera) throws -> [UInt8] {
            let renderer = try SceneRenderer(device: device)
            renderer.gridBoxes = grid ? 256 : .max
            renderer.setScene(scene, solver: solver)
            let frame = try #require(
                renderer.snapshot(commandQueue: queue, width: 160, height: 120, camera: camera))
            let data = try #require(frame.image.dataProvider?.data) as Data
            return [UInt8](data)
        }
        for camera in [
            OrbitCamera(target: SIMD3(100, 100, 10), distance: 260, azimuth: 0.4, elevation: 1.2),
            OrbitCamera(target: SIMD3(100, 100, 10), distance: 180, azimuth: 2.1, elevation: 0.08),
        ] {
            let plain = try draw(grid: false, camera)
            let gridded = try draw(grid: true, camera)
            #expect(plain.count == gridded.count)
            let differing = zip(plain, gridded).filter { abs(Int($0) - Int($1)) > 2 }.count
            // Ties between blocks at the same distance may break the other way.
            #expect(Double(differing) / Double(plain.count) < 0.002, "\(differing) of \(plain.count)")
        }
    }
}

/// A small deterministic generator.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
