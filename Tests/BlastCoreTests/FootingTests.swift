import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Rigid footings on soil (`Footing`, `FootingBed`) against theory: the half-space's static
/// stiffness, and a footing's heel lifting and its toe bearing.
@Suite("Footings")
struct FootingTests {
    let device: MTLDevice
    /// Stiff and elastic, so that the body's own deformation stays out of the way.
    let material = StructureMaterial.elastic(density: 2400, youngsModulus: 30e9, poissonRatio: 0.2)
    let g: Float = 9.81

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// A block `size` standing on a footing on `soil`, cast onto it with starter bars.
    private func block(
        _ size: SIMD3<Float>, footing: Footing, elementSize: Float = 0.25
    ) throws -> StructureSolver {
        var model = StructureModel(
            solids: [Box(min: .zero, max: size)], material: material, elementSize: elementSize,
            fixedBase: true)
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

    @Test("A block on a footing settles under its weight as the half-space's stiffness says")
    func settlement() throws {
        let footing = Footing(overhang: SIMD2(0.25, 0.25), thickness: 0.5, soil: Soil(bearingCapacity: nil))
        let solver = try block(SIMD3(1, 1, 1), footing: footing)
        let summary0 = try #require(solver.footingSummaries().first)
        #expect(abs(summary0.size.x - 1.5) < 1e-4 && abs(summary0.size.y - 1.5) < 1e-4)
        solver.damping = 200
        solver.advance(steps: steps(solver, seconds: 0.3))
        let summary = try #require(solver.footingSummaries().first)
        let weight = (bodyMass(solver) + summary.mass) * g
        let bed = FootingBed(width: 1.5, length: 1.5, soil: footing.soil)
        let expected = -weight / bed.stiffness[0]
        #expect(
            abs(summary.displacement.z - expected) / abs(expected) < 0.03,
            "\(summary.displacement.z) m against \(expected) m")
        #expect(abs(summary.soilForce.z - weight) / weight < 0.02)
        #expect(summary.bearing > 0.99)
    }

    // MARK: - The bed

