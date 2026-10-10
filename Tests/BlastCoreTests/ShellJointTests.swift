import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Support joints on shells and beams facing any way (`ShellMesh.jointPoints`): a wall hung by
/// the free edge at its end, a wall on an inclined joint, and a slab and a beam seated on
/// bearings at their ends, each as solid elements do.
@Suite("Shell joints")
struct ShellJointTests {
    let device: MTLDevice
    let material = StructureMaterial.elastic(density: 2400, youngsModulus: 30e9, poissonRatio: 0.2)
    let g: Float = 9.81

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    private func steps(_ step: Float, seconds: Double) -> Int {
        max(1, Int((seconds / Double(step)).rounded()))
    }

    /// Mass-weighted means of a body's nodes, over shell nodes or solid nodes.
    private func mean(_ solver: ShellSolver, _ value: (ShellNode) -> SIMD3<Float>) -> SIMD3<Float> {
        var total = SIMD3<Float>.zero
        var mass: Float = 0
        solver.mutateNodes { nodes in
            for node in nodes where node.flags & 128 == 0 {
                total += node.mass * value(node)
                mass += node.mass
            }
        }
        return total / mass
    }

    private func mean(_ solver: StructureSolver, _ value: (StructureNode) -> SIMD3<Float>) -> SIMD3<Float> {
        var total = SIMD3<Float>.zero
        var mass: Float = 0
        solver.mutateNodes { nodes in
            for node in nodes {
                total += node.mass * value(node)
                mass += node.mass
            }
        }
        return total / mass
    }

    /// Runs `model` as shells or solids: gravity brought on over 20 ms, then `seconds` more.
    /// Returns its mean displacement and velocity, the connection's reaction, and its weight.
    private func run(_ model: StructureModel, shells: Bool, seconds: Double) throws -> (
        displacement: SIMD3<Float>, velocity: SIMD3<Float>, reaction: SIMD3<Float>, area: Float, weight: Float
    ) {
        var model = model
        model.elementKind = shells ? .shell : .solid
        if shells {
            let solver = try ShellSolver(device: device, model: model)
            let area = solver.supportBearingArea(at: 0)
            for n in 1...20 {
                solver.gravity = g * Float(n) / 20
                solver.advance(steps: steps(solver.criticalTimeStep, seconds: 0.001))
            }
            solver.advance(steps: steps(solver.criticalTimeStep, seconds: seconds))
            var mass: Float = 0
            solver.mutateNodes { mass = $0.reduce(0) { $0 + $1.mass } }
            return (
                mean(solver) { $0.displacement }, mean(solver) { $0.velocity },
                solver.anchorSummary()?.reaction ?? .zero, area, mass * g
            )
        }
        let solver = try StructureSolver(device: device, model: model)
        let area = solver.supportBearingArea(at: 0)
        for n in 1...20 {
            solver.gravity = g * Float(n) / 20
            solver.advance(steps: steps(solver.criticalTimeStep, seconds: 0.001))
        }
        solver.advance(steps: steps(solver.criticalTimeStep, seconds: seconds))
        var mass: Float = 0
        solver.mutateNodes { mass = $0.reduce(0) { $0 + $1.mass } }
        return (
            mean(solver) { $0.displacement }, mean(solver) { $0.velocity },
            solver.anchorSummary()?.reaction ?? .zero, area, mass * g
        )
    }

