import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Footings set into the soil (`Embedment`, `FootingSides`) against the standard embedment
/// factors: Gazetas's for static stiffness, Brinch Hansen's for bearing, Rankine's passive and
/// active pressures for sliding.
@Suite("Embedded footings")
struct EmbedmentTests {
    let device: MTLDevice
    let material = StructureMaterial.elastic(density: 2400, youngsModulus: 30e9, poissonRatio: 0.2)
    let g: Float = 9.81

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    private func block(_ size: SIMD3<Float>, footing: Footing) throws -> StructureSolver {
        var model = StructureModel(
            solids: [Box(min: .zero, max: size)], material: material, elementSize: 0.25, fixedBase: true)
        var joint = Anchorage.dowelled(ratio: BaseConnection.dowelRatio)
        joint.footing = footing
        model.baseAnchorage = joint
        return try StructureSolver(device: device, model: model)
    }

    private func steps(_ solver: StructureSolver, seconds: Double) -> Int {
        max(1, Int((seconds / Double(solver.criticalTimeStep)).rounded()))
    }

    private func bodyMass(_ solver: StructureSolver) -> Float {
        var mass: Float = 0
        solver.mutateNodes { mass = $0.reduce(0) { $0 + $1.mass } }
        return mass
    }

    /// The embedded footing's bed and sides, and Gazetas's surface stiffness for it.
    private func parts(width: Float, length: Float, thickness: Float, soil: Soil, embedment: Embedment) -> (
        bed: FootingBed, sides: FootingSides, surface: [Float]
    ) {
        let bed = FootingBed(
            width: width, length: length, soil: soil, embedment: embedment, thickness: thickness)
        let sides = FootingSides(
            width: width, length: length, thickness: thickness, soil: soil, embedment: embedment,
            base: bed.stiffness)
        let surface = FootingBed(width: width, length: length, soil: soil).stiffness
        return (bed, sides, surface)
    }

