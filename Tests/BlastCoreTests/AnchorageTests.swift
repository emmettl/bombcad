import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// The base's connection to the ground (`Anchorage`) against statics: bearing, pull-off,
/// sliding at the friction limit and overturning about the toe.
@Suite("Anchorage")
struct AnchorageTests {
    let device: MTLDevice
    /// Stiff and elastic, so that the body's own deformation and cracking stay out of the way.
    let material = StructureMaterial.elastic(density: 2400, youngsModulus: 30e9, poissonRatio: 0.2)
    let g: Float = 9.81

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    private func block(
        _ size: SIMD3<Float>, anchorage: Anchorage?, elementSize: Float = 0.25
    ) throws -> StructureSolver {
        var model = StructureModel(
            solids: [Box(min: .zero, max: size)], material: material, elementSize: elementSize,
            fixedBase: true)
        model.baseAnchorage = anchorage
        return try StructureSolver(device: device, model: model)
    }

    private func steps(_ solver: StructureSolver, seconds: Double) -> Int {
        max(1, Int((seconds / Double(solver.criticalTimeStep)).rounded()))
    }

    /// Lets the body settle on its connection under gravity, with damping that is then removed.
    private func settle(_ solver: StructureSolver) {
        solver.damping = 500
        solver.advance(steps: steps(solver, seconds: 0.03))
        solver.damping = 0
    }

    /// The body's mean displacement.
    private func meanDisplacement(_ solver: StructureSolver) -> SIMD3<Float> {
        var total = SIMD3<Float>.zero
        var mass: Float = 0
        solver.mutateNodes { nodes in
            for node in nodes {
                total += node.mass * node.displacement
                mass += node.mass
            }
        }
        return total / mass
    }

    private func meanVelocity(_ solver: StructureSolver) -> SIMD3<Float> {
        var total = SIMD3<Float>.zero
        var mass: Float = 0
        solver.mutateNodes { nodes in
            for node in nodes {
                total += node.mass * node.velocity
                mass += node.mass
            }
        }
        return total / mass
    }

    @Test("A clamped base is unchanged, and a connected one is tied rather than clamped")
    func clampedOrTied() throws {
        let clamped = try block(SIMD3(1, 1, 1), anchorage: nil)
        let tied = try block(SIMD3(1, 1, 1), anchorage: .constructionJoint)
        var fixed = (0, 0)
        clamped.mutateNodes { fixed.0 = $0.filter(\.isFixed).count }
        tied.mutateNodes { fixed.1 = $0.filter(\.isFixed).count }
        #expect(fixed == (25, 0))
        #expect(clamped.anchorSummary() == nil)
        let summary = try #require(tied.anchorSummary())
        #expect(summary.nodes == 25)
        // As stiff as one more element: the time step is the clamped body's.
        #expect(tied.criticalTimeStep == clamped.criticalTimeStep)
        var stiff = Anchorage.constructionJoint
        stiff.normalStiffness = 100 * material.youngsModulus / 0.25
        let stiffer = try block(SIMD3(1, 1, 1), anchorage: stiff)
        #expect(stiffer.criticalTimeStep < 0.5 * clamped.criticalTimeStep)
    }

    @Test("A block resting on the ground bears its weight and stays put")
    func bearing() throws {
        let solver = try block(SIMD3(1, 1, 1), anchorage: .resting())
        settle(solver)
        solver.advance(steps: steps(solver, seconds: 0.02))
        let summary = try #require(solver.anchorSummary())
        let weight = material.density * 1 * g
        #expect(abs(summary.reaction.z - weight) / weight < 0.03)
        #expect(simd_length(summary.reaction - SIMD3(0, 0, summary.reaction.z)) < 0.01 * weight)
        #expect(simd_length(meanDisplacement(solver)) < 1e-5)
        let stiffer = try block(
            SIMD3(1, 1, 1),
            anchorage: {
                var a = Anchorage.resting()
                a.normalStiffness = 100 * material.youngsModulus / 0.25
                return a
            }())
        settle(stiffer)
        #expect(stiffer.summary().hasBlownUp == false)
        #expect(abs(stiffer.anchorSummary()!.reaction.z - weight) / weight < 0.03)
    }

