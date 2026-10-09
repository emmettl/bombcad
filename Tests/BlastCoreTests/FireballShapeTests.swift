import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

@Suite("The fireball's shape and its radiation")
struct FireballShapeTests {
    private func scene(blocks: [Box] = []) -> FragmentScene {
        var scenario = Scenario(
            name: "Shape", domainSize: SIMD3(100, 100, 50), boxes: blocks,
            charge: Charge(mass: 1, position: SIMD3(50, 50, 10)))
        scenario.gauges = []
        return FragmentScene(scenario)
    }

    private func exposure(blocks: [Box] = [], model: FireballModel = .shape) -> ThermalExposure {
        var spec = ThermalSpec()
        spec.samples = 2048
        spec.groundSpacing = 20
        spec.fireball = model
        return ThermalExposure(spec: spec, scene: scene(blocks: blocks))
    }

    /// Blocks `size` a side between `low` and `high`, at 2,000 K, each filled as much as it is
    /// `inside`, judged at 4³ points in it.
    private func shape(
        size: Float, low: SIMD3<Float>, high: SIMD3<Float>, inside: (SIMD3<Float>) -> Bool
    ) -> FireballShape {
        let first = SIMD3<Int32>((low / size).rounded(.down))
        let counts = SIMD3<Int32>(((high - low) / size).rounded(.up))
        var fills: [UInt8] = []
        for k in 0..<counts.z {
            for j in 0..<counts.y {
                for i in 0..<counts.x {
                    let corner = SIMD3<Float>(first &+ SIMD3(i, j, k)) * size
                    var count = 0
                    for c in 0..<4 {
                        for b in 0..<4 {
                            for a in 0..<4
                            where inside(corner + (SIMD3(Float(a), Float(b), Float(c)) + 0.5) * size / 4) {
                                count += 1
                            }
                        }
                    }
                    fills.append(UInt8((255 * Float(count) / 64).rounded()))
                }
            }
        }
        return FireballShape(
            blockSize: size, first: first, counts: counts, fills: fills,
            temperatures: fills.map { $0 > 0 ? 2000 : 0 })
    }

    /// A frame of `shape`, its sphere that of its blocks.
    private func frame(_ shape: FireballShape) -> FireballFrame {
        var sum = SIMD3<Double>.zero
        var volume = 0.0
        for k in 0..<Int(shape.counts.z) {
            for j in 0..<Int(shape.counts.y) {
                for i in 0..<Int(shape.counts.x) {
                    let fill =
                        Double(shape.fills[i + Int(shape.counts.x) * (j + Int(shape.counts.y) * k)]) / 255
                    sum += fill * (SIMD3(Double(i), Double(j), Double(k)) + 0.5)
                    volume += fill
                }
            }
        }
        let centre = shape.low + SIMD3<Float>(sum / volume) * shape.blockSize
        return FireballFrame(
            time: 0, volume: shape.volume, centre: centre, temperature: 2000, hottest: 2000, shape: shape)
    }

    private let power = Float(ThermalExposure.stefanBoltzmann * pow(2000, 4))

    private func irradiance(
        _ exposure: ThermalExposure, _ frame: FireballFrame, at position: SIMD3<Float>,
        facing normal: SIMD3<Float>
    ) -> Float {
        exposure.irradiance(
            at: ThermalReceiver(position: position, normal: normal, surface: "test"), frame, power: power)
            / power
    }

    /// The view factor from a small surface to a rectangle parallel to it, `c` away, with a corner
    /// square in front of it and sides `a` and `b` (Incropera; Howell's catalogue B-3).
    private func corner(_ a: Double, _ b: Double, _ c: Double) -> Double {
        let (x, y) = (a / c, b / c)
        return
            (x / sqrt(1 + x * x) * atan(y / sqrt(1 + x * x)) + y / sqrt(1 + y * y) * atan(x / sqrt(1 + y * y)))
            / (2 * .pi)
    }

    /// The same to the rectangle from `u1` to `u2` and `v1` to `v2` across the line of sight,
    /// from corners at the foot of the receiver's normal, signed.
    private func rectangle(_ u1: Double, _ u2: Double, _ v1: Double, _ v2: Double, _ c: Double) -> Double {
        func g(_ u: Double, _ v: Double) -> Double {
            (u < 0 ? -1 : 1) * (v < 0 ? -1 : 1) * corner(abs(u), abs(v), c)
        }
        return g(u2, v2) - g(u1, v2) - g(u2, v1) + g(u1, v1)
    }

