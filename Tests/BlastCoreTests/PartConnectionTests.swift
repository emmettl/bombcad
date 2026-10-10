import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Connections between two moving parts of one body (`Anchorage.betweenParts`): a block seated
/// across a gap on another bears on it, holds and slides on it with its forces equal and
/// opposite, and drops once it slides off its seat.
@Suite("Connections between parts")
struct PartConnectionTests {
    let device: MTLDevice
    let material = StructureMaterial.elastic(density: 2400, youngsModulus: 30e9, poissonRatio: 0.2)
    let g: Float = 9.81
    let h: Float = 0.125

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    private func steps(_ solver: StructureSolver, seconds: Double) -> Int {
        max(1, Int((seconds / Double(solver.criticalTimeStep)).rounded()))
    }

    /// A block 1 m square and 0.5 m deep seated across a gap of one element on another `below`,
    /// 0.5 m deep, the gap's region spanning the lower block's whole top. On the ground and
    /// clamped there when `grounded`, else both floating 2 m up.
    private func seated(_ law: Anchorage, below: Box? = nil, grounded: Bool = true) -> StructureModel {
        let base: Float = grounded ? 0 : 2
        let lower = below ?? Box(min: SIMD3(0, 0, base), max: SIMD3(1, 1, base + 0.5))
        let upper = Box(min: SIMD3(0, 0, lower.max.z + h), max: SIMD3(1, 1, lower.max.z + h + 0.5))
        var body = StructureModel(
            solids: [lower, upper], material: material, elementSize: h, fixedBase: grounded)
        body.supports = [
            Box(
                min: SIMD3(lower.min.x - 0.01, lower.min.y - 0.01, lower.max.z - 0.01),
                max: SIMD3(lower.max.x + 0.01, lower.max.y + 0.01, upper.min.z + 0.01))
        ]
        var law = law
        law.betweenParts = true
        body.supportAnchorages = [law]
        return body
    }

