import Foundation
import Metal
import SolidMechanics
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// Timber in shells: ContinuumKit's orthotropic plane stress, copied into the shell kernel in
/// single precision, checked against ContinuumKit's own, and layered timber against beam theory.
@Suite("Timber shells", .gpuThreads)
struct TimberTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// Softwood of about C24's stiffness (EN 338: 11 GPa along, 0.37 across, 0.69 in shear),
    /// rolling shear a tenth of that.
    private static func timber(
        grainAxis: Int = 0, rotation: Float = 0, lamellae: [TimberProperties.Lamella] = []
    ) -> StructureMaterial {
        .timber(
            name: "Softwood", density: 420,
            properties: TimberProperties(
                alongGrain: 11e9, acrossGrain: 0.37e9, shearModulus: 0.69e9, rollingShearModulus: 0.069e9,
                poissonRatio: 0.35, grainAxis: grainAxis, grainRotation: rotation, lamellae: lamellae))
    }

    /// ContinuumKit's stress (Pa) for in-plane strain (xx, yy, tensor xy) with the grain at `angle`.
    private static func reference(_ strain: SIMD3<Double>, angle: Double) throws -> SIMD3<Double> {
        let law = try OrthotropicPlaneStress(
            youngAlong: 11e9, youngAcross: 0.37e9, shear: 0.69e9, poissonAlongAcross: 0.35)
        return try law.evaluate(
            strain: SIMD3(strain.x, strain.y, 2 * strain.z), grainAngleRadians: angle,
            frame: OrthotropicPlaneStress.Frame()
        ).stress
    }

    /// One square element of `material`, 0.25 m and 100 mm thick, driven at its corners through
    /// uniform membrane strains (xx, yy, tensor xy); the mean stress through it from the corners'
    /// reactions.
    private final class Membrane {
        let solver: ShellSolver
        let corners: [Int]
        var strain = SIMD3<Float>.zero
        static let side: Float = 0.25
        static let thickness: Float = 0.1

        init(_ material: StructureMaterial, device: MTLDevice) throws {
            var model = StructureModel(
                solids: [Box(min: SIMD3(0, 0, 1), max: SIMD3(Self.side, Self.side, 1 + Self.thickness))],
                material: material, elementSize: Self.side, fixedBase: false)
            model.elementKind = .shell
            model.shellLayers = 1
            solver = try ShellSolver(device: device, model: model)
            solver.groundContact = false
            solver.gravity = 0
            corners = solver.nodes { _ in true }
        }

        func drive(to target: SIMD3<Float>, steps: Int = 3000) -> SIMD3<Float> {
            let change = target - strain
            let gradient =
                simd_float2x2(rows: [SIMD2(change.x, change.z), SIMD2(change.z, change.y)])
                * (1 / (Float(steps) * solver.criticalTimeStep))
            solver.mutateNodes { nodes in
                for n in corners {
                    let p = solver.position(n)
                    let v = gradient * SIMD2(p.x, p.y)
                    (nodes[n].vx, nodes[n].vy, nodes[n].vz) = (v.x, v.y, 0)
                    nodes[n].flags |= 8  // moves as set
                }
            }
            solver.advance(steps: steps)
            strain = target
            var (xx, xy, yy): (Float, Float, Float) = (0, 0, 0)
            for n in corners {
                let p = solver.position(n)
                let f = -solver.nodalForce(n)
                if p.x > Self.side / 2 { (xx, xy) = (xx + f.x, xy + f.y) }
                if p.y > Self.side / 2 { yy += f.y }
            }
            return SIMD3(xx, yy, xy) / (Self.side * Self.thickness)
        }
    }

    private func membraneStress(_ material: StructureMaterial, strain: SIMD3<Float>) throws -> SIMD3<Float> {
        try Membrane(material, device: device).drive(to: strain)
    }

    @Test(
        "A timber layer's stress is ContinuumKit's orthotropic plane stress, along, across and turned",
        arguments: [(0, Float(0)), (0, Float.pi / 6), (1, Float(0)), (1, -Float.pi / 5)])
    func matchesContinuumKit(grainAxis: Int, rotation: Float) throws {
        let strain = SIMD3<Float>(1e-4, -4e-5, 3e-5)
        let stress = try membraneStress(Self.timber(grainAxis: grainAxis, rotation: rotation), strain: strain)
        let angle = Double(rotation) + (grainAxis == 1 ? Double.pi / 2 : 0)
        let expected = SIMD3<Float>(try Self.reference(SIMD3<Double>(strain), angle: angle))
        let scale = max(abs(expected.x), abs(expected.y), abs(expected.z))
        #expect(
            simd_reduce_max(simd_abs(stress - expected)) < 0.01 * scale,
            "stress \(stress / 1e6) MPa, ContinuumKit \(expected / 1e6) MPa")
    }

    @Test("Cross-laminated, each lamella carries its own share, crossed or not")
    func crossLaminatedMembrane() throws {
        let lamellae = [
            TimberProperties.Lamella(share: 0.4, crossed: false),
            TimberProperties.Lamella(share: 0.2, crossed: true),
            TimberProperties.Lamella(share: 0.4, crossed: false),
        ]
        let strain = SIMD3<Float>(1e-4, 5e-5, 2e-5)
        let stress = try membraneStress(Self.timber(lamellae: lamellae), strain: strain)
        let along = try Self.reference(SIMD3<Double>(strain), angle: 0)
        let across = try Self.reference(SIMD3<Double>(strain), angle: .pi / 2)
        let expected = SIMD3<Float>(0.8 * along + 0.2 * across)
        let scale = max(abs(expected.x), abs(expected.y), abs(expected.z))
        #expect(
            simd_reduce_max(simd_abs(stress - expected)) < 0.01 * scale,
            "stress \(stress / 1e6) MPa, expected \(expected / 1e6) MPa")
    }

    /// A strip `length` long, 0.5 m wide and 100 mm thick, clamped at x = 0, settled under its
    /// own weight; its tip's sag (m).
    private func cantileverSag(_ material: StructureMaterial, length: Float, damping: Float, time: Double)
        throws
        -> Float
    {
        var model = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 1), max: SIMD3(length, 0.5, 1.1))], material: material,
            elementSize: 0.125, fixedBase: false)
        model.elementKind = .shell
        model.shellLayers = 4
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        let clamped = solver.nodes { $0.x < 1e-4 }
        solver.mutateNodes { nodes in
            for n in clamped { nodes[n].isClamped = true }
        }
        solver.damping = damping
        solver.advance(steps: Int(time / Double(solver.criticalTimeStep)))
        return -solver.node(solver.nearestNode(to: SIMD3(length, 0.25, 1.05))).displacement.z
    }

    @Test("A timber cantilever sags as beam theory says, along its grain and across it")
    func solidCantilever() throws {
        // w = q L^4 / (8 E I) + q L^2 / (2 k G t), q = rho g t per unit width: across the grain
        // the span bends on E across and shears by rolling the fibres.
        let q = 420 * 9.81 * 0.1
        for (axis, modulus, shear, damping, time) in [
            (0, 11e9, 0.69e9, Float(40), 1.5), (1, 0.37e9, 0.069e9, Float(15), 3.0),
        ] {
            let sag = try cantileverSag(Self.timber(grainAxis: axis), length: 2, damping: damping, time: time)
            let expected = Float(
                q * pow(2, 4) / (8 * modulus * 1e-3 / 12) + q * 4 / (2 * (5.0 / 6.0) * shear * 0.1))
            #expect(
                abs(sag - expected) / expected < 0.02, "grain axis \(axis): \(sag) m, expected \(expected) m")
        }
    }

    @Test("Three crossed lamellae sag as layered beam theory says, rolling shear by the shear analogy")
    func crossLaminatedCantilever() throws {
        let sag = try cantileverSag(
            Self.timber(lamellae: TimberProperties.crossLaminated(3)), length: 3, damping: 40, time: 2)
        // Outer lamellae along the span, the middle one across it: EI = E0 (2 (t^3/12 + t d^2))
        // + E90 t^3 / 12 with t = d = 1/30 m, and the shear analogy's GA = a^2 / (t / (2 G0) +
        // t / G_R + t / (2 G0)) with a = 2/30 m between the outer lamellae's centres.
        let t = 0.1 / 3
        let bending = 11e9 * 2 * (pow(t, 3) / 12 + t * t * t) + 0.37e9 * pow(t, 3) / 12
        let shear = pow(2 * t, 2) / (t / (2 * 0.69e9) + t / 0.069e9 + t / (2 * 0.69e9))
        let q = 420 * 9.81 * 0.1
        let expected = Float(q * pow(3, 4) / (8 * bending) + q * 9 / (2 * shear))
        #expect(abs(sag - expected) / expected < 0.02, "\(sag) m, expected \(expected) m")
    }

    /// Spruce as Sandhaas and van de Kuilen give it (HERON 58, 2013), its grain along x.
    private static func spruce() -> StructureMaterial {
        var properties = TimberProperties(
            alongGrain: 11e9, acrossGrain: 0.37e9, shearModulus: 0.69e9, rollingShearModulus: 0.05e9,
            poissonRatio: 0.35)
        properties.tensionAlong = 24e6
        properties.compressionAlong = 36e6
        properties.tensionAcross = 0.7e6
        properties.compressionAcross = 4.3e6
        properties.shearStrength = 6.9e6
        properties.rollingStrength = 0.5e6
        return .timber(name: "Spruce", density: 420, properties: properties)
    }

    @Test(
        "Pulled across its grain, a timber layer splits at its strength and separates on its fracture energy")
    func splitsAcrossTheGrain() throws {
        let membrane = try Membrane(Self.spruce(), device: device)
        // Across the grain with the strain along it held at zero; the band is the element.
        let q22: Float = 0.37e9 / (1 - 0.35 * 0.35 * 0.37 / 11)
        let onset = 0.7e6 / q22
        var peak: Float = 0
        var work: Float = 0
        var previous: Float = 0
        var last: Float = 0
        for i in 1...60 {
            let strain = onset * 4 * Float(i) / 60
            let stress = membrane.drive(to: SIMD3(0, strain, 0), steps: 400).y
            peak = max(peak, stress)
            work += 0.5 * (stress + previous) * (onset * 4 / 60)
            previous = stress
            last = stress
        }
        // Softening ends at 3.0 onsets on a 0.25 m band: 500 / 0.25 J/m^3 over q22's ½ f^2 / E.
        let expected: Float = 500 / 0.25 * (0.37e9 / q22)
        #expect(abs(peak - 0.7e6) < 0.03 * 0.7e6, "peak \(peak / 1e6) MPa")
        #expect(abs(last) < 0.01 * 0.7e6, "left \(last / 1e6) MPa")
        #expect(abs(work - expected) / expected < 0.06, "work \(work) J/m^3, expected \(expected)")
    }

    @Test("Squeezed along its grain, timber crushes at its strength and holds it; damage never softens it")
    func crushesAlongTheGrain() throws {
        let membrane = try Membrane(Self.spruce(), device: device)
        // The reactions give the nominal stress, the stretch times the second Piola-Kirchhoff
        // stress the layers carry against the Green strain; the stretch is read off the corners.
        func stretch() -> Float {
            let far = membrane.corners.filter { membrane.solver.position($0).x > Membrane.side / 2 }
            return far.map { membrane.solver.position($0).x }.reduce(0, +) / Float(far.count) / Membrane.side
        }
        let crushed = membrane.drive(to: SIMD3(-0.02, 0, 0), steps: 6000).x
        let stretch1 = stretch()
        #expect(abs(crushed / stretch1 + 36e6) < 0.01 * 36e6, "\(crushed / stretch1 / 1e6) MPa")
        let unloaded = membrane.drive(to: SIMD3(-0.02 + 30e6 / 11e9, 0, 0), steps: 3000).x
        let stretch2 = stretch()
        // Unloading is elastic: the stress falls by Q11 times the change in Green strain.
        let q11: Float = 11e9 / (1 - 0.35 * 0.35 * 0.37 / 11)
        let slope =
            (unloaded / stretch2 - crushed / stretch1) / ((stretch2 * stretch2 - stretch1 * stretch1) / 2)
        #expect(abs(slope - q11) < 0.03 * q11, "unloading modulus \(slope / 1e9) GPa")
        #expect(unloaded < 0)
    }

    @Test(
        "A timber beam loaded at mid-span by a node load bends as beam theory says, and breaks at its face's strength"
    )
    func beamUnderNodeLoad() throws {
        // 2 m simply supported, 120 x 200 mm (a beam: wider than half its depth), of C24 with its
        // fibres breaking at 30 MPa.
        var properties = TimberProperties(
            alongGrain: 11e9, acrossGrain: 0.37e9, shearModulus: 0.69e9, rollingShearModulus: 0.069e9)
        properties.tensionAlong = 30e6
        properties.compressionAlong = 1e30
        var model = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 0), max: SIMD3(2, 0.12, 0.2))],
            material: .timber(name: "Beam", density: 420, properties: properties), elementSize: 0.1,
            fixedBase: false)
        model.elementKind = .shell
        let solver = try ShellSolver(device: device, model: model)
        #expect(solver.beamCount > 0 && solver.elementCount == 0)
        solver.groundContact = false
        solver.gravity = 0
        let positions = solver.mesh.positions
        let ends = positions.indices.filter { abs(positions[$0].x) < 1e-3 || abs(positions[$0].x - 2) < 1e-3 }
        let middle = positions.indices.filter { abs(positions[$0].x - 1) < 1e-3 }
        solver.mutateNodes { nodes in
            for n in nodes.indices { nodes[n].restrain(y: true) }
            for n in ends { nodes[n].restrain(z: true) }
            for n in ends where positions[n].x < 1 { nodes[n].restrain(x: true) }
            for n in middle { nodes[n].restrain(rotation: true) }
        }
        // A load rising over 2 s to 80 kN, as a node load on mid-span.
        var load = PressureLoad(axis: 2, positiveSide: true, history: [SIMD2(0, 0), SIMD2(2, 80e3)])
        var shares = [Float](repeating: 0, count: positions.count)
        for n in middle { shares[n] = 1 / Float(middle.count) }
        load.nodeShares = shares
        solver.appliedLoad = load
        solver.damping = 50
        // At 20 kN: P L^3 / 48 E I + P L / 4 (5/6) G A.
        let stiffness: Float =
            1 / (8 / (48 * 11e9 * 0.12 * 0.008 / 12) + 2 / (4 * (5.0 / 6.0) * 0.69e9 * 0.024))
        solver.advance(steps: Int(0.5 / Double(solver.criticalTimeStep)))
        let sag = middle.map { -solver.node($0).displacement.z }.reduce(0, +) / Float(middle.count)
        #expect(
            abs(sag * stiffness - 20e3) < 0.03 * 20e3,
            "at 20 kN: \(sag * 1000) mm, \(20e3 / stiffness * 1000) expected")
        // The face reaches 30 MPa at P = 4 f W / L = 48 kN, at the elements' one point along them,
        // half an element (5%) from mid-span, at 48 / 0.95; it breaks then, brittly.
        var broke: Float?
        while solver.time < 2, broke == nil {
            solver.advance(steps: Int(0.01 / Double(solver.criticalTimeStep)))
            if solver.summary().maxDamage >= 1 { broke = 80e3 * Float(solver.time / 2) }
        }
        let expected: Float = 4 * 30e6 * (0.12 * 0.04 / 6) / 2 / 0.95
        let at = try #require(broke)
        #expect(
            abs(at - expected) < 0.03 * expected, "broke at \(at / 1e3) kN, expected \(expected / 1e3) kN")
    }

    @Test(
        "A piece of timber is meshed as shells whatever its elements were chosen as; mixed with concrete, so is it"
    )
    func timberMeshesAsShells() throws {
        var model = StructureModel(
            solids: [Box(min: SIMD3(1, 1, 0), max: SIMD3(4, 1.1, 2.5))], material: .crossLaminatedTimber,
            elementSize: 0.125, fixedBase: true)
        #expect(model.elementKind == .solid && model.isAllShells)
        let scenario = Scenario(
            name: "CLT wall", domainSize: SIMD3(6, 3, 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(0.5, 1.5, 0.5)), structure: model)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        #expect(solver.shells != nil && solver.structure == nil)
        // With a concrete footing beside it, the body is mixed: solids and shells.
        model.solids.append(Box(min: SIMD3(1, 1.1, 0), max: SIMD3(4, 1.6, 0.5)))
        model.setMaterial(.reinforcedConcrete, of: 1)
        #expect(model.isMixed && model.elementKind(of: 0) == .shell && model.elementKind(of: 1) == .solid)
    }

    @Test(
        "A timber layer breaking follows ContinuumKit's released TimberFailure, along the grain, across it and in shear",
        arguments: [0, 1, 2])
    func failureMatchesContinuumKit(path: Int) throws {
        // Spruce as Sandhaas and van de Kuilen give it, with every fracture energy positive (as
        // ContinuumKit requires); the element's band is its side, 0.25 m. Driven past breaking.
        var properties = TimberProperties(
            alongGrain: 11e9, acrossGrain: 0.37e9, shearModulus: 0.69e9, rollingShearModulus: 0.05e9,
            poissonRatio: 0.35)
        properties.tensionAlong = 24e6
        properties.compressionAlong = 36e6
        properties.tensionAcross = 0.7e6
        properties.compressionAcross = 4.3e6
        properties.shearStrength = 6.9e6
        properties.rollingStrength = 0.5e6
        properties.fibreEnergy = 60e3
        // In shear, ten times spruce's, so that it softens on this band rather than breaking at once
        // (where the two would differ by the whole strength at the one step between them).
        properties.shearEnergy = 12e3
        let membrane = try Membrane(
            .timber(name: "Spruce", density: 420, properties: properties), device: device)
        let law = try TimberFailure(
            alongModulus: 11e9, acrossModulus: 0.37e9, shearModulus: 0.69e9, rollingModulus: 0.05e9,
            poisson: 0.35,
            tensionAlong: 24e6, compressionAlong: 36e6, tensionAcross: 0.7e6, compressionAcross: 4.3e6,
            shearStrength: 6.9e6, rollingStrength: 0.5e6, fibreEnergy: 60e3, splittingEnergy: 500,
            shearEnergy: 12e3,
            rollingEnergy: 600, bandLength: Double(Membrane.side), throughBandLength: 0.1)
        // Along the grain (x), across it (y) and in shear, to several times the breaking strain.
        let (end, strength): (Float, Float) = [(0.012, 24e6), (0.006, 0.7e6), (0.02, 6.9e6)][path]
        var reference = law.zeroState
        var worst: Float = 0
        for i in 1...40 {
            let amount = end * Float(i) / 40
            let target: SIMD3<Float> =
                path == 0 ? SIMD3(amount, 0, 0) : path == 1 ? SIMD3(0, amount, 0) : SIMD3(0, 0, amount / 2)
            let nominal = membrane.drive(to: target, steps: 600)
            // The layer's Green strain and second Piola-Kirchhoff stress, from the corners.
            let far = membrane.corners.filter {
                path == 1
                    ? membrane.solver.position($0).y > Membrane.side / 2
                    : membrane.solver.position($0).x > Membrane.side / 2
            }
            let positions = far.map { membrane.solver.position($0) }
            let stretch =
                (path == 1 ? positions.map(\.y) : positions.map(\.x)).reduce(0, +) / Float(positions.count)
                / Membrane.side
            let green = path == 2 ? Double(amount) : Double(stretch * stretch - 1) / 2
            let strain =
                path == 0
                ? TimberFailure.Components(along: green)
                : path == 1 ? TimberFailure.Components(across: green) : TimberFailure.Components(shear: green)
            reference = try law.evaluate(strain: strain, from: reference)
            let model = path == 0 ? nominal.x / stretch : path == 1 ? nominal.y / stretch : nominal.z
            let expected = Float(
                path == 0
                    ? reference.stress.along : path == 1 ? reference.stress.across : reference.stress.shear)
            worst = max(worst, abs(model - expected))
        }
        #expect(
            worst < 0.03 * strength,
            "worst \(worst / 1e6) MPa off ContinuumKit, strength \(strength / 1e6) MPa")
    }

    @Test("Timber in solid elements is refused; layered, it is integrated lamella by lamella")
    func solidsRefused() throws {
        let model = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 0), max: SIMD3(1, 1, 0.1))], material: Self.timber(),
            elementSize: 0.05,
            fixedBase: false)
        #expect(throws: BlastError.self) { try StructureSolver(device: device, model: model) }
        let rule = ShellSolver.thicknessRule(
            layers: 4, materials: [Self.timber(lamellae: TimberProperties.crossLaminated(5))])
        #expect(rule.count == 15)
        #expect(abs(rule.reduce(0) { $0 + $1.y } - 2) < 1e-5)
    }
}