    @Test("A compact fireball gives the sphere's answer")
    func compact() {
        let centre = SIMD3<Float>(50, 50, 20)
        let ball = shape(size: 0.1, low: centre - 2, high: centre + 2) { simd_distance($0, centre) < 2 }
        #expect(ball.tileCount == 1)
        let frame = frame(ball)
        let blocks = exposure()
        let sphere = exposure(model: .sphere)
        let below = SIMD3<Float>(50, 50, 10)
        let tilted = SIMD3<Float>(sin(.pi / 3), 0, cos(.pi / 3))
        // Face on and tilted 60° away, (2/10)² and half that.
        let faceOn = irradiance(blocks, frame, at: below, facing: SIMD3(0, 0, 1))
        #expect(abs(faceOn / 0.04 - 1) < 0.02, "\(faceOn / 0.04)")
        let atAngle = irradiance(blocks, frame, at: below, facing: tilted)
        #expect(abs(atAngle / 0.02 - 1) < 0.03, "\(atAngle / 0.02)")
        #expect(irradiance(blocks, frame, at: below, facing: SIMD3(0, 0, -1)) == 0)
        #expect(abs(irradiance(blocks, frame, at: centre + 0.5, facing: SIMD3(0, 0, 1)) - 1) < 1e-5)
        // Against the sphere's own model, near and far, and to the side.
        for (position, normal) in [
            (SIMD3<Float>(50, 50, 17.5), SIMD3<Float>(0, 0, 1)), (SIMD3(50, 44, 20), SIMD3(0, 1, 0)),
            (SIMD3(58, 50, 12), simd_normalize(SIMD3(-1, 0, 1))), (SIMD3(50, 50, 0.001), SIMD3(0, 0, 1)),
        ] {
            let a = irradiance(blocks, frame, at: position, facing: normal)
            let b = irradiance(sphere, frame, at: position, facing: normal)
            #expect(abs(a / b - 1) < 0.03, "\(a) against the sphere's \(b) at \(position)")
        }
    }

    @Test("An elongated fireball gives a box's view factors, where the sphere does not")
    func elongated() {
        // 12 m by 2 by 2, 10 m up.
        let low = SIMD3<Float>(44, 49, 10)
        let high = SIMD3<Float>(56, 51, 12)
        let box = shape(size: 0.125, low: low, high: high) { _ in true }
        #expect(box.tileCount > 1)
        let frame = frame(box)
        let blocks = exposure()
        let sphere = exposure(model: .sphere)
        // Below its middle and towards its end, facing up at its underside 6 m above; beside it,
        // facing its long side 5 m away. Each sees only that one face.
        let cases: [(SIMD3<Float>, SIMD3<Float>, Double)] = [
            (SIMD3(50, 50, 4), SIMD3(0, 0, 1), rectangle(-6, 6, -1, 1, 6)),
            (SIMD3(54.5, 50.5, 4), SIMD3(0, 0, 1), rectangle(-10.5, 1.5, -1.5, 0.5, 6)),
            (SIMD3(50, 44, 11), SIMD3(0, 1, 0), rectangle(-6, 6, -1, 1, 5)),
        ]
        for (position, normal, expected) in cases {
            let a = Double(irradiance(blocks, frame, at: position, facing: normal))
            #expect(abs(a / expected - 1) < 0.03, "\(a) against \(expected) at \(position)")
            let b = Double(irradiance(sphere, frame, at: position, facing: normal))
            #expect(abs(b / expected - 1) > 0.1, "the sphere's \(b) against \(expected) at \(position)")
        }
    }

    @Test("An L-shaped fireball gives the sum of its arms' view factors")
    func lShaped() {
        // Two arms 12 m and 10 m long and 2 m wide, round a corner, 10 m up.
        let armA = Box(min: SIMD3(40, 40, 10), max: SIMD3(52, 42, 12))
        let armB = Box(min: SIMD3(40, 42, 10), max: SIMD3(42, 52, 12))
        let ell = shape(size: 0.25, low: SIMD3(40, 40, 10), high: SIMD3(52, 52, 12)) {
            armA.contains($0) || armB.contains($0)
        }
        let frame = frame(ell)
        let blocks = exposure()
        // Below the corner, facing up at the arms' undersides 6 m above, and seeing no other face.
        let expected = rectangle(-1, 11, -1, 1, 6) + rectangle(-1, 1, 1, 11, 6)
        let a = Double(irradiance(blocks, frame, at: SIMD3(41, 41, 4), facing: SIMD3(0, 0, 1)))
        #expect(abs(a / expected - 1) < 0.03, "\(a) against \(expected)")
    }

