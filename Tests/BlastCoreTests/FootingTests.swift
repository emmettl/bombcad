import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Rigid footings on soil (`Footing`, `FootingBed`, `FootingImpedance`) against theory: the
/// half-space's static stiffness, a footing's heel lifting and its toe bearing, the cones'
/// dynamic stiffness, and a layer's.
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
        let footing = Footing(
            overhang: SIMD2(0.25, 0.25), thickness: 0.5, soil: Soil(bearingCapacity: nil, cyclic: nil))
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
            overhang: SIMD2(0.25, 0.25), thickness: 0.5,
            soil: Soil(bearingCapacity: nil, friction: 1.2, cyclic: nil))
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
        "A wall on a footing tips about the footing's toe, M = W B / 2, not its own; of solids or shells, over a layer",
        arguments: [(false, nil), (true, nil), (false, 2)] as [(Bool, Float?)])
    func overturning(shells: Bool, layer: Float?) throws {
        // A 3 m wall 250 mm thick on a footing 1.25 m wide on stiff soil, a 1 m strip of it.
        // Over a layer, the soil's echoes must not push a footing that lifts and turns this far.
        let (height, thickness): (Float, Float) = (3, 0.25)
        let size = SIMD3(thickness, 1, height)
        let footing = Footing(
            overhang: SIMD2(0.5, 0), thickness: 0.4,
            soil: Soil(
                material: SoilMaterial(shearModulus: 400e6, poissonRatio: 0.3, density: 2000),
                bearingCapacity: nil, friction: 1, layerDepth: layer, cyclic: nil))
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

    // MARK: - The soil's mass and radiation damping

    /// Drives `solver` at about ω rad/s, `force(sin ωt)` setting the load each 1/48 of a period,
    /// for `warm` periods and then `measured` more, and returns the frequency it drove at (a
    /// whole number of steps to a period) and the complex amplitudes X of the signals `read`
    /// gives over the measured periods, as u(t) = Im(X e^(iωt)). The force grows from nothing
    /// over the first `ramp` periods, so as to set little free vibration going.
    private func drive(
        _ solver: StructureSolver, omega: Double, warm: Int, measured: Int, ramp: Int = 0,
        force: (Float) -> Void, read: () -> [Float]
    ) -> (omega: Double, amplitudes: [Complex]) {
        let chunks = 48
        let dt = Double(solver.criticalTimeStep)
        let stepsPerChunk = max(1, Int((2 * Double.pi / omega / dt / Double(chunks)).rounded()))
        let period = Double(chunks * stepsPerChunk) * dt
        let omega = 2 * Double.pi / period
        var sums: [Complex] = []
        var last: (time: Double, values: [Float])?
        for chunk in 0..<((warm + measured) * chunks) {
            let middle = (Double(chunk) + 0.5) * period / Double(chunks)
            let growth = ramp > 0 ? min(1, middle / (Double(ramp) * period)) : 1
            force(Float(growth * sin(omega * middle)))
            solver.advance(steps: stepsPerChunk)
            let now = (time: Double(chunk + 1) * period / Double(chunks), values: read())
            if sums.isEmpty { sums = now.values.map { _ in Complex(0) } }
            if chunk >= warm * chunks, let last {
                // u(t) = X_r sin + X_i cos: X_r = (2/T) ∫ u sin, X_i = (2/T) ∫ u cos, by trapezoids.
                let dt = now.time - last.time
                for k in sums.indices {
                    let a = Double(last.values[k])
                    let b = Double(now.values[k])
                    sums[k] =
                        sums[k]
                        + Complex(
                            dt / 2 * (a * sin(omega * last.time) + b * sin(omega * now.time)),
                            dt / 2 * (a * cos(omega * last.time) + b * cos(omega * now.time)))
                }
            }
            last = now
        }
        let span = Double(measured) * period
        return (omega, sums.map { Complex(2 * $0.real / span, 2 * $0.imaginary / span) })
    }

    /// A 1 m block on a 1.5 m square footing 0.5 m thick on the medium dense sand.
    private func impedanceBlock(soil: Soil = Soil(bearingCapacity: nil, friction: 2, cyclic: nil)) throws
        -> StructureSolver
    {
        let solver = try block(
            SIMD3(1, 1, 1), footing: Footing(overhang: SIMD2(0.25, 0.25), thickness: 0.5, soil: soil))
        solver.damping = 200
        solver.advance(steps: steps(solver, seconds: 0.15))
        solver.damping = 0
        return solver
    }

    @Test("Driven up and down, a footing answers as the vertical cone's impedance says")
    func verticalImpedance() throws {
        let soil = Soil(bearingCapacity: nil, friction: 2, cyclic: nil)
        let bed = FootingBed(width: 1.5, length: 1.5, soil: soil)
        let probe = try impedanceBlock(soil: soil)
        let mass = Double(bodyMass(probe) + probe.footingSummaries()[0].mass)
        let natural = (Double(bed.stiffness[0]) / mass).squareRoot()
        for ratio in [0.5, 1.0, 2.0] {
            let solver = try impedanceBlock(soil: soil)
            // A body force a sin ωt on everything, the footing too: F = -M a sin ωt (downward).
            let a: Float = 2
            let (omega, response) = drive(
                solver, omega: ratio * natural, warm: 6, measured: 4,
                force: { solver.gravity = 9.81 + a * $0 },
                read: { [solver.footingSummaries()[0].displacement.z] })
            let x = response[0]
            // F = Im(-M a e^(iωt)), so X = -M a / (S - ω² M).
            let measured = Complex(-mass * Double(a)) / x + Complex(omega * omega * mass)
            let expected = bed.impedance.dynamicStiffness(.vertical, omega: omega)
            #expect(
                (measured - expected).magnitude < 0.05 * expected.magnitude,
                "ω = \(ratio) ω₀: \(measured) against \(expected)")
        }
    }

    @Test("Pushed to and fro, a footing sways and rocks as the cones' impedances say")
    func rockingImpedance() throws {
        let soil = Soil(bearingCapacity: nil, friction: 2, cyclic: nil)
        let bed = FootingBed(width: 1.5, length: 1.5, soil: soil)
        let probe = try impedanceBlock(soil: soil)
        let footing = probe.footingSummaries()[0]
        // The rigid body about the base centre O: mass, height of its centre, and moment of
        // inertia about y through O, from the block's node masses and the footing's box.
        var mass = Double(footing.mass)
        var moment = Double(footing.mass) * 0.25
        var inertia = Double(footing.mass) * (1.5 * 1.5 + 0.5 * 0.5) / 12 + Double(footing.mass) * 0.25 * 0.25
        probe.mutateNodes { nodes in
            for k in 0...probe.ez {
                for j in 0...probe.ey {
                    for i in 0...probe.ex {
                        guard let n = probe.storedNode(i, j, k) else { continue }
                        let x = Double(i) * 0.25 - 0.5
                        let z = Double(k) * 0.25 + 0.5
                        mass += Double(nodes[n].mass)
                        moment += Double(nodes[n].mass) * z
                        inertia += Double(nodes[n].mass) * (x * x + z * z)
                    }
                }
            }
        }
        let h = moment / mass
        let lever = 1.0  // the push, at the block's mid-height
        let natural = (Double(bed.stiffness[4]) / inertia).squareRoot()
        for ratio in [0.6, 1.6] {
            let solver = try impedanceBlock(soil: soil)
            let p: Float = 5000
            let (omega, response) = drive(
                solver, omega: ratio * natural, warm: 20, measured: 4,
                force: { value in
                    solver.appliedLoad = PressureLoad(
                        axis: 0, positiveSide: false, history: [SIMD2(0, p * value), SIMD2(1e6, p * value)])
                },
                read: {
                    let f = solver.footingSummaries()[0]
                    return [f.displacement.x, f.rotation.y]
                })
            // [S_h - ω² M, -ω² M h; -ω² M h, S_r - ω² I_O - M g h] [X, Θ] = [F, F lever].
            let sh = bed.impedance.dynamicStiffness(.horizontalX, omega: omega)
            let sr = bed.impedance.dynamicStiffness(.rockingY, omega: omega)
            let a11 = sh - Complex(omega * omega * mass)
            let a12 = Complex(-omega * omega * mass * h)
            let a22 = sr - Complex(omega * omega * inertia + mass * 9.81 * h)
            let f = Complex(Double(p))
            let det = a11 * a22 - a12 * a12
            let sway = (f * a22 - a12 * f * Complex(lever)) / det
            let rock = (a11 * f * Complex(lever) - a12 * f) / det
            #expect(
                (response[1] - rock).magnitude < 0.07 * rock.magnitude,
                "ω = \(ratio) ω₀: rotation \(response[1]) against \(rock)")
            #expect(
                (response[0] - sway).magnitude < 0.07 * sway.magnitude,
                "ω = \(ratio) ω₀: sway \(response[0]) against \(sway)")
        }
    }

    // MARK: - Layers

    @Test("Over a layer on rock a footing is stiffer, as the cones' echoes and Kausel's stratum say")
    func layerStatics() throws {
        let depth: Float = 1.5
        let layer = Soil(bearingCapacity: nil, friction: 2, layerDepth: depth, cyclic: nil)
        let bed = FootingBed(width: 1.5, length: 1.5, soil: layer)
        let impedance = bed.impedance
        let factor = impedance.staticStiffness(.vertical) / impedance.stiffness[0]
        // E. Kausel's stratum on rock, 1 + 1.28 r / d, for a disk of the footing's area.
        let radius = (1.5 * 1.5 / Float.pi).squareRoot()
        let kausel = 1 + 1.28 * radius / depth
        #expect(factor > 1.3 && abs(factor / kausel - 1) < 0.12, "\(factor) against \(kausel)")
        // Over a soft half-space instead of rock the layer is softer than on its own.
        var soft = layer
        soft.beneath = SoilMaterial(shearModulus: 10e6, poissonRatio: 0.3, density: 1800)
        let softer = FootingBed(width: 1.5, length: 1.5, soil: soft).impedance
        #expect(softer.staticStiffness(.vertical) < softer.stiffness[0])
        // Massless, the bed is that much stiffer from the start; with mass, the echoes make it so.
        var massless = layer
        massless.radiationDamping = false
        for soil in [massless, layer] {
            let solver = try block(
                SIMD3(1, 1, 1), footing: Footing(overhang: SIMD2(0.25, 0.25), thickness: 0.5, soil: soil))
            solver.damping = 100
            solver.advance(steps: steps(solver, seconds: 1))
            let summary = try #require(solver.footingSummaries().first)
            let weight = (bodyMass(solver) + summary.mass) * g
            let expected = -weight / impedance.staticStiffness(.vertical)
            #expect(
                abs(summary.displacement.z / expected - 1) < 0.03,
                "radiation \(soil.radiationDamping): \(summary.displacement.z) m against \(expected) m")
        }
    }

    @Test(
        "Pushed past its friction, a footing slides at (F − μ W) / M, on the half-space or over a layer",
        arguments: [nil, 2] as [Float?])
    func sliding(layer: Float?) throws {
        let soil = Soil(bearingCapacity: nil, friction: 0.5, layerDepth: layer, cyclic: nil)
        let solver = try block(
            SIMD3(1, 1, 0.5), footing: Footing(overhang: SIMD2(0.5, 0.5), thickness: 0.3, soil: soil))
        solver.damping = 200
        solver.advance(steps: steps(solver, seconds: 0.1))
        solver.damping = 0
        let mass = bodyMass(solver) + solver.footingSummaries()[0].mass
        let push = 1.3 * soil.friction * mass * g  // on the block's 1 × 0.5 m face
        let start = Float(solver.time)
        solver.appliedLoad = PressureLoad(
            axis: 0, positiveSide: false,
            history: [
                SIMD2(0, 0), SIMD2(start, 0), SIMD2(start + 0.02, push / 0.5), SIMD2(start + 10, push / 0.5),
            ])
        solver.advance(steps: steps(solver, seconds: 0.1))
        let early = try #require(solver.footingSummaries().first)
        solver.advance(steps: steps(solver, seconds: 0.2))
        let late = try #require(solver.footingSummaries().first)
        let acceleration = (late.velocity.x - early.velocity.x) / 0.2
        let expected = (push - soil.friction * mass * g) / mass
        #expect(
            abs(acceleration / expected - 1) < 0.15, "\(acceleration) m/s² against \(expected)")
        #expect(abs(late.rotation.y) < 0.01 && late.uplift < 0.01)
    }

    @Test(
        "Over any layer the soil never gives a footing energy: its impedance's imaginary part stays positive")
    func layerPassivity() {
        let beneath: [SoilMaterial?] = [
            nil, .softRock, SoilMaterial(shearModulus: 10e6, poissonRatio: 0.3, density: 1800),
        ]
        for depth: Float in [0.3, 1, 3, 10] {
            for below in beneath {
                let soil = Soil(layerDepth: depth, beneath: below)
                let impedance = FootingBed(width: 1.5, length: 1.5, soil: soil).impedance
                for mode in FootingImpedance.Mode.allCases {
                    let period = 2 * Double(depth) / Double(impedance.waveSpeed[mode.rawValue])
                    let lowest = (1...4000).map { k -> Double in
                        let omega = Double(k) * 20 * .pi / period / 4000
                        return impedance.dynamicStiffness(mode, omega: omega).imaginary
                            / (omega * Double(impedance.dashpot[mode.rawValue]))
                    }.min()!
                    #expect(
                        lowest > -1e-4, "\(mode) over \(depth) m on \(String(describing: below)): \(lowest)")
                }
            }
        }
    }

    @Test("Over a layer on rock a footing radiates little below the layer's cut-off, as its impedance says")
    func layerImpedance() throws {
        let soil = Soil(bearingCapacity: nil, friction: 2, layerDepth: 1.5, cyclic: nil)
        let bed = FootingBed(width: 1.5, length: 1.5, soil: soil)
        let probe = try impedanceBlock(soil: soil)
        let mass = Double(bodyMass(probe) + probe.footingSummaries()[0].mass)
        // The layer's first vertical mode, c / 4 d: below it no wave carries energy away.
        let cutoff = 2 * Double.pi * Double(soil.material.coneWaveSpeed) / (4 * 1.5)
        let halfSpace = FootingImpedance(width: 1.5, length: 1.5, soil: Soil(), stiffness: bed.stiffness)
        let low = bed.impedance.dynamicStiffness(.vertical, omega: 0.4 * cutoff)
        #expect(low.imaginary < 0.3 * halfSpace.dynamicStiffness(.vertical, omega: 0.4 * cutoff).imaginary)
        for ratio in [0.4, 1.5] {
            let solver = try impedanceBlock(soil: soil)
            // The layer keeps the footing's own free vibration, which it hardly radiates; a little
            // damping of the body's, i ω M c in the impedance, lets it die away.
            let damping: Float = 20
            solver.damping = damping
            let a: Float = 2
            let (omega, response) = drive(
                solver, omega: ratio * cutoff, warm: 30, measured: 4, ramp: 10,
                force: { solver.gravity = 9.81 + a * $0 },
                read: { [solver.footingSummaries()[0].displacement.z] })
            let x = response[0]
            let measured = Complex(-mass * Double(a)) / x + Complex(omega * omega * mass)
            let expected =
                bed.impedance.dynamicStiffness(.vertical, omega: omega)
                + Complex(0, omega * mass * Double(damping))
            #expect(
                (measured - expected).magnitude < 0.07 * expected.magnitude,
                "ω = \(ratio) cut-off: \(measured) against \(expected)")
        }
    }

    // MARK: - Cyclic sand

    /// A 1 × 1 × 2 m block on a 1.5 m square footing on sand bearing 600 kPa, settled, then
    /// pushed one way and the other on its faces, `cycles` times, each push's moment about the
    /// footing's base `share` of W B / 2; its settlement after each cycle.
    private func rocked(_ sand: CyclicSand?, share: Float = 0.6, cycles: Int = 4) throws -> (
        rest: Float, settlement: [Float]
    ) {
        var soil = Soil(bearingCapacity: 600e3)
        soil.cyclic = sand
        let footing = Footing(overhang: SIMD2(0.25, 0.25), thickness: 0.5, soil: soil)
        let solver = try block(SIMD3(1, 1, 2), footing: footing)
        solver.damping = 200
        solver.advance(steps: steps(solver, seconds: 0.5))
        let rest = try #require(solver.footingSummaries().first)
        let weight = (bodyMass(solver) + rest.mass) * g
        // A face of 2 m², its middle 1.5 m above the footing's base.
        let push = share * weight * (1.5 / 2) / 1.5 / 2
        solver.damping = 20
        var settlement: [Float] = []
        for _ in 0..<cycles {
            for side in [false, true] {
                solver.appliedLoad = PressureLoad(
                    axis: 0, positiveSide: side, history: [SIMD2(0, push), SIMD2(1e6, push)])
                solver.advance(steps: steps(solver, seconds: 0.4))
            }
            solver.appliedLoad = nil
            solver.advance(steps: steps(solver, seconds: 0.2))
            let now = try #require(solver.footingSummaries().first)
            settlement.append(rest.displacement.z - now.displacement.z)
        }
        return (rest.displacement.z, settlement)
    }

    @Test("Cyclic sand settles under its weight as the elastic bed does, and at every cycle of rocking")
    func cyclicSandRatchets() throws {
        let elastic = try rocked(nil, cycles: 2)
        let gajan = try rocked(CyclicSand())
        // First loaded, the sand is as stiff as the elastic bed.
        #expect(abs(gajan.rest / elastic.rest - 1) < 0.03, "\(gajan.rest) against \(elastic.rest)")
        // Rocked on the elastic bed, its stiff edges yield a little at first and then no more; on
        // Gajan's sand it settles at every cycle, by about as much each time.
        #expect(
            elastic.settlement[1] - elastic.settlement[0] < 0.2 * elastic.settlement[0],
            "\(elastic.settlement)")
        let steps = zip(gajan.settlement, [0] + gajan.settlement).map { $0 - $1 }
        #expect(steps.allSatisfy { $0 > 0.2 * abs(gajan.rest) }, "\(gajan.settlement)")
        #expect(steps[3] > 0.3 * steps[1], "\(steps)")
        // Remembering the force each point bore, it shakes down after the first cycle.
        let remembering = try rocked(CyclicSand(memory: 1, heave: 0))
        #expect(
            remembering.settlement[3] - remembering.settlement[1] < 0.2 * remembering.settlement[0],
            "\(remembering.settlement)")
    }

    // MARK: - Measured

    @Test(
        "Rocked slowly, a footing on dry sand mobilizes the moment Gajan and Kutter's did, within 15% to 7 mrad"
    )
    func measuredRocking() throws {
        // The first two packets (`blastbench rocking` runs all five), the push set every 4 ms.
        let packets = Array(FootingRockingTest.packets.prefix(2))
        let result = try FootingRockingTest.run(
            device: device, shearModulus: 80e6, packets: packets, interval: 4e-3)
        for (measured, model) in zip(packets, result.packets) {
            #expect(abs(model.peakRotation / measured.peakRotation - 1) < 0.15, "\(measured.name) rotation")
            // Pushing forward: the measured moment back was lopsided in the first packet.
            #expect(
                abs(model.moment.x / measured.moment.x - 1) < 0.15,
                "\(measured.name): \(model.moment.x) against \(measured.moment.x)")
        }
        // On cyclic sand it settles up to twice as much as the sand did, where the elastic bed
        // settled a tenth (see docs/validation.md#a-footing-shaken-on-dry-sand).
        let ratio = result.packets[1].settlement / packets[1].settlement
        #expect(ratio > 0.7 && ratio < 2.5, "\(ratio)")
    }

    @Test(
        "Shaken at its base, a wall on a footing on dry sand settles and rocks as Gajan's SSG04 did, within 50%"
    )
    func measuredShaking() throws {
        // The first of SSG04's shakes on the lighter wall (`blastbench shaking` runs them all).
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Samples/FoRDy").standardized
        var test = FootingShakingTest.tests[0]
        test.events = [test.events[0]]
        let measured = try FootingShakingTest.Series.load(folder.appending(path: "\(test.events[0]).csv"))
        let result = try FootingShakingTest.run(
            device: device, test: test, series: [measured], interval: 2e-3)
        let (a, b) = (measured.summary, result.events[0].summary)
        #expect(
            abs(b.settlement / a.settlement - 1) < 0.5, "settlement \(b.settlement) against \(a.settlement)")
        let peak = { (s: FootingShakingTest.Summary) in max(s.rotation.x, -s.rotation.y) }
        #expect(abs(peak(b) / peak(a) - 1) < 0.5, "rotation \(peak(b)) against \(peak(a))")
        // It dissipates energy in the sand, if less than the test did.
        #expect(b.energy > 0.3 * a.energy, "energy \(b.energy) against \(a.energy)")
    }
}