    /// The mass-weighted mean of `value` over the nodes above `level`.
    private func mean(_ solver: StructureSolver, above level: Float, _ value: (StructureNode) -> SIMD3<Float>)
        -> SIMD3<Float>
    {
        var total = SIMD3<Float>.zero
        var mass: Float = 0
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...solver.ex {
                        guard let n = solver.storedNode(i, j, k), solver.referencePosition(i, j, k).z > level
                        else { continue }
                        total += nodes[n].mass * value(nodes[n])
                        mass += nodes[n].mass
                    }
                }
            }
        }
        return total / mass
    }

    private func mass(_ solver: StructureSolver, above level: Float) -> Float {
        var mass: Float = 0
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...solver.ex {
                        guard let n = solver.storedNode(i, j, k), solver.referencePosition(i, j, k).z > level
                        else { continue }
                        mass += nodes[n].mass
                    }
                }
            }
        }
        return mass
    }

    @Test(
        "A block seated across a gap on another bears its weight on it, the pairs' forces equal and opposite")
    func bearing() throws {
        let solver = try StructureSolver(device: device, model: seated(.resting()))
        // The upper block's underside, 1 m², is tied to the lower block's top.
        #expect(abs(solver.supportBearingArea(at: 0) - 1) < 1e-4)
        solver.damping = 200
        solver.advance(steps: steps(solver, seconds: 0.05))
        solver.damping = 0
        solver.advance(steps: steps(solver, seconds: 0.02))
        let summary = try #require(solver.pairSummary())
        #expect(summary.pairs == 81)
        let weight = mass(solver, above: 0.55) * g
        #expect(abs(summary.force.z - weight) < 0.03 * weight, "\(summary.force) against \(weight)")
        // Nothing reaches the ground through the pairs: the ground carries both blocks.
        #expect(solver.anchorSummary()?.nodes == 0)
    }

    @Test("Floating blocks tied across a gap keep their momentum, whether the tie holds or shears through")
    func momentum() throws {
        for (cohesion, speed) in [(Float(2e6), Float(0.1)), (5e3, 1)] {
            var law = Anchorage.constructionJoint
            law.cohesion = cohesion
            law.friction = 0
            let solver = try StructureSolver(device: device, model: seated(law, grounded: false))
            solver.gravity = 0
            solver.groundContact = false
            // The upper block thrown along the joint.
            solver.mutateNodes { nodes in
                for k in 0...solver.ez {
                    for j in 0...solver.ey {
                        for i in 0...solver.ex {
                            guard let n = solver.storedNode(i, j, k),
                                solver.referencePosition(i, j, k).z > 2.55
                            else { continue }
                            nodes[n].velocity = SIMD3(speed, 0, 0)
                        }
                    }
                }
            }
            let start = solver.momentum()
            solver.advance(steps: steps(solver, seconds: 0.05))
            let end = solver.momentum()
            #expect(simd_length(end - start) < 1e-5 * simd_length(start), "\(cohesion): \(start) to \(end)")
            let summary = try #require(solver.pairSummary())
            // The blocks weigh the same, so the lower one moves at twice the mean less the upper.
            let upper = mean(solver, above: 2.55) { $0.velocity }.x
            let lower = 2 * mean(solver, above: 0) { $0.velocity }.x - upper
            if cohesion > 1e6 {
                // Held: they move on together, ringing about their common speed.
                #expect(summary.separated == 0 && summary.maxSlip < 1e-5, "\(summary)")
                #expect(
                    abs(
                        mean(solver, above: 2.55) { $0.displacement }.x
                            - mean(solver, above: 0) { $0.displacement }.x) < 1e-3)
            } else {
                // Sheared through, without friction: the lower block is left nearly behind.
                #expect(summary.separated == summary.pairs, "\(summary)")
                #expect(upper > 0.98 && lower < 0.02, "\(upper), \(lower)")
            }
        }
    }

    @Test("Struck together across a gap, floating blocks rebound with their momentum and never more energy")
    func impact() throws {
        let solver = try StructureSolver(device: device, model: seated(.resting(), grounded: false))
        solver.gravity = 0
        solver.groundContact = false
        func kinetic() -> Double {
            var energy = 0.0
            solver.mutateNodes { nodes in
                for node in nodes {
                    energy += 0.5 * Double(node.mass) * Double(simd_length_squared(node.velocity))
                }
            }
            return energy
        }
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...solver.ex {
                        guard let n = solver.storedNode(i, j, k), solver.referencePosition(i, j, k).z > 2.55
                        else { continue }
                        nodes[n].velocity = SIMD3(0, 0, -1)
                    }
                }
            }
        }
        let start = (momentum: solver.momentum(), energy: kinetic())
        var highest = start.energy
        for _ in 0..<40 {
            solver.advance(steps: steps(solver, seconds: 0.001))
            highest = max(highest, kinetic())
        }
        let end = (momentum: solver.momentum(), energy: kinetic())
        #expect(simd_length(end.momentum - start.momentum) < 1e-5 * simd_length(start.momentum))
        // The blocks' own kinetic energy never passes what it started with, and they part.
        #expect(highest <= start.energy * 1.0001)
        let upper = mean(solver, above: 2.55) { $0.velocity }.z
        let lower = mean(solver, above: 0) { $0.velocity }.z
        #expect(upper > lower, "\(upper), \(lower)")
        #expect(end.energy < start.energy)
    }

    /// The upper block, seated with friction 0.5 on a lower block 1 m long, thrown along the joint
    /// at `speed`: how far it slides in 1.2 s, how far it drops, and the pairs at the end.
    private func thrown(at speed: Float) throws -> (slide: Float, drop: Float, summary: PartPairs.Summary) {
        let solver = try StructureSolver(device: device, model: seated(.resting(friction: 0.5)))
        // Falling off, it meets the lower block's side rather than passing through it.
        solver.contactMode = .always
        solver.damping = 200
        solver.advance(steps: steps(solver, seconds: 0.05))
        solver.damping = 0
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...solver.ex {
                        guard let n = solver.storedNode(i, j, k), solver.referencePosition(i, j, k).z > 0.55
                        else { continue }
                        nodes[n].velocity.x += speed
                    }
                }
            }
        }
        let before = mean(solver, above: 0.55) { $0.displacement }
        solver.advance(steps: steps(solver, seconds: 1.2))
        let after = mean(solver, above: 0.55) { $0.displacement }
        return (after.x - before.x, before.z - after.z, try #require(solver.pairSummary()))
    }

    @Test(
        "A block thrown along its seat slides μ g's distance and stays; thrown harder it slides off and drops"
    )
    func seat() throws {
        // Sliding a quarter metre, its kinetic energy goes into friction, μ W s.
        let speed = (2 * 0.5 * g * 0.25).squareRoot()
        let stays = try thrown(at: speed)
        #expect(abs(stays.slide - 0.25) < 0.025, "\(stays.slide)")
        #expect(stays.drop < 0.01, "\(stays.drop)")
        // Its pairs within a quarter metre (less half an element) of the far edge have gone past it.
        let fraction = Float(stays.summary.unseated) / Float(stays.summary.pairs)
        #expect(abs(fraction - 2.0 / 9) < 0.01, "\(fraction)")
        // Thrown to slide 1.5 m, it passes the edge and falls off.
        let falls = try thrown(at: (2 * 0.5 * g * 1.5).squareRoot())
        #expect(falls.summary.unseated == falls.summary.pairs)
        #expect(falls.drop > 0.3, "\(falls.drop)")
    }

    @Test("A precast beam on a 100 mm seat stays when its column is struck at 4 m/s and drops at 12 m/s")
    func droppedSpan() throws {
        let holds = try DroppedSpanStudy.run(device: device, seat: 0.1, speed: 4, duration: 1)
        #expect(holds.drop < 0.01 && holds.unseated < 1, "\(holds.drop), \(holds.unseated)")
        let drops = try DroppedSpanStudy.run(device: device, seat: 0.1, speed: 12, duration: 1)
        #expect(drops.peakSlide > 0.15 && drops.unseated == 1 && drops.drop > 1, "\(drops.drop)")
    }

    @Test("A joint between parts cannot be the ground's or stand on a footing")
    func validation() throws {
        var law = Anchorage.resting()
        law.betweenParts = true
        var body = StructureModel(solids: [Box(min: .zero, max: SIMD3(1, 1, 1))], elementSize: 0.25)
        body.baseAnchorage = law
        #expect(throws: ImportedMesh.ImportError.self) { try StructureSolver(device: device, model: body) }
        law.footing = Footing()
        #expect(throws: ImportedMesh.ImportError.self) { try law.validate() }
    }
}
