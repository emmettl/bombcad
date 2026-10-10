import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Joints at angles to the lattice (`Anchorage.jointNormal`): a block on an inclined joint slides
/// at the friction angle, a staircase of faces is tied over the joint's own area, and a wall turned
/// against the lattice, with its joint and gravity, holds and tips as the upright one does.
@Suite("Inclined joints")
struct InclinedJointTests {
    let device: MTLDevice
    let material = StructureMaterial.elastic(density: 2400, youngsModulus: 30e9, poissonRatio: 0.2)
    let g: Float = 9.81

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    private func steps(_ solver: StructureSolver, seconds: Double) -> Int {
        max(1, Int((seconds / Double(solver.criticalTimeStep)).rounded()))
    }

    /// Brings gravity on over 20 ms, so as not to strike the joint.
    private func load(_ solver: StructureSolver) {
        for n in 1...20 {
            solver.gravity = g * Float(n) / 20
            solver.advance(steps: steps(solver, seconds: 0.001))
        }
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

    private func mass(_ solver: StructureSolver) -> Float {
        var mass: Float = 0
        solver.mutateNodes { nodes in mass = nodes.reduce(0) { $0 + $1.mass } }
        return mass
    }

    /// A 2 m by 1 m block 0.5 m deep, raised 2 m, its flat base tied by a joint at `angle` to the
    /// horizontal, falling towards +x, with `friction` and no cohesion: after 20 ms of rising
    /// gravity and `seconds` more, its mean velocity, the reaction, and the slope's directions.
    private func slope(angle: Float, friction: Float, seconds: Double = 0.15) throws -> (
        velocity: SIMD3<Float>, reaction: SIMD3<Float>, weight: Float, normal: SIMD3<Float>,
        down: SIMD3<Float>
    ) {
        var body = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 2), max: SIMD3(2, 1, 2.5))], material: material, elementSize: 0.25,
            fixedBase: false)
        body.supports = [Box(min: SIMD3(-0.01, -0.01, 1.99), max: SIMD3(2.01, 1.01, 2.01))]
        let normal = Anchorage.normal(tilt: angle, azimuth: .pi)
        body.supportAnchorages = [
            Anchorage(
                tensileStrength: 0, tensionOpening: 0, cohesion: 0, cohesionSlip: 0, friction: friction,
                jointNormal: normal)
        ]
        let solver = try StructureSolver(device: device, model: body)
        load(solver)
        solver.advance(steps: steps(solver, seconds: seconds))
        let summary = try #require(solver.anchorSummary())
        let down = SIMD3<Float>(cos(angle), 0, -sin(angle))
        return (mean(solver) { $0.velocity }, summary.reaction, mass(solver) * g, normal, down)
    }

    @Test("A block on a joint at 30° or 45° holds below the friction angle and slides above it")
    func frictionAngle() throws {
        for degrees in [Float(30), 45] {
            let angle = degrees * .pi / 180
            // μ a quarter above tan α: it holds, the joint bearing W cos α across and W sin α along.
            let held = try slope(angle: angle, friction: 1.25 * tan(angle))
            #expect(simd_length(held.velocity) < 2e-3, "\(degrees)°: \(held.velocity)")
            #expect(abs(simd_dot(held.reaction, held.normal) - held.weight * cos(angle)) < 0.03 * held.weight)
            #expect(abs(-simd_dot(held.reaction, held.down) - held.weight * sin(angle)) < 0.03 * held.weight)
            // A quarter below: it slides down the slope at g (sin α − μ cos α), without lifting off.
            let friction = 0.75 * tan(angle)
            let expected = g * (sin(angle) - friction * cos(angle))
            let early = try slope(angle: angle, friction: friction, seconds: 0.1)
            let late = try slope(angle: angle, friction: friction, seconds: 0.3)
            let acceleration = simd_dot(late.velocity - early.velocity, late.down) / 0.2
            #expect(
                abs(acceleration - expected) < 0.1 * expected,
                "\(degrees)°: \(acceleration) against \(expected)")
            #expect(abs(simd_dot(late.velocity, late.normal)) < 0.02 * simd_dot(late.velocity, late.down))
            // Sliding, the joint's force along it is μ times its force across.
            let across = simd_dot(late.reaction, late.normal)
            let along = simd_length(late.reaction - across * late.normal)
            #expect(abs(along - friction * across) < 0.05 * friction * across)
        }
    }

    /// A block whose underside is a staircase standing for a joint at 45° falling towards +x, eight
    /// steps of one 0.25 m element, tied over that joint by `law`: its mean displacement after
    /// 0.3 s, the bearing area, and the body's weight.
    private func staircase(_ law: Anchorage) throws -> (
        displacement: SIMD3<Float>, area: Float, weight: Float
    ) {
        let h: Float = 0.25
        let columns = (0..<8).map { i in
            Box(min: SIMD3(Float(i) * h, 0, 3 - Float(i) * h), max: SIMD3(Float(i + 1) * h, 1, 3.5))
        }
        var body = StructureModel(solids: columns, material: material, elementSize: h, fixedBase: false)
        body.supports = [Box(min: SIMD3(-0.01, -0.01, 1.24), max: SIMD3(2.01, 1.01, 3.01))]
        var law = law
        law.jointNormal = Anchorage.normal(tilt: .pi / 4, azimuth: .pi)
        body.supportAnchorages = [law]
        let solver = try StructureSolver(device: device, model: body)
        let area = solver.supportBearingArea(at: 0)
        load(solver)
        solver.advance(steps: steps(solver, seconds: 0.28))
        return (mean(solver) { $0.displacement }, area, mass(solver) * g)
    }

    @Test("A staircase standing for a joint at 45° is tied over the joint's area, and holds by its cohesion")
    func staircaseCohesion() throws {
        func law(_ cohesion: Float) -> Anchorage {
            Anchorage(
                tensileStrength: 1e6, tensionOpening: 1e-3, cohesion: cohesion, cohesionSlip: 1e-3,
                friction: 0)
        }
        // Each step's tread and riser, projected on the joint, are its length along it, h √2; the
        // top step's riser adds half an element's quarter faces along the box's edge.
        let probe = try staircase(law(1e6))
        let plane = 8 * 0.25 * Float(2).squareRoot()
        #expect(abs(probe.area - plane) < 0.04 * plane, "\(probe.area) against \(plane)")
        // Without friction, the joint holds the weight's share along it, W sin 45°, by c A alone.
        let along = probe.weight * sin(Float.pi / 4)
        let holds = try staircase(law(along / (0.7 * probe.area)))
        let slides = try staircase(law(along / (1.3 * probe.area)))
        #expect(simd_length(holds.displacement) < 1e-3, "\(holds.displacement)")
        #expect(slides.displacement.x > 0.05 && slides.displacement.z < -0.05, "\(slides.displacement)")
    }

    /// The axis-aligned turn of `local` by `angle` about y: x across the wall, z up it.
    private func turned(_ local: SIMD3<Float>, by angle: Float) -> SIMD3<Float> {
        SIMD3(
            local.x * cos(angle) + local.z * sin(angle), local.y, -local.x * sin(angle) + local.z * cos(angle)
        )
    }

    /// A wall 0.5 m thick and 1.5 m high, a 1 m strip on 0.125 m elements, resting with friction 0.8
    /// on a joint at its base and pulled by gravity turned towards its +x face, a steady push of
    /// `push` times what tips it as meshed; the wall, its joint and gravity all turned by `angle`
    /// about y against the lattice. Returns the mean displacement across the wall after 0.6 s; the
    /// joint's reaction across and along its base, in the wall's own frame, after 0.2 s; the
    /// weight; and the push, as a share of the weight across the base, that tips the meshed wall.
    private func wall(turnedBy angle: Float, push: Float) throws -> (
        sway: Float, across: Float, along: Float, weight: Float, tipping: Float
    ) {
        let (b, height, h): (Float, Float, Float) = (0.5, 1.5, 0.125)
        let base = SIMD3<Float>(0.5, 0, 3)
        // The cells whose centres lie inside the turned wall, as one box per column of them.
        var columns: [Box] = []
        for i in -8..<24 {
            let x = (Float(i) + 0.5) * h
            var low: Float?
            var high: Float = 0
            for k in 0..<40 {
                let local = turned(SIMD3(x, 0, (Float(k) + 0.5) * h) - base, by: -angle)
                guard local.x >= 0 && local.x <= b && local.z >= 0 && local.z <= height else { continue }
                if low == nil { low = Float(k) * h }
                high = Float(k + 1) * h
            }
            if let low {
                columns.append(Box(min: SIMD3(Float(i) * h, 0, low), max: SIMD3(Float(i + 1) * h, 1, high)))
            }
        }
        var body = StructureModel(solids: columns, material: material, elementSize: h, fixedBase: false)
        // The nodes within about half an element of the base, across its whole width.
        let ends = [turned(SIMD3(0, 0, 0), by: angle), turned(SIMD3(b, 0, 0), by: angle)].map { $0 + base }
        body.supports = [
            Box(
                min: SIMD3(min(ends[0].x, ends[1].x) - 0.6 * h, -0.01, min(ends[0].z, ends[1].z) - 0.6 * h),
                max: SIMD3(max(ends[0].x, ends[1].x) + 0.6 * h, 1.01, max(ends[0].z, ends[1].z) + 0.6 * h))
        ]
        let normal = turned(SIMD3(0, 0, 1), by: angle)
        body.supportAnchorages = [
            Anchorage(
                tensileStrength: 0, tensionOpening: 0, cohesion: 0, cohesionSlip: 0, friction: 0.8,
                jointNormal: normal)
        ]
        let solver = try StructureSolver(device: device, model: body)
        // The meshed wall tips about its outermost tied node once the push's moment about it passes
        // the weight's: a staircase's corners stand out of the turned wall by up to h / √2.
        let toe = try #require(
            solver.tiedPoints().map { turned($0.position - base, by: -angle) }.max { $0.x < $1.x })
        var centre = SIMD3<Float>.zero
        solver.mutateNodes { nodes in
            let total = nodes.reduce(0) { $0 + $1.mass }
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...solver.ex {
                        guard let n = solver.storedNode(i, j, k) else { continue }
                        centre += nodes[n].mass / total * solver.referencePosition(i, j, k)
                    }
                }
            }
        }
        let local = turned(centre - base, by: -angle)
        let tipping = (toe.x - local.x) / (local.z - toe.z)
        let tilt = atan(push * tipping)
        solver.gravityDirection = turned(SIMD3(sin(tilt), 0, -cos(tilt)), by: angle)
        load(solver)
        solver.advance(steps: steps(solver, seconds: 0.18))
        let summary = try #require(solver.anchorSummary())
        let acrossBase = turned(SIMD3(1, 0, 0), by: angle)
        let weight = mass(solver) * g
        let across = simd_dot(summary.reaction, normal) / cos(tilt)
        let along = -simd_dot(summary.reaction, acrossBase) / sin(tilt)
        solver.advance(steps: steps(solver, seconds: 0.4))
        let sway = simd_dot(mean(solver) { $0.displacement }, acrossBase)
        return (sway, across, along, weight, tipping)
    }

    @Test(
        "A wall turned 30° or 45° against the lattice, with its joint and gravity, holds and tips as the upright one"
    )
    func turnedWall() throws {
        for angle in [Float(0), 30 * .pi / 180, 45 * .pi / 180] {
            let holds = try wall(turnedBy: angle, push: 0.8)
            let tips = try wall(turnedBy: angle, push: 1.2)
            #expect(abs(holds.sway) < 2e-3, "\(angle): \(holds.sway)")
            #expect(tips.sway > 0.05, "\(angle): \(tips.sway)")
            // Holding, the joint bears the weight's share across it and resists its share along.
            #expect(abs(holds.across - holds.weight) < 0.03 * holds.weight, "\(angle): \(holds.across)")
            #expect(abs(holds.along - holds.weight) < 0.03 * holds.weight, "\(angle): \(holds.along)")
            // b / H upright; the staircase's corners widen the base by up to 30%.
            #expect(abs(holds.tipping - 1.0 / 3) < (angle == 0 ? 1e-4 : 0.1), "\(angle): \(holds.tipping)")
        }
    }

    @Test("A joint's normal along an axis is the side it names, to the bit")
    func normalMatchesSide() throws {
        for side in [JointSide.negativeX, .positiveY, .above] {
            func run(_ law: Anchorage) throws -> (SIMD3<Float>, Float) {
                var body = StructureModel(
                    solids: [Box(min: SIMD3(0, 0, 2), max: SIMD3(1, 1, 3))], material: material,
                    elementSize: 0.25,
                    fixedBase: false)
                var face = Box(min: SIMD3(-0.01, -0.01, 1.99), max: SIMD3(1.01, 1.01, 3.01))
                face.min[side.axis] = side.direction < 0 ? face.min[side.axis] : face.max[side.axis] - 0.02
                face.max[side.axis] = face.min[side.axis] + 0.02
                body.supports = [face]
                body.supportAnchorages = [law]
                let solver = try StructureSolver(device: device, model: body)
                load(solver)
                solver.advance(steps: 200)
                return (mean(solver) { $0.displacement }, solver.supportBearingArea(at: 0))
            }
            var bySide = Anchorage.constructionJoint
            bySide.side = side
            var byNormal = Anchorage.constructionJoint
            byNormal.jointNormal = 2 * side.normal
            let (a, b) = (try run(bySide), try run(byNormal))
            #expect(a.0 == b.0 && a.1 == b.1, "\(side)")
        }
        // The angles name the sides.
        #expect(
            simd_distance(Anchorage.normal(tilt: .pi / 2, azimuth: .pi), JointSide.negativeX.normal) < 1e-6)
        #expect(
            simd_distance(Anchorage.normal(tilt: .pi / 2, azimuth: .pi / 2), JointSide.positiveY.normal)
                < 1e-6)
        #expect(simd_distance(Anchorage.normal(tilt: .pi, azimuth: 0), JointSide.above.normal) < 1e-6)
        var zero = Anchorage.resting()
        zero.jointNormal = .zero
        #expect(throws: ImportedMesh.ImportError.self) { try zero.validate() }
    }
}