    @Test("Gazetas's stiffnesses match the rigid disk's for a square, and the bed gives them")
    func bedStiffness() {
        let soil = Soil()
        let g = soil.material.shearModulus
        let nu = soil.material.poissonRatio
        // A unit square and the disk of its area (translation) or second moment (rocking).
        let square = FootingImpedance.gazetas(width: 1, length: 1, material: soil.material)
        let r = (1 / Float.pi).squareRoot()
        let rr = (1 / (3 * Float.pi)).squareRoot().squareRoot()
        #expect(abs(square[0] / (4 * g * r / (1 - nu)) - 1) < 0.02)
        #expect(abs(square[1] / (8 * g * r / (2 - nu)) - 1) < 0.02)
        #expect(abs(square[3] / (8 * g * rr * rr * rr / (3 * (1 - nu))) - 1) < 0.1)
        // The bed turns about both axes as stiffly as the half-space; under a square footing it
        // is as stiff vertically too, and under a long one stiffer, as its edges can only carry
        // so much.
        for (width, length) in [(Float(1.5), Float(1.5)), (1.25, 2.5), (1.25, 12)] {
            let bed = FootingBed(width: width, length: length, soil: soil)
            let target = FootingImpedance.gazetas(width: width, length: length, material: soil.material)
            for mode in [3, 4] {
                #expect(
                    abs(bed.stiffness[mode] / target[mode] - 1) < 0.01,
                    "rocking \(mode), \(width) x \(length): \(bed.stiffness[mode] / target[mode])")
            }
            let vertical = bed.stiffness[0] / target[0]
            #expect(vertical > 0.99 && vertical < (width == length ? 1.01 : 1.7), "vertical \(vertical)")
            #expect(bed.points.allSatisfy { $0.vertical > 0 })
            let area = bed.points.reduce(0) { $0 + $1.area }
            #expect(abs(area - width * length) < 1e-3)
            #expect(abs(bed.stiffness[1] / target[1] - 1) < 1e-3)
        }
    }

    /// The tensionless bed's own statics, as a rigid plate on its springs: the rotation about y
    /// and the bearing range of x under a weight `weight` and a moment `moment` about y.
    private func plate(on bed: FootingBed, weight: Float, moment: Float) -> (
        rotation: Float, contact: ClosedRange<Float>
    ) {
        var w: Double = -Double(weight / bed.stiffness[0])
        var theta: Double = 0
        for _ in 0..<200 {
            var force = 0.0
            var turn = 0.0
            var j = [[0.0, 0.0], [0.0, 0.0]]
            for p in bed.points {
                let z = w - theta * Double(p.place.x)
                guard z < 0 else { continue }
                let k = Double(p.vertical)
                let x = Double(p.place.x)
                force += -k * z
                turn += -k * z * x
                j[0][0] += -k
                j[0][1] += k * x
                j[1][0] += -k * x
                j[1][1] += k * x * x
            }
            let r = [force - Double(weight), turn - Double(moment)]
            let det = j[0][0] * j[1][1] - j[0][1] * j[1][0]
            guard abs(det) > 0 else { break }
            w -= (r[0] * j[1][1] - r[1] * j[0][1]) / det
            theta -= (j[0][0] * r[1] - j[1][0] * r[0]) / det
        }
        let bearing = bed.points.filter { Double($0.place.x) * -theta + w < -1e-12 }.map(\.place.x)
        return (Float(theta), (bearing.min() ?? 0)...(bearing.max() ?? 0))
    }

    @Test(
        "A footing turns under a moment as its bed says; past the kern its heel lifts and its contact shifts to the toe"
    )
    func rockingAndUplift() throws {
        // Rough enough not to slide under the push.
        let footing = Footing(
            overhang: SIMD2(0.25, 0.25), thickness: 0.5, soil: Soil(bearingCapacity: nil, friction: 1.2))
        let bed = FootingBed(width: 1.5, length: 1.5, soil: footing.soil)
        for eccentricity: Float in [0.1, 0.25, 0.4] {
            let solver = try block(SIMD3(1, 1, 1), footing: footing)
            let weight = (bodyMass(solver) + solver.footingSummaries()[0].mass) * g
            // A push on the block's face at its mid-height, 1 m above the footing's base.
            let moment = eccentricity * 1.5 * weight
            let start = Float(solver.time)
            solver.appliedLoad = PressureLoad(
                axis: 0, positiveSide: false,
                history: [
                    SIMD2(0, 0), SIMD2(start, 0), SIMD2(start + 0.1, moment), SIMD2(start + 10, moment),
                ])
            solver.damping = 100
            solver.advance(steps: steps(solver, seconds: 1))
            let summary = try #require(solver.footingSummaries().first)
            #expect(
                abs(summary.soilMoment.y + moment) < 0.01 * moment,
                "\(summary.soilMoment.y) against \(moment)")
            let expected = plate(on: bed, weight: weight, moment: moment)
            #expect(
                abs(summary.rotation.y - expected.rotation) / expected.rotation < 0.05,
                "e = \(eccentricity) B: \(summary.rotation.y) rad against \(expected.rotation)")
            let spacing = 1.5 / Float(FootingBed.pointsAcross - 1)
            #expect(abs(summary.contact.x - expected.contact.lowerBound) < 1.01 * spacing)
            #expect(abs(summary.contact.y - expected.contact.upperBound) < 1e-3)
            if expected.contact.lowerBound > -0.7 {
                #expect(summary.uplift > 0 && summary.contact.x > -0.7, "the heel lifts: \(summary.uplift)")
            } else {
                #expect(summary.bearing > 0.99)
            }
        }
    }

    /// The calls the overturning test makes of a wall of solid elements or of shells.
    private struct Wall {
        var step: Double
        var time: () -> Double
        var advance: (Int) -> Void
        var setDamping: (Float) -> Void
        var setLoad: (PressureLoad) -> Void
        var sway: () -> Float
        var mass: Float
        var footings: () -> [FootingSummary]
    }

    private func wall(_ size: SIMD3<Float>, footing: Footing, shells: Bool) throws -> Wall {
        var model = StructureModel(
            solids: [Box(min: .zero, max: size)], material: material, elementSize: 0.25, fixedBase: true)
        var joint = Anchorage.dowelled(ratio: BaseConnection.dowelRatio)
        joint.footing = footing
        model.baseAnchorage = joint
        if shells {
            model.elementKind = .shell
            let solver = try ShellSolver(device: device, model: model)
            let top = solver.nearestNode(to: SIMD3(size.x / 2, size.y / 2, size.z))
            var mass: Float = 0
            solver.mutateNodes { mass = $0.reduce(0) { $0 + $1.mass } }
            return Wall(
                step: Double(solver.criticalTimeStep), time: { solver.time }, advance: solver.advance(steps:),
                setDamping: { solver.damping = $0 }, setLoad: { solver.appliedLoad = $0 },
                sway: { solver.node(top).ux }, mass: mass, footings: solver.footingSummaries)
        }
        let solver = try StructureSolver(device: device, model: model)
        return Wall(
            step: Double(solver.criticalTimeStep), time: { solver.time }, advance: solver.advance(steps:),
            setDamping: { solver.damping = $0 }, setLoad: { solver.appliedLoad = $0 },
            sway: {
                var value: Float = 0
                solver.mutateNodes { value = $0[solver.nodeIndex(0, 0, solver.ez)].ux }
                return value
            }, mass: bodyMass(solver), footings: solver.footingSummaries)
    }

    @Test(
        "A wall on a footing tips about the footing's toe, M = W B / 2, not its own; of solids or shells",
        arguments: [false, true])
    func overturning(shells: Bool) throws {
        // A 3 m wall 250 mm thick on a footing 1.25 m wide on stiff soil, a 1 m strip of it.
        let (height, thickness): (Float, Float) = (3, 0.25)
        let size = SIMD3(thickness, 1, height)
        let footing = Footing(
            overhang: SIMD2(0.5, 0), thickness: 0.4,
            soil: Soil(
                material: SoilMaterial(shearModulus: 400e6, poissonRatio: 0.3, density: 2000),
                bearingCapacity: nil, friction: 1))
        let width = thickness + 2 * footing.overhang.x
        /// The top's sway at 0.75 s and 1.5 s under a steady push `pressure` on the face.
        func sway(_ pressure: Float) throws -> (early: Float, late: Float) {
            let solver = try wall(size, footing: footing, shells: shells)
            func steps(_ seconds: Double) -> Int { Int((seconds / solver.step).rounded()) }
            solver.setDamping(200)
            solver.advance(steps(0.1))
            solver.setDamping(0)
            let start = Float(solver.time())
            solver.setLoad(
                PressureLoad(
                    axis: 0, positiveSide: false,
                    history: [
                        SIMD2(0, 0), SIMD2(start, 0), SIMD2(start + 0.1, pressure),
                        SIMD2(start + 10, pressure),
                    ]))
            var values: [Float] = []
            for _ in 0..<2 {
                solver.advance(steps(0.75))
                values.append(solver.sway())
            }
            return (values[0], values[1])
        }
        let probe = try wall(size, footing: footing, shells: shells)
        let summary = try #require(probe.footings().first)
        #expect(abs(summary.size.x - width) < 1e-4 && abs(summary.size.y - 1) < 1e-4)
        let weight = (probe.mass + summary.mass) * g
        // The push on the face, H × 1 m at H / 2, whose moment about the footing's toe is W B / 2;
        // and the one that tips the wall alone about its own toe.
        let tipping = weight * width / 2 / (height * (height / 2 + footing.thickness))
        let own = probe.mass * g * thickness / 2 / (height * height / 2)
        #expect(tipping > 5 * own)
        let below = try sway(0.8 * tipping)
        let above = try sway(1.3 * tipping)
        #expect(below.late < 0.03 && abs(below.late - below.early) < 0.01, "\(below)")
        #expect(above.late > 2 * above.early && above.late > 0.3, "\(above)")
    }
}