    /// A wall 1 m long, 1 m high and 0.25 m thick across y, raised 2 m off the ground and hung by
    /// a joint across its end at x = 0.
    private func endHung(_ law: Anchorage) -> StructureModel {
        var body = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 2), max: SIMD3(1, 0.25, 3))], material: material,
            elementSize: 0.125,
            fixedBase: false)
        body.supports = [Box(min: SIMD3(-0.01, -0.01, 1.99), max: SIMD3(0.01, 0.26, 3.01))]
        var law = law
        law.side = .negativeX
        body.supportAnchorages = [law]
        return body
    }

    @Test(
        "A shell wall hung by the free edge at its end holds W below c A and slides above, as solid elements")
    func endEdge() throws {
        func law(_ cohesion: Float) -> Anchorage {
            Anchorage(
                tensileStrength: 1e6, tensionOpening: 1e-3, cohesion: cohesion, cohesionSlip: 1e-3,
                friction: 0)
        }
        // The end is 0.25 m²; the wall weighs 2400 g × 0.25 m³.
        let stress = 2400 * g
        for shells in [true, false] {
            let holds = try run(endHung(law(stress / 0.7)), shells: shells, seconds: 0.28)
            let slides = try run(endHung(law(stress / 1.3)), shells: shells, seconds: 0.28)
            #expect(abs(holds.area - 0.25) < 1e-4, "shells \(shells): \(holds.area)")
            #expect(holds.displacement.z > -1e-3, "shells \(shells): \(holds.displacement)")
            #expect(slides.displacement.z < -0.1, "shells \(shells): \(slides.displacement)")
            #expect(abs(holds.reaction.z - holds.weight) < 0.03 * holds.weight)
        }
    }

    /// A wall 2 m long across x, 1 m high and 0.25 m thick, raised 2 m and resting with `friction`
    /// on a joint at its base inclined at `angle`, falling towards +x.
    private func onSlope(angle: Float, friction: Float) -> StructureModel {
        var body = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 2), max: SIMD3(2, 0.25, 3))], material: material,
            elementSize: 0.125,
            fixedBase: false)
        body.supports = [Box(min: SIMD3(-0.01, -0.01, 1.99), max: SIMD3(2.01, 0.26, 2.01))]
        body.supportAnchorages = [
            Anchorage(
                tensileStrength: 0, tensionOpening: 0, cohesion: 0, cohesionSlip: 0, friction: friction,
                jointNormal: Anchorage.normal(tilt: angle, azimuth: .pi))
        ]
        return body
    }

    @Test(
        "A shell wall on a joint at 30° or 45° holds below the friction angle and slides above it, as solid elements"
    )
    func inclinedBase() throws {
        for degrees in [Float(30), 45] {
            let angle = degrees * .pi / 180
            let down = SIMD3<Float>(cos(angle), 0, -sin(angle))
            for shells in [true, false] {
                let held = try run(
                    onSlope(angle: angle, friction: 1.25 * tan(angle)), shells: shells, seconds: 0.15)
                #expect(simd_length(held.velocity) < 2e-3, "\(degrees)°, shells \(shells): \(held.velocity)")
                #expect(abs(held.reaction.z - held.weight) < 0.03 * held.weight)
                // Sliding, the body chatters on the joint, hopping at a few centimetres a second
                // as stick and slip pass over its nodes (on a joint along the lattice too), so the
                // check is Coulomb's in impulse: along the joint it gains g (sin α − μ cos α) less μ
                // times what it gains across it.
                let friction = 0.75 * tan(angle)
                let normal = SIMD3<Float>(sin(angle), 0, cos(angle))
                let early = try run(onSlope(angle: angle, friction: friction), shells: shells, seconds: 0.1)
                let late = try run(onSlope(angle: angle, friction: friction), shells: shells, seconds: 0.3)
                let across = simd_dot(late.velocity - early.velocity, normal) / 0.2
                let expected = g * (sin(angle) - friction * cos(angle)) - friction * across
                let acceleration = simd_dot(late.velocity - early.velocity, down) / 0.2
                #expect(
                    abs(acceleration - expected) < 0.05 * g * sin(angle),
                    "\(degrees)°, shells \(shells): \(acceleration) against \(expected)")
            }
        }
    }

    @Test("A slab and a beam seated on bearings at their ends bear their weight and lift off them")
    func seated() throws {
        // A slab 3 m by 1 m and 0.2 m deep, and a beam 3 m long of 0.3 m square section, each with
        // 0.25 m of each end on a bearing under it, resting there.
        for size in [SIMD3<Float>(3, 1, 0.2), SIMD3<Float>(3, 0.3, 0.3)] {
            var body = StructureModel(
                solids: [Box(min: SIMD3(0, 0, 2), max: SIMD3(0, 0, 2) + size)], material: material,
                elementSize: size.y < 0.5 ? 0.25 : 0.125, fixedBase: false)
            body.elementKind = .shell
            body.supports = [
                Box(min: SIMD3(-0.01, -0.01, 1.99), max: SIMD3(0.26, size.y + 0.01, 2.01)),
                Box(min: SIMD3(size.x - 0.26, -0.01, 1.99), max: SIMD3(size.x + 0.01, size.y + 0.01, 2.01)),
            ]
            body.supportAnchorages = [.resting(), .resting()]
            let solver = try ShellSolver(device: device, model: body)
            let bearing = solver.supportBearingArea(at: 0) + solver.supportBearingArea(at: 1)
            #expect(size.y < 0.5 ? solver.beamCount > 0 : solver.elementCount > 0)
            // Each bearing ties the soffit's points at the nodes in it, over their shares: a
            // quarter metre and half the next element.
            let tributary = 2 * (0.25 + body.elementSize / 2) * size.y
            #expect(abs(bearing - tributary) < 1e-3 * tributary, "\(size): \(bearing)")
            solver.damping = 50
            solver.advance(steps: steps(solver.criticalTimeStep, seconds: 0.2))
            solver.damping = 0
            solver.advance(steps: steps(solver.criticalTimeStep, seconds: 0.05))
            let summary = try #require(solver.anchorSummary())
            var mass: Float = 0
            solver.mutateNodes { nodes in mass = nodes.reduce(0) { $0 + $1.mass } }
            #expect(abs(summary.reaction.z - mass * g) < 0.03 * mass * g, "\(size): \(summary.reaction)")
            // Thrown up, it leaves its bearings, which hold nothing down.
            solver.mutateNodes { nodes in for n in nodes.indices { nodes[n].vz = 2 } }
            solver.advance(steps: steps(solver.criticalTimeStep, seconds: 0.05))
            #expect(simd_length(solver.anchorSummary()?.reaction ?? .zero) < 1e-3 * mass * g)
        }
    }
}
