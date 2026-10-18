import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// A structure standing on the scene's terrain (`StructureModel.ground`): held at the ground's
/// height there, and landing on the surface, not z = 0, when it falls.
@Suite("Structures on the terrain", .gpuThreads)
struct StructureOnTerrainTests {
    let device: MTLDevice
    let material = StructureMaterial.elastic(density: 2400, youngsModulus: 30e9, poissonRatio: 0.2)
    /// A slope rising 1 in 4 along x, 4 m up at x = 10.
    let terrain = Terrain.sampled(domain: SIMD3(20, 20, 12), spacing: 0.5) { max(0, ($0.x + 6) * 0.25) }

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// The lattice's nodes over `x` × `y` × `z` elements from its origin.
    private func nodes(_ x: Int, _ y: Int, _ z: Int) -> [(Int, Int, Int)] {
        (0...z).flatMap { k in (0...y).flatMap { j in (0...x).map { i in (i, j, k) } } }
    }

    private func steps(_ solver: StructureSolver, seconds: Double) -> Int {
        max(1, Int((seconds / Double(solver.criticalTimeStep)).rounded()))
    }

    @Test("A block dropped onto the slope lands on it, not on the floor")
    func solidLands() throws {
        // Released 1 m above the ground at its middle.
        var model = StructureModel(
            solids: [Box(min: SIMD3(9.5, 9.5, 5), max: SIMD3(10.5, 10.5, 5.5))], material: material,
            elementSize: 0.25, fixedBase: false)
        model = model.standing(on: terrain)
        let solver = try StructureSolver(device: device, model: model)
        solver.damping = 2
        solver.advance(steps: steps(solver, seconds: 1.5))
        var lowest = Float.infinity
        var below: Float = 0
        for (i, j, k) in nodes(4, 4, 2) where solver.node(i, j, k).mass > 0 {
            let position = solver.position(i, j, k)
            lowest = min(lowest, position.z)
            below = max(below, terrain.height(at: position) - position.z)
        }
        // On the ground (4 m up at its middle), none of it more than a millimetre into it.
        #expect(lowest > 3.5 && lowest < 4.2, "\(lowest)")
        #expect(below < 1e-3, "\(below)")
    }

    @Test("A shell plate dropped onto the slope lands on it, not on the floor")
    func shellLands() throws {
        var model = StructureModel(
            solids: [Box(min: SIMD3(9, 9, 5), max: SIMD3(11, 11, 5.2))], material: material,
            elementSize: 0.25,
            fixedBase: false)
        model.elementKind = .shell
        model = model.standing(on: terrain)
        let solver = try ShellSolver(device: device, model: model)
        solver.damping = 2
        solver.advance(steps: Int((1.5 / Double(solver.criticalTimeStep)).rounded()))
        var positions = solver.referencePositions
        solver.mutateNodes { nodes in for n in nodes.indices { positions[n] += nodes[n].displacement } }
        let lowest = positions.map(\.z).min() ?? 0
        let below = positions.map { terrain.height(at: $0) - $0.z }.max() ?? 0
        #expect(lowest > 3.5, "\(lowest)")
        #expect(below < 1e-3, "\(below)")
    }

    @Test("Clamped or connected at the ground's height on the slope, a block stands where it is put")
    func heldOnTheSlope() throws {
        // Its base on the ground at its middle, a step's tolerance either side.
        for connection in [nil, Anchorage.dowelled(ratio: BaseConnection.dowelRatio)] {
            var model = StructureModel(
                solids: [Box(min: SIMD3(9.5, 9.5, 4), max: SIMD3(10.5, 10.5, 6))], material: material,
                elementSize: 0.25, fixedBase: true)
            model.baseAnchorage = connection
            model = model.standing(on: terrain)
            let solver = try StructureSolver(device: device, model: model)
            solver.damping = 50
            solver.advance(steps: steps(solver, seconds: 0.3))
            let fallen =
                nodes(4, 4, 8).filter { solver.node($0.0, $0.1, $0.2).mass > 0 }
                .map { -solver.displacement($0.0, $0.1, $0.2).z }.max() ?? 0
            #expect(fallen < 1e-3, "\(connection == nil ? "clamped" : "connected"): fell \(fallen) m")
        }
    }

    @Test(
        "A block standing on cut terrain shuts in the slivers under it, and the air stays finite under a blast"
    )
    func cappedSlivers() throws {
        // A 1 in 4 slope; a block clamped on it, its base 1.5 m up where the ground is 1.375-1.625 m,
        // so that thin cut cells lie under its cells; 5 kg 3 m in front.
        let domain = SIMD3<Float>(12, 8, 8)
        let slope = Terrain.sampled(domain: domain, spacing: 0.5) { max(0, $0.x * 0.25) }
        let block = StructureModel(
            solids: [Box(min: SIMD3(5.5, 3.5, 1.5), max: SIMD3(6.5, 4.5, 3))], material: material,
            elementSize: 0.25,
            fixedBase: true)
        var scenario = Scenario(
            name: "Block on a slope", domainSize: domain, boxes: [],
            charge: Charge(mass: 5, position: SIMD3(2.5, 4, slope.height(at: SIMD2(2.5, 4)) + 1)), gauges: [],
            structure: block)
        scenario.terrain = slope
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        let result = solver.advance(until: 0.01)
        #expect(result.isStable)
        let capped = try #require(solver.cappedSliverBuffer)
        let columns = capped.contents().bindMemory(to: UInt32.self, capacity: capped.length / 4)
        #expect((0..<(capped.length / 4)).contains { columns[$0] > 0 })
    }
}