    /// Pulls a 0.5 m block up from its bonded base by raising an upward body force slowly to
    /// `fraction` of what the joint's tensile strength holds, and returns the block's state.
    private func pull(
        to fraction: Float, anchorage: Anchorage = .constructionJoint
    ) throws -> (StructureSolver, StructureSolver.AnchorSummary) {
        let solver = try block(SIMD3(1, 1, 0.5), anchorage: anchorage, elementSize: 0.125)
        let strength = anchorage.tensileStrength
        let holding = strength / (material.density * 0.5)  // acceleration the joint holds
        let ramp = 40
        for n in 1...ramp {
            solver.gravity = -fraction * holding * Float(n) / Float(ramp)
            solver.advance(steps: steps(solver, seconds: 0.0005))
        }
        solver.advance(steps: steps(solver, seconds: 0.005))
        return (solver, try #require(solver.anchorSummary()))
    }

    @Test("A bonded joint holds a pull below its tensile strength and lets go above it")
    func pullOff() throws {
        let (held, below) = try pull(to: 0.8)
        #expect(below.separated == 0)
        #expect(below.maxOpening < 5e-5)
        let pulled = Anchorage.constructionJoint.tensileStrength * 0.8
        #expect(abs(below.reaction.z + pulled) / pulled < 0.05)
        #expect(meanVelocity(held).z < 0.01)

        let (_, above) = try pull(to: 1.3)
        #expect(above.separated == above.nodes)
        #expect(abs(above.reaction.z) < 1)
    }

    @Test("Starter bars hold their yield force as the joint opens, then let go")
    func dowelPlateau() throws {
        let bars = Anchorage.dowelled(ratio: 0.005, ductileOpening: 0.01)
        // Pulled past the bars' strength, the block lifts while they still hold it.
        let (solver, lifting) = try pull(to: 1.05, anchorage: bars)
        #expect(lifting.maxOpening > 1e-4 && lifting.maxOpening < 0.01)
        #expect(abs(lifting.reaction.z + bars.tensileStrength) / bars.tensileStrength < 0.05)
        #expect(lifting.separated == 0)
        // Past twice the plateau they are gone.
        while try #require(solver.anchorSummary()).maxOpening < 0.025 {
            solver.advance(steps: steps(solver, seconds: 0.002))
        }
        let broken = try #require(solver.anchorSummary())
        #expect(broken.separated == broken.nodes)
        #expect(abs(broken.reaction.z) < 1)
    }

    @Test("A freestanding wall's base decides whether a distant blast topples it")
    func wallStudy() throws {
        func run(_ base: BaseConnection) throws -> AnchorageStudy.Result {
            try AnchorageStudy.run(
                device: device, base: base, mass: 50, standoff: 25, duration: 0.3, elementSize: 0.125)
        }
        let clamped = try run(.clamped)
        let dowelled = try run(.dowelled)
        let resting = try run(.resting)
        // Starter bars keep the wall close to the clamped one; resting on the ground, it rocks
        // up and goes over.
        #expect(clamped.peakSway < 0.02)
        #expect(abs(dowelled.peakSway - clamped.peakSway) < 0.3 * clamped.peakSway)
        #expect(dowelled.separated == 0)
        #expect(resting.peakSway > 10 * clamped.peakSway)
        #expect(resting.finalSway == resting.peakSway)
    }

    @Test("A block resting on the ground slides once the push passes the friction")
    func sliding() throws {
        // 2 m square, 0.5 m high: it slides long before it could tip (at four times its weight).
        let friction: Float = 0.5
        let solver = try block(SIMD3(2, 2, 0.5), anchorage: .resting(friction: friction))
        settle(solver)
        let weight = material.density * 2 * 2 * 0.5 * g
        let face: Float = 2 * 0.5
        let start = Float(solver.time)
        // Ramp to 80% of the friction, hold, then step to 130% and hold.
        let low = 0.8 * friction * weight / face
        let high = 1.3 * friction * weight / face
        solver.appliedLoad = PressureLoad(
            axis: 0, positiveSide: false,
            history: [
                SIMD2(0, 0), SIMD2(start, 0), SIMD2(start + 0.02, low), SIMD2(start + 0.05, low),
                SIMD2(start + 0.052, high), SIMD2(start + 1, high),
            ])
        solver.advance(steps: steps(solver, seconds: 0.05))
        #expect(abs(meanDisplacement(solver).x) < 1e-4)
        #expect(abs(meanVelocity(solver).x) < 1e-3)

        // The friction force, averaged over the slide (its value at any instant rings with the
        // base's vertical modes), and the acceleration it leaves.
        let before = meanVelocity(solver).x
        let duration: Float = 0.1
        let samples = 50
        var reaction: Float = 0
        for _ in 0..<samples {
            solver.advance(steps: steps(solver, seconds: Double(duration) / Double(samples)))
            reaction -= try #require(solver.anchorSummary()).reaction.x / Float(samples)
        }
        let acceleration = (meanVelocity(solver).x - before) / duration
        let expected = 0.3 * friction * g
        #expect(abs(acceleration - expected) / expected < 0.1)
        #expect(abs(reaction - friction * weight) / (friction * weight) < 0.1)
    }