    @Test("Base and sides give Gazetas's embedded stiffness vertically and horizontally; rocking follows")
    func stiffness() {
        let soil = Soil(cyclic: nil)
        for (width, length, thickness, depth) in [
            (Float(2), Float(2), Float(1), Float(1)), (2, 2, 0.5, 1), (1.5, 4, 0.8, 0.8),
        ] {
            let embedment = Embedment(depth: depth)
            let (bed, sides, surface) = parts(
                width: width, length: length, thickness: thickness, soil: soil, embedment: embedment)
            let total = zip(bed.stiffness, sides.stiffness).map { $0 + $1 }
            for mode in 0..<3 {
                #expect(
                    abs(total[mode] / sides.target[mode] - 1) < 0.01,
                    "\(mode): \(total[mode]) against \(sides.target[mode])")
                #expect(total[mode] > surface[mode])
            }
            // Rocking: the sides' springs give a fifth to two fifths of what Gazetas says
            // embedment adds, and a spring on the footing the rest.
            for mode in 3..<5 {
                let gain = (total[mode] - surface[mode]) / (sides.target[mode] - surface[mode])
                #expect(gain > 0.15 && gain < 0.45, "\(mode): \(gain)")
                let remainder = mode == 3 ? sides.rocking.x : sides.rocking.y
                #expect(abs((total[mode] + remainder) / sides.target[mode] - 1) < 1e-4)
            }
        }
        // Gazetas's factors for a square 2 m footing 1 m deep, its sides in contact all the way:
        // vertically [1 + (D / 21 B)(1 + 1.3 χ)] [1 + 0.2 (A_w / A_b)^(2/3)] = 1.105 × 1.317.
        let factors = Embedment(depth: 1).gazetasFactors(width: 2, length: 2, thickness: 1)
        #expect(abs(factors.trench[0] - (1 + 1.0 / 21 * 2.3)) < 1e-4)
        #expect(abs(factors.sidewall[0] - (1 + 0.2 * pow(Float(2), 2.0 / 3))) < 1e-4)
    }

    @Test("Hansen's bearing capacity: the overburden's γ D N_q s_q d_q on the surface footing's")
    func bearingFactors() {
        // φ = 35°: N_q = 33.3 (tables give 33.30); s_q = 1 + tan φ for a square; d_q at D / B = 0.5,
        // 1 + 2 tan φ (1 − sin φ)² 0.5 = 1.127.
        let embedment = Embedment(depth: 1)
        let material = SoilMaterial.mediumDenseSand
        let q = embedment.bearingCapacity(surface: 600e3, width: 2, length: 2, material: material)
        let phi: Float = 35 * .pi / 180
        let expected = 600e3 + 1900 * 9.81 * 1 * 33.30 * (1 + tan(phi)) * 1.127
        #expect(abs(q / expected - 1) < 0.005, "\(q) against \(expected)")
        #expect(abs(embedment.passive - 3.690) < 0.001 && abs(embedment.active - 0.271) < 0.001)
        #expect(abs(embedment.atRest - 0.426) < 0.001)
    }

    @Test("A block on an embedded footing settles under its weight as Gazetas's embedded stiffness says")
    func settlement() throws {
        // Sides that grip without slipping: at this depth sand's friction on its pressure at rest
        // would let them slip under the weight, and the static stiffness is for small motions.
        let soil = Soil(bearingCapacity: nil, cyclic: nil)
        let embedment = Embedment(depth: 0.5, sideFriction: 10)
        let footing = Footing(overhang: SIMD2(0.5, 0.5), thickness: 0.5, soil: soil, embedment: embedment)
        let solver = try block(SIMD3(1, 1, 1), footing: footing)
        solver.damping = 200
        solver.advance(steps: steps(solver, seconds: 0.3))
        let summary = try #require(solver.footingSummaries().first)
        let weight = (bodyMass(solver) + summary.mass) * g
        let (bed, sides, _) = parts(width: 2, length: 2, thickness: 0.5, soil: soil, embedment: embedment)
        let expected = -weight / (bed.stiffness[0] + sides.stiffness[0])
        #expect(
            abs(summary.displacement.z - expected) / abs(expected) < 0.03,
            "\(summary.displacement.z) m against \(expected) m")
        // The sides carry their share of the weight.
        #expect(abs(summary.sideForce.z / weight - sides.stiffness[0] / sides.target[0]) < 0.03)
    }

    @Test(
        "Pushed a little sideways, an embedded footing slides and turns as its stiffnesses about the base say"
    )
    func sway() throws {
        let soil = Soil(bearingCapacity: nil, cyclic: nil)
        let embedment = Embedment(depth: 1, sideFriction: 10)
        let footing = Footing(overhang: SIMD2(0.5, 0.5), thickness: 0.5, soil: soil, embedment: embedment)
        let solver = try block(SIMD3(1, 1, 1), footing: footing)
        solver.damping = 200
        solver.advance(steps: steps(solver, seconds: 0.3))
        let before = try #require(solver.footingSummaries().first)
        let push: Float = 1000
        let start = Float(solver.time)
        solver.appliedLoad = PressureLoad(
            axis: 0, positiveSide: false,
            history: [SIMD2(0, 0), SIMD2(start, 0), SIMD2(start + 0.05, push), SIMD2(start + 10, push)])
        solver.advance(steps: steps(solver, seconds: 0.4))
        let after = try #require(solver.footingSummaries().first)
        // [K_hh K_hr; K_hr K_rr] [u; θ] = [H; H a], a the push's height over the base centre:
        // the footing's 0.5 m and half the block's 1 m face.
        let (bed, sides, _) = parts(width: 2, length: 2, thickness: 0.5, soil: soil, embedment: embedment)
        let hh = Double(bed.stiffness[1] + sides.stiffness[1])
        let rr = Double(bed.stiffness[4] + sides.stiffness[4] + sides.rocking.y)
        let hr = Double(sides.coupling.x)
        let arm = 1.0
        let determinant = hh * rr - hr * hr
        let u = (rr * Double(push) - hr * Double(push) * arm) / determinant
        let theta = (hh * Double(push) * arm - hr * Double(push)) / determinant
        let moved = Double(after.displacement.x - before.displacement.x)
        let turned = Double(after.rotation.y - before.rotation.y)
        #expect(abs(moved / u - 1) < 0.05, "\(moved) m against \(u)")
        #expect(abs(turned / theta - 1) < 0.05, "\(turned) rad against \(theta)")
    }

    @Test("Pressed past the embedded bearing capacity a footing sinks; below it, it holds")
    func bearing() throws {
        let soil = Soil(bearingCapacity: 300e3, radiationDamping: false, cyclic: nil)
        let embedment = Embedment(depth: 0.5)
        let footing = Footing(overhang: SIMD2(0.5, 0.5), thickness: 0.5, soil: soil, embedment: embedment)
        let capacity =
            embedment.bearingCapacity(surface: 300e3, width: 2, length: 2, material: soil.material) * 4
        func sink(_ fraction: Float) throws -> Float {
            let solver = try block(SIMD3(1, 1, 1), footing: footing)
            // The block sinks with its footing below the ground's surface.
            solver.groundContact = false
            let weight = (bodyMass(solver) + solver.footingSummaries()[0].mass) * g
            solver.damping = 100
            // Gravity raised slowly until the weight is `fraction` of the capacity.
            for n in 1...20 {
                solver.gravity = g * fraction * capacity / weight * Float(n) / 20
                solver.advance(steps: steps(solver, seconds: 0.01))
            }
            solver.advance(steps: steps(solver, seconds: 0.3))
            let before = solver.footingSummaries()[0].displacement.z
            solver.advance(steps: steps(solver, seconds: 0.2))
            return before - solver.footingSummaries()[0].displacement.z
        }
        let holds = try sink(0.8)
        let sinks = try sink(1.2)
        #expect(holds < 2e-3, "\(holds)")
        #expect(sinks > 0.05, "\(sinks)")
    }

    /// A 1 m block on an embedded footing 2 m square and 0.5 m deep, set `depth` into the sand
    /// (or on the surface), pushed on its face by `push` newtons: how far the footing has slid
    /// after 0.4 s.
    private func slide(push: Float, depth: Float?) throws -> Float {
        let soil = Soil(bearingCapacity: nil, friction: 0.5, cyclic: nil)
        let footing = Footing(
            overhang: SIMD2(0.5, 0.5), thickness: 0.5, soil: soil,
            embedment: depth.map { Embedment(depth: $0) })
        let solver = try block(SIMD3(1, 1, 0.5), footing: footing)
        solver.damping = 200
        solver.advance(steps: steps(solver, seconds: 0.1))
        solver.damping = 0
        let start = Float(solver.time)
        solver.appliedLoad = PressureLoad(
            axis: 0, positiveSide: false,
            history: [
                SIMD2(0, 0), SIMD2(start, 0), SIMD2(start + 0.05, push / 0.5), SIMD2(start + 10, push / 0.5),
            ])
        let before = solver.footingSummaries()[0].displacement.x
        solver.advance(steps: steps(solver, seconds: 0.4))
        return solver.footingSummaries()[0].displacement.x - before
    }

    @Test(
        "Pushed sideways, an embedded footing holds below its base friction plus the passive pressure, and slides above"
    )
    func passive() throws {
        // The resistance: the base's friction, the passive pressure less the active across the
        // faces facing the push, (Kₚ − Kₐ) γ D² / 2 a metre of face, and the sides' friction on
        // the pressure at rest along the push.
        let embedment = Embedment(depth: 0.5)
        let gamma: Float = 1900 * 9.81
        let solver = try block(
            SIMD3(1, 1, 0.5), footing: Footing(thickness: 0.5, soil: Soil(friction: 0.5, cyclic: nil)))
        let weight = (bodyMass(solver) + solver.footingSummaries()[0].mass) * g
        let pressure = gamma * 0.5 * 0.5 / 2
        let resistance =
            0.5 * weight + (embedment.passive - embedment.active) * pressure * 2
            + 2 * embedment.wallFriction * embedment.atRest * pressure * 2
        #expect(try slide(push: 0.8 * resistance, depth: 0.5) < 0.005)
        #expect(try slide(push: 1.2 * resistance, depth: 0.5) > 0.05)
        // On the surface the base's friction alone holds, and a push it holds embedded slides it.
        #expect(try slide(push: 0.8 * resistance, depth: nil) > 0.05)
    }
}
