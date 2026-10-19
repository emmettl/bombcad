import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// Independent deformable bodies meeting through contact. Mechanical checks, with the air
/// unaware of the bodies so that only contact moves momentum between them.
@Suite("Contact between independent bodies", .serialized, .gpuThreads)
struct BodyContactTests {
    let device: MTLDevice
    init() throws { device = try #require(MTLCreateSystemDefaultDevice()) }

    /// A soft elastic material, so that the bodies' time steps are not tiny.
    let material = StructureMaterial.elastic(density: 2400, youngsModulus: 3e9, poissonRatio: 0.2)

    /// Two free blocks 1.6 m apart in x, raised off the ground: the first of 0.25 m elements, the
    /// second of 0.5 m, each solid or shell.
    func scene(shells: (Bool, Bool)) throws -> Scenario {
        func model(_ box: Box, size: Float, shell: Bool) -> StructureModel {
            var body = StructureModel(solids: [box], material: material, elementSize: size, fixedBase: false)
            if shell { body.elementKind = .shell }
            return body
        }
        var scene = Scenario(
            name: "Two blocks", domainSize: SIMD3(8, 6, 5), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)),
            structure: model(
                Box(min: SIMD3(2, 2, 1), max: SIMD3(2.5, 4, 3)), size: 0.25, shell: shells.0))
        try scene.addStructureObject(
            model(Box(min: SIMD3(4.1, 1.5, 0.5), max: SIMD3(4.6, 4.5, 3.5)), size: 0.5, shell: shells.1),
            name: "Second block")
        return scene
    }

    func configuration() -> SolverConfiguration {
        var configuration = SolverConfiguration()
        configuration.skipStillAir = false
        configuration.twoWayCoupling = false
        configuration.airSleepThreshold = 0
        configuration.airSleepCrossings = 0
        return configuration
    }

    struct Motion {
        var momentum: SIMD3<Double>
        var energy: Double
        /// The first body's nodes furthest along x, and the second's least far.
        var front: Double
        var back: Double
    }

    func motion(_ solver: BlastSolver) -> [Motion] {
        solver.bodies.map { body in
            var result = Motion(momentum: .zero, energy: 0, front: -.infinity, back: .infinity)
            func add(_ position: SIMD3<Float>, _ velocity: SIMD3<Float>, _ mass: Float) {
                result.momentum += Double(mass) * SIMD3<Double>(velocity)
                result.energy += 0.5 * Double(mass) * Double(simd_length_squared(velocity))
                result.front = max(result.front, Double(position.x))
                result.back = min(result.back, Double(position.x))
            }
            if let solids = body.solids {
                for k in 0...solids.ez {
                    for j in 0...solids.ey {
                        for i in 0...solids.ex where solids.storedNode(i, j, k) != nil {
                            let node = solids.node(i, j, k)
                            add(solids.position(i, j, k), node.velocity, node.mass)
                        }
                    }
                }
            }
            if let shells = body.shells {
                for n in 0..<shells.nodeCount where shells.node(n).flags & 128 == 0 {
                    let node = shells.node(n)
                    add(shells.position(n), node.velocity, node.mass)
                }
            }
            return result
        }
    }

    func setUp(_ solver: BlastSolver, speed: Float) {
        for (index, body) in solver.bodies.enumerated() {
            body.solids?.gravity = 0
            body.solids?.groundContact = false
            body.shells?.gravity = 0
            body.shells?.groundContact = false
            guard index == 0 else { continue }
            body.solids?.mutateNodes { nodes in
                for n in nodes.indices { nodes[n].velocity = SIMD3(speed, 0, 0) }
            }
            body.shells?.mutateNodes { nodes in
                for n in nodes.indices { nodes[n].velocity = SIMD3(speed, 0, 0) }
            }
        }
    }

    @Test(
        "A block thrown into another pushes it through contact, keeping their momentum and adding no energy",
        arguments: [(false, false), (false, true), (true, false), (true, true)])
    func blocksMeet(shells: (Bool, Bool)) throws {
        let scene = try scene(shells: shells)
        let solver = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.5, configuration: configuration())
        setUp(solver, speed: 20)
        // Bodies are compiled in object-ID order; the first is the thrown one.
        let thrown = solver.bodies.firstIndex { $0.id == scene.structuralObjects[0].id }!
        let struck = 1 - thrown
        let start = motion(solver)
        let momentum = start[thrown].momentum + start[struck].momentum
        let energy = start[thrown].energy + start[struck].energy
        var deepest = -Double.infinity
        var apart = 0.0
        while solver.time < 0.12 {
            let result = solver.advance(steps: 4)
            #expect(!result.unsupportedInteraction && result.isStable)
            let now = motion(solver)
            deepest = max(deepest, now[thrown].front - now[struck].back)
            if !solver.bodiesInContact { apart = solver.time }
            guard result.steps > 0 else { break }
        }
        let end = motion(solver)
        // Contact came on of itself, shortly before the blocks met.
        #expect(solver.bodiesInContact && apart > 0.02)
        #expect(!solver.interObjectContactDetected)
        // The struck block moves off; the pair's momentum is what it was, and no energy appears.
        #expect(end[struck].momentum.x > 0.2 * momentum.x)
        #expect(end[thrown].momentum.x < 0.8 * momentum.x)
        let total = end[thrown].momentum + end[struck].momentum
        #expect(simd_length(total - momentum) < 1e-3 * simd_length(momentum))
        #expect(end[thrown].energy + end[struck].energy < energy)
        // Spheres overlap by up to half the sum of their widths, and no further.
        #expect(deepest < 0.5 * (0.25 + 0.5))
    }

    @Test("Without contact between bodies, coming close still stops the run")
    func contactOff() throws {
        var configuration = configuration()
        configuration.interBodyContact = false
        let solver = try BlastSolver(
            device: device, scenario: scene(shells: (false, false)), cellSize: 0.5,
            configuration: configuration)
        setUp(solver, speed: 10)
        while solver.time < 0.12 {
            let result = solver.advance(steps: 4)
            if result.unsupportedInteraction || result.steps == 0 { break }
        }
        #expect(solver.interObjectContactDetected)
        #expect(!solver.bodiesInContact)
    }

    @Test(
        "Two bodies loaded by one blast exchange with the air what each does alone, neither duplicated nor misattributed"
    )
    func exchangeAccounting() throws {
        var first = StructureModel(
            solids: [Box(min: SIMD3(4, 5, 1), max: SIMD3(4.5, 7, 3))], material: material, elementSize: 0.25,
            fixedBase: false)
        first.elementKind = .solid
        var second = StructureModel(
            solids: [Box(min: SIMD3(9.5, 4.5, 1), max: SIMD3(10, 7.5, 3))], material: material,
            elementSize: 0.5,
            fixedBase: false)
        second.elementKind = .shell
        /// What the bodies gained and the air lost (horizontal, N s), with the bodies given.
        func exchange(_ models: [StructureModel]) throws -> (bodies: [Double], air: Double) {
            var scene = Scenario(
                name: "Bodies", domainSize: SIMD3(14, 12, 6), boxes: [],
                charge: Charge(mass: 0.5, position: SIMD3(7, 6, 2)), structure: models[0])
            for model in models.dropFirst() { try scene.addStructureObject(model, name: "Second") }
            var configuration = configuration()
            configuration.twoWayCoupling = true
            let solver = try BlastSolver(
                device: device, scenario: scene, cellSize: 0.25, configuration: configuration)
            setUp(solver, speed: 0)
            let air = solver.momentum()
            // The wave is still inside the domain, so nothing has left through its open faces.
            solver.advance(until: 0.005)
            // In the scene's order.
            let gained = scene.structuralObjects.map { object in
                motion(solver)[solver.bodies.firstIndex { $0.id == object.id }!].momentum.x
            }
            return (gained, (air - solver.momentum()).x)
        }
        let together = try exchange([first, second])
        let alone = [try exchange([first]), try exchange([second])]
        // Each body takes what it takes alone; the air loses what it loses to each alone.
        for n in 0..<2 {
            #expect(abs(together.bodies[n]) > 10)
            #expect(abs(together.bodies[n] - alone[n].bodies[0]) < 0.02 * abs(alone[n].bodies[0]))
        }
        let air = alone[0].air + alone[1].air
        #expect(abs(together.air - air) < 0.02 * abs(alone[0].air - alone[1].air))
        // A body's load is read from the pressure at its faces, not from the momentum the air puts
        // through them, so it takes a few per cent less than the air loses to it (3 and 6% here).
        for n in 0..<2 {
            #expect(abs(alone[n].bodies[0]) < abs(alone[n].air))
            #expect(abs(alone[n].bodies[0] - alone[n].air) < 0.1 * abs(alone[n].air))
        }
    }
}
