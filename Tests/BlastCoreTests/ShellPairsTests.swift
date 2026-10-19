import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

@Suite("Connections between two parts of a shell body", .gpuThreads)
struct ShellPairsTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
    }

    /// Ties smeared over a joint: 3 kPa of tension held to 10 mm and gone at 50 mm, buckling at
    /// 1.5 kPa until the 50 mm gap has closed.
    static let ties: Anchorage = {
        var law = Anchorage(
            normalStiffness: 1e6, shearStiffness: 1e6, tensileStrength: 3e3, tensionPlateau: 0.01,
            tensionOpening: 0.05, cohesion: 0, cohesionSlip: 0, friction: 0, bearingCapacity: 1.5e3,
            jointNormal: SIMD3(1, 0, 0), betweenParts: true)
        law.closingGap = 0.05
        return law
    }()

    /// Two walls 1 m square and 100 mm thick, 50 mm apart, tied across the gap by `law` over the
    /// second's face of 1 m^2; the first held still. Returns the solver and the second's nodes.
    private func walls(_ law: Anchorage) throws -> (ShellSolver, [Int]) {
        var model = StructureModel(
            solids: [
                Box(min: SIMD3(0, 0, 1), max: SIMD3(0.1, 1, 2)),
                Box(min: SIMD3(0.15, 0, 1), max: SIMD3(0.25, 1, 2)),
            ],
            material: .masonry, elementSize: 0.25, fixedBase: false)
        model.elementKind = .shell
        model.supports = [
            Box(min: SIMD3(-0.01, -0.01, 0.99), max: SIMD3(0.11, 1.01, 2.01)),
            Box(min: SIMD3(-0.01, -0.01, 0.99), max: SIMD3(0.26, 1.01, 2.01)),
        ]
        model.setAnchorage(law, ofSupport: 1)
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        return (solver, solver.nodes { $0.x > 0.15 })
    }

    /// Drives `nodes` at `velocity` for `time` seconds.
    private func drive(_ solver: ShellSolver, _ nodes: [Int], at velocity: SIMD3<Float>, for time: Double) {
        solver.mutateNodes { all in
            for n in nodes {
                (all[n].vx, all[n].vy, all[n].vz) = (velocity.x, velocity.y, velocity.z)
                all[n].flags |= 8  // moves as set
            }
        }
        solver.advance(steps: Int((time / Double(solver.criticalTimeStep)).rounded()))
    }

    @Test("Ties pulled apart hold their strength over the plateau, then lose it to the final opening")
    func pulled() throws {
        let (solver, moving) = try walls(Self.ties)
        drive(solver, moving, at: SIMD3(0.2, 0, 0), for: 0.025)
        let held = try #require(solver.pairSummary())
        #expect(held.pairs == 25)
        #expect(abs(held.force.x + 3e3) < 30, "force at 5 mm \(held.force)")
        drive(solver, moving, at: SIMD3(0.2, 0, 0), for: 0.125)
        let softened = try #require(solver.pairSummary())
        #expect(abs(softened.maxOpening - 0.03) < 1e-3)
        #expect(abs(softened.force.x + 1.5e3) < 30, "force at 30 mm \(softened.force)")
    }

    @Test("Ties pushed together buckle at their strength until the gap has closed, then the walls bear")
    func closed() throws {
        let (solver, moving) = try walls(Self.ties)
        drive(solver, moving, at: SIMD3(-0.2, 0, 0), for: 0.1)
        let buckled = try #require(solver.pairSummary())
        #expect(abs(buckled.force.x - 1.5e3) < 30, "force at 20 mm closed \(buckled.force)")
        drive(solver, moving, at: SIMD3(-0.2, 0, 0), for: 0.16)
        let bearing = try #require(solver.pairSummary())
        #expect(bearing.force.x > 1e6, "force 2 mm past closing \(bearing.force)")
    }

    @Test("A node slid half an element past the region is off its seat for good")
    func unseated() throws {
        let (solver, moving) = try walls(Self.ties)
        drive(solver, moving, at: SIMD3(0, 1, 0), for: 0.2)
        let slid = try #require(solver.pairSummary())
        // Only the edge at y = 1 m has slid past 1.01 m and half an element.
        #expect(slid.unseated == 5)
        #expect(slid.pairs == 25)
    }
}
