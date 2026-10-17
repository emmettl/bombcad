import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Profiled metal sheeting as a skin with the ribs as beams (docs/profiled-sheeting.md).
@Suite("Profiled sheeting", .gpuThreads)
struct ProfiledSheetTests {
    @Test("Section properties match the published ones")
    func sections() {
        // Langdon's Table 7-2, per corrugation: second moment 1.398e-7 m⁴, plastic moment 2273.4
        // N m at 311.4 MPa, neutral axis 17.27 mm above the base (the outside face, a millimetre
        // below the troughs' centreline). Her plastic moment is 3% below this one, whose equal-area
        // axis, 12.36 mm above the base, is hers (12.37 mm).
        let wall = SheetProfile.langdonBlastWall.section
        #expect(abs(wall.secondMoment / 1.398e-7 - 1) < 0.02, "I \(wall.secondMoment)")
        #expect(abs(wall.plasticModulus * 311.4e6 / 2273.4 - 1) < 0.04, "Zp \(wall.plasticModulus)")
        #expect(abs((wall.centroid + 0.001) / 0.01727 - 1) < 0.02, "centroid \(wall.centroid)")
        // Swedsteel's gross properties at 0.63 mm design thickness, per metre (their corners are
        // rounded, 3 mm, which this leaves out).
        for (profile, area, secondMoment) in [
            (SheetProfile.swedsteelSTW35, 745e-6, 126_052e-12),
            (SheetProfile.swedsteelSTR45, 782e-6, 237_204e-12),
        ] {
            let perWidth = profile.perWidth
            #expect(abs(Double(perWidth.area) / area - 1) < 0.03, "\(profile.name): A \(perWidth.area)")
            #expect(
                abs(Double(perWidth.secondMoment) / secondMoment - 1) < 0.03,
                "\(profile.name): I \(perWidth.secondMoment)")
        }
        // A sinusoid's second moment per pitch: t p h² / 8 for a shallow one (h the centreline's
        // depth), a little more for the extra length of its slopes.
        let wave = SheetProfile.sinusoidal76x18
        let h = Double(wave.depth - wave.thickness)
        let shallow = Double(wave.thickness * wave.pitch) * h * h / 8
        #expect(wave.section.secondMoment > shallow && wave.section.secondMoment < 1.3 * shallow)
    }

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

    @Test("The ribs are beams on the skin's midsurface, sharing its nodes, one on each line")
    func mesh() throws {
        let (model, sheet) = Self.panel(steel: .structuralSteel)
        let mesh = try ShellMesh(model: model)
        let lines = sheet.ribLines(elementSize: model.elementSize)
        #expect(lines.count == 16, "\(lines.count) lines")
        let skin = Set(mesh.elements.flatMap { e in (0..<4).map { e.nodes[$0] } })
        #expect(mesh.beams.count == lines.count * 16, "\(mesh.beams.count) beam elements")
        #expect(mesh.beams.allSatisfy { skin.contains($0.nodes[0]) && skin.contains($0.nodes[1]) })
        #expect(mesh.beams.allSatisfy { abs(mesh.positions[Int($0.nodes[0])].y - 0.5) < 1e-5 })
        // The sheet weighs what the profile does.
        let materials = model.materials
        let mass =
            mesh.elements.reduce(Float(0)) { sum, e in
                sum + materials[e.material].density * e.thickness * e.size.x * e.size.y
            }
            + mesh.beams.reduce(Float(0)) { sum, b in
                sum + materials[b.material].density * b.section.x * b.section.y * b.length
            }
        let expected = 7850 * SheetProfile.langdonBlastWall.perWidth.area * 0.88 * 0.915
        #expect(abs(mass / expected - 1) < 0.01, "mass \(mass) kg, expected \(expected) kg")
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

    @Test("Sheeting in the one-way model follows UFC 3-340-02's method for cold-formed panels")
    func oneWay() {
        // STR45 over purlins 1.8 m apart: M = 1.21 × 1.1 × 350 MPa × 6,931 mm³/m; r_u = 10.8 M / L²
        // continuous, 7.2 M / L² a single span; X_E = β r_u L⁴ / (E I).
        let profile = SheetProfile.swedsteelSTR45
        let moment = 1.21 * 1.1 * 350e6 * 6931e-9
        let continuous = EnvelopePanel.profiledSheetOneWay(profile: profile, span: 1.8, continuous: true)
        let single = EnvelopePanel.profiledSheetOneWay(profile: profile, span: 1.8, continuous: false)
        #expect(abs(continuous.ultimateResistance / (10.8 * moment / 3.24) - 1) < 1e-6)
        #expect(abs(single.ultimateResistance / (7.2 * moment / 3.24) - 1) < 1e-6)
        let secondMoment = Double(profile.perWidth.secondMoment)
        let deflection = 0.0062 * continuous.ultimateResistance * pow(1.8, 4) / (210e9 * secondMoment)
        #expect(abs(continuous.backbone[0].x / deflection - 1) < 1e-6)
        #expect(continuous.loadMassElastic == 0.74 && abs(continuous.massPerArea - 7850 * 782e-6) < 0.2)
        // A screw into 2 mm of purlin pulls out at 0.45 d t f_u (2.1 kN), before the 0.63 mm sheet
        // pulls over its 16 mm washer (4.2 kN).
        let screw = EnvelopePanel.screwTension(profile: profile, supportThickness: 0.002)
        #expect(abs(screw - 0.45 * 0.0055 * 0.002 * 420e6) < 1)
        // Graded as PDC-TR 06-08 grades deck limited by its connectors.
        #expect(EnvelopeDamageLevel.profiledSheet(ductility: 0.9, rotationDeg: 0.5) == .none)
        #expect(EnvelopeDamageLevel.profiledSheet(ductility: 1.5, rotationDeg: 1) == .moderate)
        #expect(EnvelopeDamageLevel.profiledSheet(ductility: 1.5, rotationDeg: 1.8) == .heavy)
        #expect(EnvelopeDamageLevel.profiledSheet(ductility: 5, rotationDeg: 3) == .hazardous)
        #expect(EnvelopeDamageLevel.profiledSheet(ductility: 8, rotationDeg: 3) == .failed)
    }

    @Test(
        "Langdon's panels in the one-way model: below 1 bar elastic peaks as a beam's, above it the safe side"
    )
    func langdonOneWay() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures/Langdon2003/panels.json")
        let panels = try LangdonPanelTest.panels(from: url)
        // Her steel's measured yield, so only UFC's dynamic increase.
        let system = EnvelopePanel.profiledSheetOneWay(
            profile: .langdonBlastWall, span: 0.915, continuous: false, strengthIncrease: 1.1)
        var ratios: [(peak: Float, ratio: Double)] = []
        for panel in panels where panel.isPositive && panel.peakDeflectionMM != nil {
            let step = 1e-4
            let pressures = stride(from: 0.0, through: 0.3, by: step).map { t -> Double in
                let pulse = panel.pulse
                for (a, b) in zip(pulse, pulse.dropFirst()) where t <= Double(b.x) {
                    return Double(a.y) + Double(b.y - a.y) * (t - Double(a.x)) / Double(b.x - a.x)
                }
                return 0
            }
            let response = system.response(pressures: pressures, step: step)
            ratios.append(
                (panel.peakBarg, response.peakDeflection * 1000 / Double(panel.peakDeflectionMM!)))
        }
        let text = ratios.map { String(format: "%.2f bar %.2f", $0.peak, $0.ratio) }
        print("Langdon's elastic peaks, one-way model over measured: \(text)")
        // Below 1 bar, like her own beam model, 0.6–1.2 of what was measured: the panels were softer
        // than a beam of their section. At 1.04–1.05 bar the single span has yielded (r_u 0.96 bar)
        // where the panels, their ends partly fixed, had not: well over, the safe side.
        let elastic = ratios.filter { $0.peak < 1 }.map(\.ratio)
        #expect(ratios.count == 11 && elastic.count == 9 && elastic.allSatisfy { $0 > 0.6 && $0 < 1.2 })
        #expect(ratios.filter { $0.peak >= 1 }.allSatisfy { $0.ratio > 1.5 })
    }
}