    /// A 2 m square, 0.25 m high block on a construction joint, pushed sideways by a pressure
    /// ramped over 20 ms to `fraction` of the joint's shear strength, c A + μ W, and held.
    private func shear(to fraction: Float) throws -> (StructureSolver.AnchorSummary, slide: Float) {
        let joint = Anchorage.constructionJoint
        let solver = try block(SIMD3(2, 2, 0.25), anchorage: joint, elementSize: 0.125)
        settle(solver)
        let weight = material.density * 2 * 2 * 0.25 * g
        let strength = joint.cohesion * 4 + joint.friction * weight
        let face: Float = 2 * 0.25
        let start = Float(solver.time)
        solver.appliedLoad = PressureLoad(
            axis: 0, positiveSide: false,
            history: [
                SIMD2(0, 0), SIMD2(start, 0), SIMD2(start + 0.02, fraction * strength / face),
                SIMD2(start + 1, fraction * strength / face),
            ])
        solver.advance(steps: steps(solver, seconds: 0.03))
        return (try #require(solver.anchorSummary()), meanDisplacement(solver).x)
    }

    @Test("A construction joint holds a shear below its cohesion and friction and slides above")
    func jointShear() throws {
        let (below, held) = try shear(to: 0.7)
        // Damage starts at the loaded edge, where the shear and the uplift gather, but holds.
        #expect(below.separated == 0)
        #expect(below.meanDamage < 0.15)
        #expect(held < 1e-4)
        let (above, slid) = try shear(to: 1.3)
        #expect(above.separated == above.nodes)
        #expect(slid > 0.01)
    }

    /// A block 0.5 m thick and 2 m tall, standing on its base with friction enough not to slide,
    /// pushed on its broad face by a pressure ramped over 50 ms to `fraction` of the one that
    /// tips it, then held: its uplift at the heel and its top's sway after 0.25 s.
    private func overturn(_ fraction: Float, anchorage: Anchorage?) throws -> (uplift: Float, sway: Float) {
        let solver = try block(SIMD3(Self.thickness, 1, Self.height), anchorage: anchorage)
        if anchorage != nil { settle(solver) }
        let start = Float(solver.time)
        solver.appliedLoad = PressureLoad(
            axis: 0, positiveSide: false,
            history: [
                SIMD2(0, 0), SIMD2(start, 0), SIMD2(start + 0.05, fraction * tippingPressure),
                SIMD2(start + 1, fraction * tippingPressure),
            ])
        solver.advance(steps: steps(solver, seconds: 0.25))
        var result: (Float, Float) = (0, 0)
        solver.mutateNodes { nodes in
            result = (nodes[solver.nodeIndex(0, 0, 0)].uz, nodes[solver.nodeIndex(0, 0, solver.ez)].ux)
        }
        return result
    }

    static let thickness: Float = 0.5
    static let height: Float = 2
    var weight: Float { material.density * Self.thickness * Self.height * g }
    /// The pressure whose moment about the toe matches the weight's: p H (H / 2) = W b / 2.
    var tippingPressure: Float { weight * Self.thickness / (Self.height * Self.height) }

    /// The same block as a rigid body rocking about its toe, under the same push: the uplift at
    /// its heel after 0.25 s.
    private func rigidUplift(_ fraction: Float) -> Float {
        let (b, h) = (Self.thickness, Self.height)
        let inertia = material.density * b * h * (b * b + h * h) / 3  // about the toe
        var (angle, rate): (Float, Float) = (0, 0)
        let dt: Float = 1e-5
        for n in 0..<25_000 {
            let t = Float(n) * dt
            let push = fraction * tippingPressure * h * min(t / 0.05, 1)
            // Moments about the toe, the push's arm shortened and the weight's by the tilt.
            let moment =
                push * (h / 2 * cos(angle) - b * sin(angle)) - weight
                * (b / 2 * cos(angle) - h / 2 * sin(angle))
            rate += dt * (angle > 0 || moment > 0 ? moment / inertia : 0)
            angle = max(angle + dt * rate, 0)
        }
        return b * sin(angle)
    }

    @Test("A block resting on the ground tips once the push's moment passes its weight's")
    func overturning() throws {
        let resting = Anchorage.resting(friction: 1)
        let below = try overturn(0.7, anchorage: resting)
        #expect(below.uplift < 1e-4 && below.sway < 1e-3)
        // Past the tipping push it rocks up as a rigid block would, within its elasticity.
        let above = try overturn(1.3, anchorage: resting)
        let rigid = rigidUplift(1.3)
        #expect(abs(above.uplift - rigid) / rigid < 0.15)
        #expect(above.sway > 3 * above.uplift)
        // Clamped, or cast on a bonded joint, the same block stands.
        #expect(try overturn(1.3, anchorage: nil).sway < 1e-3)
        let joint = try overturn(1.3, anchorage: .constructionJoint)
        #expect(joint.uplift < 1e-4 && joint.sway < 1e-3)
    }

    @Test("Connections are recognised by name")
    func connections() {
        for connection in BaseConnection.allCases {
            #expect(BaseConnection(connection.anchorage) == connection)
        }
        #expect(BaseConnection(.dowelled(ratio: 0.01)) == .dowelled)
        #expect(BaseConnection(.resting(friction: 0.3)) == .resting)
    }

    @Test("A model's anchorage is saved, and models saved without one still open")
    func persistence() throws {
        var model = StructureModel(solids: [Box(min: .zero, max: SIMD3(1, 1, 1))], elementSize: 0.25)
        model.baseAnchorage = .dowelled(ratio: 0.005)
        let data = try JSONEncoder().encode(model)
        #expect(try JSONDecoder().decode(StructureModel.self, from: data) == model)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["baseAnchorage"] = nil
        let old = try JSONDecoder().decode(
            StructureModel.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(old.baseAnchorage == nil)
        #expect(old.fixedBase)
    }
}