    @Test("A fireball round a corner gives a receiver that sees only part of it that part's irradiance")
    func roundACorner() {
        // A street along x, 4 m wide, and another along y off its end, filled with flame 4 m
        // deep; a building fills the inside of the corner. The receiver, on a face across the end
        // of the second street, 10 m off, sees only that street's end of the flame: the first is
        // round the corner, behind the building.
        let armA = Box(min: SIMD3(20, 20, 0), max: SIMD3(40, 24, 4))
        let armB = Box(min: SIMD3(36, 24, 0), max: SIMD3(40, 44, 4))
        let building = Box(min: SIMD3(10, 24, 0), max: SIMD3(36, 50, 10))
        let ell = shape(size: 0.25, low: SIMD3(20, 20, 0), high: SIMD3(40, 44, 4)) {
            armA.contains($0) || armB.contains($0)
        }
        let frame = frame(ell)
        let position = SIMD3<Float>(38, 54, 2)
        let normal = SIMD3<Float>(0, -1, 0)
        let hidden = Double(irradiance(exposure(blocks: [building]), frame, at: position, facing: normal))
        let expected = rectangle(-2, 2, -2, 2, 10)
        #expect(abs(hidden / expected - 1) < 0.03, "\(hidden) against \(expected)")
        // Without the building, the first street's side shows too.
        let open = Double(irradiance(exposure(), frame, at: position, facing: normal))
        #expect(open > 1.1 * hidden, "\(open) open against \(hidden) hidden")
        // The sphere, centred inside the building, is judged as a whole.
        let sphere = Double(
            irradiance(exposure(blocks: [building], model: .sphere), frame, at: position, facing: normal))
        #expect(abs(sphere / expected - 1) > 0.1, "the sphere's \(sphere) against \(expected)")
    }

    @Test("A hot sphere of gas is cut out as one compact tile of blocks, here and on the GPU")
    func extraction() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scenario = Scenario(
            name: "Hot", domainSize: SIMD3(repeating: 8), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)))
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.125)
        let centre = SIMD3<Float>(4, 3.5, 4)
        let pressure: Float = 101_325
        solver.mutateState { cells in
            for k in 0..<64 {
                for j in 0..<64 {
                    for i in 0..<64 {
                        let x = (SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5) * 0.125
                        let t: Float = simd_distance(x, centre) < 1.5 ? 2500 : 300
                        cells[solver.grid.index(i, j, k)] = CellState(
                            Primitive(density: pressure / (287.05 * t), velocity: .zero, pressure: pressure),
                            gamma: 1.4)
                    }
                }
            }
        }
        let fireball = solver.fireball(luminousTemperature: 1500)
        let shape = try #require(fireball.shape)
        #expect(shape.blockSize == 0.25 && shape.tileCount == 1)
        #expect(abs(shape.volume / fireball.volume - 1) < 0.01, "\(shape.volume) against \(fireball.volume)")
        #expect(shape.temperatures.allSatisfy { $0 == 0 || abs(Int($0) - 2500) <= 2 })
        #expect(abs(simd_distance(shape.sampling.tiles[0].centre, centre)) < 0.05)
    }

    @Test("A large fireball's blocks are doubled until they fit, and the shape travels intact")
    func coarsening() throws {
        // A grid of 200 by 200 by 60 cells, every one of them luminous: 300,000 small blocks.
        let grid = Grid(nx: 200, ny: 200, nz: 60, cellSize: 0.1)
        let dims = LuminousBlock.dimensions(grid)
        var blocks: [LuminousBlock] = []
        for k in 0..<dims.z {
            for j in 0..<dims.y {
                for i in 0..<dims.x {
                    blocks.append(
                        LuminousBlock(
                            index: i + dims.x * (j + dims.y * k), cells: 8, fourth: 8 * pow(2000, 4),
                            hottest: 2000,
                            position: .zero, air: 8))
                }
            }
        }
        let shape = try #require(FireballShape(blocks: blocks, grid: grid))
        #expect(shape.temperatures.count <= FireballShape.maximumBlocks)
        #expect(abs(shape.blockSize - 0.8) < 1e-6 && shape.counts == SIMD3(25, 25, 8))
        #expect(shape.temperatures.allSatisfy { $0 == 2000 } && shape.fills.allSatisfy { $0 == 255 })
        let frame = FireballFrame(
            time: 0.01, volume: 1, centre: SIMD3(1, 2, 3), temperature: 2000, hottest: 2100, shape: shape)
        // Four bytes a block, sent as the workers' protocol does, without escaping base64's slashes.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = try encoder.encode(frame)
        #expect(data.count < 4 * shape.temperatures.count + 300, "\(data.count)")
        #expect(try JSONDecoder().decode(FireballFrame.self, from: data) == frame)
        // Its result keeps the frames without their shapes.
        var exposure = exposure()
        exposure.add(frame)
        #expect(exposure.frames == [frame.withoutShape])
    }

    @Test("A description names its fireball model, the shape unless it says otherwise")
    func model() throws {
        #expect(try JSONDecoder().decode(ThermalSpec.self, from: Data("{}".utf8)).fireball == .shape)
        let sphere = try JSONDecoder().decode(ThermalSpec.self, from: Data(#"{"fireball": "sphere"}"#.utf8))
        #expect(sphere.fireball == .sphere)
    }
}
