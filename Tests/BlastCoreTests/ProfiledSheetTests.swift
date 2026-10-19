import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// Profiled metal sheeting as a skin with the ribs as beams (docs/profiled-sheeting.md).
@Suite("Profiled sheeting", .gpuThreads)
struct ProfiledSheetTests {
    /// Langdon's panel, 880 mm wide and 915 mm high, standing in the x–z plane at y = 0.5.
    static func panel(
        _ profile: SheetProfile = .langdonBlastWall, steel: StructureMaterial, size: Float = 0.0575
    )
        -> (StructureModel, ProfiledSheet)
    {
        var model = StructureModel(
            solids: [], material: steel, elementSize: size, fixedBase: false)
        model.elementKind = .shell
        model.shellLayers = 4
        let sheet = ProfiledSheet(
            profile: profile, region: Box(min: SIMD3(0, 0.49, 0), max: SIMD3(0.88, 0.51, 0.915)), span: 2,
            steel: steel)
        sheet.add(to: &model)
        return (model, sheet)
    }

    @Test("Simply supported and pressed slowly, the sheet bends as a beam of the profile")
    func elasticSpan() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let elastic = StructureMaterial.elastic(density: 7850, youngsModulus: 210e9, poissonRatio: 0.3)
        let (model, _) = Self.panel(steel: elastic)
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        solver.damping = 600
        let pressure: Float = 10_000
        solver.appliedLoad = PressureLoad(
            axis: 1, positiveSide: false, history: [SIMD2(0, pressure), SIMD2(100, pressure)])
        let ends = solver.nodes { $0.z < 1e-4 || $0.z > 0.915 - 1e-4 }
        let corner = solver.nearestNode(to: SIMD3(0, 0.5, 0))
        solver.mutateNodes { nodes in
            for n in ends { nodes[n].restrain(y: true, z: true) }
            nodes[corner].restrain(x: true)
        }
        solver.advance(steps: Int(0.05 / solver.criticalTimeStep))
        let perWidth = SheetProfile.langdonBlastWall.perWidth
        let expected = 5 * pressure * pow(0.915, 4) / (384 * 210e9 * perWidth.secondMoment)
        let middle = solver.node(solver.nearestNode(to: SIMD3(0.44, 0.5, 0.4575))).displacement.y
        print("Profiled sheet, simply supported: \(middle * 1000) mm, expected \(expected * 1000) mm")
        #expect(abs(abs(middle) / expected - 1) < 0.05, "middle \(middle) m, expected \(expected) m")
    }

    @Test(
        "A plate on a turning spring bends as a cantilever whose foot turns by its moment over the spring's stiffness"
    )
    func springSupport() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let elastic = StructureMaterial.elastic(density: 7850, youngsModulus: 210e9, poissonRatio: 0.3)
        var model = StructureModel(
            solids: [Box(min: SIMD3(0, -0.01, 0), max: SIMD3(1, 0.01, 1))], material: elastic,
            elementSize: 0.1,
            fixedBase: false)
        model.elementKind = .shell
        model.shellLayers = 4
        // Stiff along and across, 20 kN m/rad per metre turning.
        let stiff = SpringLaw(stiffness: 1e10)
        let turning = SpringLaw(stiffness: 2e4)
        model.springSupports = [
            SpringSupport(
                region: Box(min: SIMD3(-0.01, -0.02, -0.005), max: SIMD3(1.01, 0.02, 0.005)), edge: 0,
                along: 2,
                pull: stiff, across: stiff, turnPositive: turning, turnNegative: turning)
        ]
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        // Near critical for its first mode on the spring (about 20 rad/s), to settle in a second.
        solver.damping = 40
        let pressure: Float = 1000
        solver.appliedLoad = PressureLoad(
            axis: 1, positiveSide: true, history: [SIMD2(0, pressure), SIMD2(100, pressure)])
        solver.advance(steps: Int(1.5 / solver.criticalTimeStep))
        // M = q L² / 2 = 500 N m per metre at the foot: 0.025 rad.
        let foot = solver.node(solver.nearestNode(to: SIMD3(0.5, 0, 0)))
        let turn = 2 * atan2(foot.rotation.imag.x, foot.rotation.real)
        let tip = solver.node(solver.nearestNode(to: SIMD3(0.5, 0, 1))).displacement.y
        print("Foot turned \(turn) rad, expected 0.025; tip \(tip) m, foot y \(foot.displacement.y)")
        #expect(abs(abs(turn) / 0.025 - 1) < 0.05, "turned \(turn) rad")
        #expect(abs(foot.displacement.y) < 1e-5 && abs(foot.displacement.z) < 1e-5)
    }

    @Test(
        "Langdon's panel against its design direction collapses as its wide flange buckles, held by her springs"
    )
    func langdonNegative() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures/Langdon2003/panels.json")
        let panel = try #require(try LangdonPanelTest.panels(from: url).first { $0.name == "60CORR1" })
        var settings = LangdonPanelTest.Settings()
        let buckled = try LangdonPanelTest.run(panel, settings: settings, device: device)
        settings.buckles = false
        let stiff = try LangdonPanelTest.run(panel, settings: settings, device: device)
        print(
            "60CORR1 (283 mm measured): \(buckled.permanent * 1000) mm buckling, \(stiff.permanent * 1000) mm not"
        )
        // Measured 283 mm: within half to twice with buckling; a hundredth of it without.
        #expect(buckled.permanent > 0.14 && buckled.permanent < 0.57)
        #expect(stiff.permanent < 0.03)
        #expect(buckled.failedShells == 0)
    }

    /// An STW35 sheet over two purlins 1.8 m apart, screwed to them, sucked off by `pressure`
    /// loaded slowly: how far its middle rose off the purlins (m).
    static func suction(_ pressure: Float, device: MTLDevice) throws -> (rise: Float, links: Int) {
        let elastic = StructureMaterial.elastic(density: 7850, youngsModulus: 210e9, poissonRatio: 0.3)
        var model = StructureModel(
            solids: [], material: .structuralSteel, elementSize: 0.15, fixedBase: false)
        model.elementKind = .shell
        model.shellLayers = 4
        let sheet = Box(min: SIMD3(0, 0, 0.99), max: SIMD3(1.8, 1.2, 1.01))
        for x in [Float(0), 1.8] {
            // Stiff purlins past the sheet's sides, held at their ends.
            model.solids.append(Box(min: SIMD3(x - 0.06, -0.3, 0.92), max: SIMD3(x + 0.06, 1.5, 1.08)))
            model.setMaterial(elastic, of: model.solids.count - 1)
            for y in [Float(-0.3), 1.5] {
                model.supports.append(
                    Box(min: SIMD3(x - 0.05, y - 0.01, 0.95), max: SIMD3(x + 0.05, y + 0.01, 1.05)))
            }
        }
        model.solids.append(sheet)
        let profile = SheetProfile.swedsteelSTW35
        model.setSheet(
            SheetAssignment(
                profile: profile, ribAxis: 0,
                fastening: .screws(profile: profile, supportThickness: 0.002, perMetre: 1)),
            of: model.solids.count - 1)
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        solver.damping = 60
        // Up, on the underside, over 0.2 s.
        solver.appliedLoad = PressureLoad(
            axis: 2, positiveSide: false, history: [SIMD2(0, 0), SIMD2(0.2, pressure), SIMD2(100, pressure)])
        solver.advance(steps: Int(0.4 / solver.criticalTimeStep))
        return (
            solver.node(solver.nearestNode(to: SIMD3(0.9, 0.6, 1))).displacement.z, solver.mesh.links.count
        )
    }

    @Test(
        "A screwed sheet stays on its purlins below its screws' pull-through by EN 1993-1-3, and comes off above"
    )
    func screws() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // 2.1 kN a screw (pulling out of 2 mm); one a metre, so that the screws give way before the
        // sheet's bending (about 6 kPa): q L / 2 = 2.1 kN/m at 2.3 kPa.
        let screw = Fastening.screws(profile: .swedsteelSTW35, supportThickness: 0.002)
        #expect(abs(screw.tension - 0.45 * 0.0055 * 0.002 * 420e6) < 1)
        let held = try Self.suction(1500, device: device)
        let torn = try Self.suction(4000, device: device)
        print(
            "Sheet on screws: \(held.links) links; middle rose \(held.rise * 1000) mm at 1.5 kPa, \(torn.rise * 1000) mm at 4 kPa"
        )
        #expect(held.links > 0)
        #expect(held.rise < 0.05)
        #expect(torn.rise > 0.3)
    }

    @Test(
        "A cold-formed Zed purlin, simply supported over 6 m, collapses at 8 M_c / L² of its maker's capacity"
    )
    func zedPurlin() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var steel = StructureMaterial.structuralSteel
        steel.yieldStress = 450e6
        steel.hardeningModulus = 0
        let zed = ScenarioPreset.zedPurlin
        let width: Float = 0.12
        var model = StructureModel(
            solids: [Box(min: SIMD3(0, -width / 2, 0.9), max: SIMD3(6, width / 2, 1.1))],
            material: zed.equivalent(of: steel, width: width), elementSize: 0.25, fixedBase: false)
        model.elementKind = .shell
        // Straight and held sideways along its length, as the sheeting it carries holds it: its
        // capacity in bending is the check. Free, the rectangle standing for it is past its
        // lateral-torsional buckling load at 0.9 of collapse and stands only while perfectly
        // symmetric: bowed, or with its fibres' yields raised a little unevenly by the strain-rate
        // law, it buckles sideways first.
        model.memberImperfections = false
        // Collapse at w = 8 M_c / L² per metre: 3.33 kN/m from M_c = 14.98 kN m.
        let collapse: Float = 8 * 14.98e3 / 36
        func deflection(at fraction: Float) throws -> Float {
            let solver = try ShellSolver(device: device, model: model)
            solver.groundContact = false
            solver.gravity = 0
            solver.damping = 80
            let ends = solver.nodes { $0.x < 1e-4 || $0.x > 6 - 1e-4 }
            solver.mutateNodes { nodes in
                for n in nodes.indices { nodes[n].restrain(y: true) }
                for n in ends { nodes[n].restrain(y: true, z: true) }
                nodes[ends[0]].restrain(x: true)
            }
            // The load as the beam's own weight, 4.49 kg/m, under gravity raised over half a
            // second to give it, then held.
            let target = fraction * collapse / 4.49
            let steps = Int(0.01 / solver.criticalTimeStep)
            for n in 1...100 {
                solver.gravity = target * min(1, Float(n) / 50)
                solver.advance(steps: steps)
            }
            return -solver.node(solver.nearestNode(to: SIMD3(3, 0, 1))).displacement.z
        }
        let below = try deflection(at: 0.9)
        let above = try deflection(at: 1.1)
        print("Zed purlin: \(below * 1000) mm at 0.9 of collapse, \(above * 1000) mm at 1.1")
        // Holding at 0.9, running away at 1.1. At 0.9 it bends twice as far as the elastic 44 mm
        // (5 w L⁴ / 384 E I): the rectangle that stands for it yields from two-thirds of its
        // capacity, where a cold-formed section stays elastic nearly to it.
        #expect(below < 0.15)
        #expect(above > 0.3)
    }

    @Test(
        "ADBLAST's 0.75 mm cladding under 1.5 kg of C4 in the air: its first deflection within a quarter of the measured"
    )
    func adblastInAir() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures/ADBLAST2015/tests.json")
        let test = try #require(try AdblastCladdingTest.tests(from: url).first { $0.test == 11 })
        var settings = AdblastCladdingTest.Settings()
        settings.duration = 0.08
        let result = try AdblastCladdingTest.runInAir(test, settings: settings, device: device)
        print(
            "ADBLAST test 11: first \(result.structure.firstPeak * 1000) mm (measured -110); air at the middle "
                + "\(result.reflectedPeak / 1000) kPa, \(result.reflectedImpulse) kPa ms (measured 315, 196)")
        #expect(abs(result.structure.firstPeak / -0.110 - 1) < 0.25)
        #expect(abs(result.reflectedImpulse / 196 - 1) < 0.3)
    }
}
