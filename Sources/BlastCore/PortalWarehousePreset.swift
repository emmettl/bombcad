import Foundation
import simd

/// "Portal-frame warehouse, profiled steel cladding": a single-span steel shed of the usual
/// proportions (docs/profiled-sheeting.md gives the sources), built of shells:
/// - a 30 m span, the efficient 25–35 m, with frames at 6 m (6–8 m), four bays, 24 m long, and
///   8 m to the eaves; the roof is flat at the eaves where a real one rises at 6° (1.6 m to the
///   ridge), as the shells' plates lie along the axes;
/// - columns of 533 × 210 × 92 UB and rafters of 457 × 191 × 67 UB, the columns about 1.5 times
///   the rafters' plastic modulus as the guidance has it (sized here, not taken from a design),
///   joined rigidly without haunches, the columns clamped at their bases;
/// - Zed purlins and side rails, 200 mm deep and 1.6 mm thick, about 1.8 m apart, continuous;
///   gable posts at 6 m;
/// - trapezoidal steel sheets, 32 mm deep on the walls and 45 mm on the roof, 0.7 mm, as
///   `ProfiledSheet`, sharing the purlins' and rails' nodes (screwed, without pull-out here).
/// A neighbouring unit of the same construction stands behind it as an envelope, its sheeting
/// judged by the one-way model. 100 kg of TNT, a car's worth, stands 30 m from the front gable.
extension ScenarioPreset {
    /// Hadley UltraZED 200/1.6, S450GD: 4.49 kg/m, I = 341.85 cm⁴, moment capacity 14.98 kN m
    /// (its effective modulus at 450 MPa).
    static let zedPurlin = SteelSection(
        name: "Zed purlin 200 × 1.6", depth: 0.2, width: 0.075, area: 4.49 / 7850, secondMoment: 341.85e-8,
        plasticModulus: 14.98e3 / 450e6)

    static func portalWarehouseScenario(title: String) -> Scenario {
        let (span, bay, bays, eaves): (Float, Float, Int, Float) = (30, 6, 4, 8)
        let (x0, y0): (Float, Float) = (20, 40)
        let (x1, y1) = (x0 + span, y0 + Float(bays) * bay)
        var solids: [Box] = []
        var materials: [StructureMaterial?] = []
        var sheets: [(index: Int, profile: SheetProfile)] = []
        func add(_ box: Box, _ material: StructureMaterial?) {
            solids.append(box)
            materials.append(material)
        }
        func beam(_ section: SteelSection, along k: Int, from a: Float, to b: Float, at line: SIMD3<Float>) {
            // Its depth across the plane it lies in (up for a rafter or purlin, out of a wall for a
            // rail), its width the other way, no more than 0.24 m (as the office's beams).
            var low = line
            var high = line
            low[k] = a
            high[k] = b
            let width = min(section.rectangleWidth, 0.24)
            for j in 0..<3 where j != k {
                let half = (j == 2 ? section.depth : width) / 2
                low[j] -= half
                high[j] += half
            }
            add(Box(min: low, max: high), section.equivalent(width: width))
        }
        let column = SteelSection.ub533x210x92
        let rafter = SteelSection.ub457x191x67
        var purlinSteel = StructureMaterial.structuralSteel
        purlinSteel.yieldStress = 450e6
        let purlin = zedPurlin
        // The frames, across the shed: columns in the side walls (x = x0 and x1), their depth in the
        // frame's plane, and the rafter at the eaves.
        for n in 0...bays {
            let y = y0 + Float(n) * bay
            for x in [x0, x1] {
                let (dx, dy) = (column.depth / 2, min(column.rectangleWidth, 0.24) / 2)
                add(
                    Box(min: SIMD3(x - dx, y - dy, 0), max: SIMD3(x + dx, y + dy, eaves)),
                    column.equivalent(width: 0.24))
            }
            beam(rafter, along: 0, from: x0, to: x1, at: SIMD3(0, y, eaves))
        }
        // Gable posts at 6 m between the corner columns, the same section, bending out of the gable.
        for y in [y0, y1] {
            for x in stride(from: x0 + bay, to: x1 - 1, by: bay) {
                let half = column.depth / 2
                add(
                    Box(min: SIMD3(x - 0.12, y - half, 0), max: SIMD3(x + 0.12, y + half, eaves)),
                    column.equivalent(width: 0.24))
            }
        }
        // Purlins from gable to gable at about 1.8 m (17 spaces of 1.76 m), rails round the walls
        // at 1.8 m up to 7.2 m.
        let purlins = 17
        for n in 0...purlins {
            let x = x0 + span * Float(n) / Float(purlins)
            add(
                Box(min: SIMD3(x - 0.06, y0, eaves - 0.1), max: SIMD3(x + 0.06, y1, eaves + 0.1)),
                purlin.equivalent(of: purlinSteel, width: 0.12))
        }
        for z in stride(from: Float(1.8), through: 7.2, by: 1.8) {
            for y in [y0, y1] {
                add(
                    Box(min: SIMD3(x0, y - 0.1, z - 0.06), max: SIMD3(x1, y + 0.1, z + 0.06)),
                    purlin.equivalent(of: purlinSteel, width: 0.12))
            }
            for x in [x0, x1] {
                add(
                    Box(min: SIMD3(x - 0.1, y0, z - 0.06), max: SIMD3(x + 0.1, y1, z + 0.06)),
                    purlin.equivalent(of: purlinSteel, width: 0.12))
            }
        }
        // The sheeting: the walls' up the walls, the roof's across the purlins.
        let wallSheet = SheetProfile.swedsteelSTW35
        let roofSheet = SheetProfile.swedsteelSTR45
        for (box, profile) in [
            (Box(min: SIMD3(x0, y0 - 0.02, 0), max: SIMD3(x1, y0 + 0.02, eaves)), wallSheet),
            (Box(min: SIMD3(x0, y1 - 0.02, 0), max: SIMD3(x1, y1 + 0.02, eaves)), wallSheet),
            (Box(min: SIMD3(x0 - 0.02, y0, 0), max: SIMD3(x0 + 0.02, y1, eaves)), wallSheet),
            (Box(min: SIMD3(x1 - 0.02, y0, 0), max: SIMD3(x1 + 0.02, y1, eaves)), wallSheet),
            (Box(min: SIMD3(x0, y0, eaves - 0.02), max: SIMD3(x1, y1, eaves + 0.02)), roofSheet),
        ] {
            add(box, .structuralSteel)
            sheets.append((solids.count - 1, profile))
        }
        var structure = StructureModel(
            solids: solids, material: column.equivalent(width: 0.24), elementSize: 0.5, fixedBase: true)
        structure.elementKind = .shell
        structure.shellLayers = 4
        for (index, material) in materials.enumerated() where material != structure.material {
            structure.setMaterial(material, of: index)
        }
        for sheet in sheets {
            structure.setSheet(
                SheetAssignment(profile: sheet.profile, on: solids[sheet.index]), of: sheet.index)
        }
        var scenario = Scenario(
            name: title, domainSize: SIMD3(70, 104, 20), boxes: [],
            charge: Charge(mass: 100, position: SIMD3(x0 + span / 2, y0 - 30, 1)),
            gauges: [
                Gauge("Front gable, outside", at: SIMD3(x0 + span / 2, y0 - 0.6, 4)),
                Gauge("Inside, middle", at: SIMD3(x0 + span / 2, (y0 + y1) / 2, 4)),
                Gauge("Roof, above", at: SIMD3(x0 + span / 2, y0 + bay, eaves + 0.6)),
                Gauge("Behind", at: SIMD3(x0 + span / 2, y1 + 6, 4)),
            ],
            structure: structure)
        // The neighbouring unit, 20 m behind: a 24 × 18 m shed 7 m to the eaves, sheeted.
        let (n0, n1): (Float, Float) = (y1 + 14, y1 + 32)
        let unit = [
            Box(min: SIMD3(x0 + 3, n0, 0), max: SIMD3(x0 + 27, n0 + 0.05, 7)),
            Box(min: SIMD3(x0 + 3, n1 - 0.05, 0), max: SIMD3(x0 + 27, n1, 7)),
            Box(min: SIMD3(x0 + 3, n0 + 0.05, 0), max: SIMD3(x0 + 3.05, n1 - 0.05, 7)),
            Box(min: SIMD3(x0 + 26.95, n0 + 0.05, 0), max: SIMD3(x0 + 27, n1 - 0.05, 7)),
            Box(min: SIMD3(x0 + 3, n0, 7), max: SIMD3(x0 + 27, n1, 7.05)),
        ]
        if let envelope = try? BuildingEnvelope(solids: unit) {
            let id = UUID(uuidString: "5E1D0000-0000-4000-8000-000000000017")!
            _ = try? scenario.addEnvelopeObject(envelope, name: "Neighbouring unit (sheeted)", id: id)
            var construction = EnvelopeConstruction(
                objectID: id, walls: .profiledSteelSheeting, roof: .profiledSteelSheeting, source: .user,
                detail: "profiled steel sheeting on rails and purlins 1.8 m apart, as the warehouse")
            construction.sheetSpanM = 1.8
            scenario.envelopeConstructions = [construction]
        }
        return scenario
    }
}

extension SteelSection {
    /// 533 × 210 × 92 UB: a portal frame's column (SCI P363).
    public static let ub533x210x92 = Self(
        name: "533×210×92 UB", depth: 0.5331, width: 0.2093, area: 117e-4, secondMoment: 55_230e-8,
        plasticModulus: 2360e-6)
}
