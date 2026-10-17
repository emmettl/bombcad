import Foundation
import simd

/// "Transport hub, long-span steel and glass roof": a station's train shed beside its concourse
/// (docs/transport-hub.md gives the sources and the choices):
/// - the train shed, built of shells and beams: 36 m clear span (a two-platform, four-track shed)
///   by 48 m, its roof 12 m up on 305 UC columns in frames at 12 m;
/// - across each frame a Vierendeel truss 3 m deep: square hollow chords and posts (axis-aligned
///   members, as the shells' lines lie along the axes; a Warren truss's diagonals would not),
///   300 × 12.5 mm chords and 200 × 10 mm posts at 3 m;
/// - 356 UB purlins at 3 m between the trusses' top chords, carrying 10 mm toughened glass over the
///   whole roof (the structure model's glass is a brittle solid; laminated glass is not built in
///   it);
/// - its ends and sides open to the tracks and platforms.
/// Beside it stands the concourse, 24 × 20 m and 8 m high, as an envelope judged by envelope
/// damage: concrete walls, a glazed front of sixteen 3 × 3 m laminated panes and twelve 3 × 2 m
/// laminated rooflights over the concourse floor (6 + 1.52 mm PVB + 6 mm in structural silicone,
/// `LaminatedGlass.facade`), whose glass, if it goes, falls on the people below
/// (`OverheadGlassHazard`). 100 kg of TNT, a car's worth, stands in the forecourt 20 m in front
/// of both.
extension ScenarioPreset {
    static func transportHubScenario(title: String) -> Scenario {
        let (span, bay, bays, eaves, deep): (Float, Float, Int, Float, Float) = (36, 12, 4, 12, 3)
        let (x0, y0): (Float, Float) = (36, 40)
        let (x1, y1) = (x0 + span, y0 + Float(bays) * bay)
        let top = eaves + deep
        var solids: [Box] = []
        var materials: [StructureMaterial?] = []
        func add(_ box: Box, _ material: StructureMaterial?) {
            solids.append(box)
            materials.append(material)
        }
        /// A square member `side` wide from `a` to `b` along axis `k` through `line`.
        func member(_ section: SteelSection, along k: Int, from a: Float, to b: Float, at line: SIMD3<Float>)
        {
            var low = line
            var high = line
            low[k] = a
            high[k] = b
            for j in 0..<3 where j != k {
                low[j] -= section.width / 2
                high[j] += section.width / 2
            }
            add(Box(min: low, max: high), section.equivalent(width: section.width))
        }
        let column = SteelSection.uc305x305x118
        let chord = SteelSection.squareHollow(side: 0.3, wall: 0.0125)
        let post = SteelSection.squareHollow(side: 0.2, wall: 0.01)
        let purlin = SteelSection.ub356x171x45
        for n in 0...bays {
            let y = y0 + Float(n) * bay
            // Columns, their depth along the truss.
            for x in [x0, x1] {
                let (dx, dy) = (column.depth / 2, column.rectangleWidth / 2)
                add(
                    Box(min: SIMD3(x - dx, y - dy, 0), max: SIMD3(x + dx, y + dy, eaves)), column.equivalent()
                )
            }
            // The Vierendeel truss: its chords at the eaves and 3 m above, posts every 3 m.
            member(chord, along: 0, from: x0, to: x1, at: SIMD3(0, y, eaves))
            member(chord, along: 0, from: x0, to: x1, at: SIMD3(0, y, top))
            for x in stride(from: x0, through: x1 + 0.01, by: 3) {
                member(post, along: 2, from: eaves, to: top, at: SIMD3(x, y, 0))
            }
        }
        // Purlins along the shed at 3 m, on the top chords, their depth up.
        for x in stride(from: x0, through: x1 + 0.01, by: 3) {
            let (dx, dz) = (min(purlin.rectangleWidth, 0.24) / 2, purlin.depth / 2)
            add(
                Box(min: SIMD3(x - dx, y0, top - dz), max: SIMD3(x + dx, y1, top + dz)),
                purlin.equivalent(width: min(purlin.rectangleWidth, 0.24)))
        }
        // The glass over the whole roof, on the purlins' and chords' line.
        add(Box(min: SIMD3(x0, y0, top - 0.005), max: SIMD3(x1, y1, top + 0.005)), .toughenedGlass)

        var structure = StructureModel(
            solids: solids, material: column.equivalent(), elementSize: 0.5, fixedBase: true)
        structure.elementKind = .shell
        structure.shellLayers = 4
        for (index, material) in materials.enumerated() where material != structure.material {
            structure.setMaterial(material, of: index)
        }
        let (cx0, cx1, cy1, ch): (Float, Float, Float, Float) = (6, 30, y0 + 20, 8)
        var scenario = Scenario(
            name: title, domainSize: SIMD3(80, 100, 24), boxes: [],
            charge: Charge(mass: 100, position: SIMD3(33, y0 - 20, 1)),
            gauges: [
                Gauge("Concourse front, outside", at: SIMD3((cx0 + cx1) / 2, y0 - 0.6, 2)),
                Gauge("Concourse, inside", at: SIMD3((cx0 + cx1) / 2, y0 + 10, 2)),
                Gauge("Shed, platform level", at: SIMD3(x0 + span / 2, y0 + bay, 2)),
                Gauge("Shed roof, above", at: SIMD3(x0 + span / 2, y0 + bay / 2, top + 0.8)),
            ],
            structure: structure)
        // The concourse: 0.3 m concrete walls and roof, glazed front and rooflights. Each pane
        // fills its opening through the wall's or roof's thickness, so the air sees it closed at
        // any cell size; envelope damage takes the glass from the construction.
        let wall: Float = 0.3
        let walls = [
            Box(min: SIMD3(cx0, y0, 0), max: SIMD3(cx1, y0 + wall, ch)),
            Box(min: SIMD3(cx0, cy1 - wall, 0), max: SIMD3(cx1, cy1, ch)),
            Box(min: SIMD3(cx0, y0 + wall, 0), max: SIMD3(cx0 + wall, cy1 - wall, ch)),
            Box(min: SIMD3(cx1 - wall, y0 + wall, 0), max: SIMD3(cx1, cy1 - wall, ch)),
            Box(min: SIMD3(cx0, y0, ch), max: SIMD3(cx1, cy1, ch + wall)),
        ]
        var openings: [Box] = []
        for column in 0..<8 {
            let x = cx0 + Float(column) * 3
            for z: Float in [0.5, 4.5] {
                openings.append(Box(min: SIMD3(x, y0, z), max: SIMD3(x + 3, y0 + wall, z + 3)))
            }
        }
        for row in 0..<2 {
            for column in 0..<6 {
                let x = cx0 + 1.5 + Float(column) * 3.5
                let y = y0 + 4 + Float(row) * 8
                openings.append(Box(min: SIMD3(x, y, ch), max: SIMD3(x + 3, y + 2, ch + wall)))
            }
        }
        if let envelope = try? BuildingEnvelope(solids: walls, openings: openings, panes: openings) {
            let id = UUID(uuidString: "5E1D0000-0000-4000-8000-000000000021")!
            _ = try? scenario.addEnvelopeObject(envelope, name: "Concourse (laminated glazing)", id: id)
            scenario.envelopeConstructions = [
                EnvelopeConstruction(
                    objectID: id, wallThicknessM: wall, roofThicknessM: wall, source: .user,
                    detail: "0.3 m reinforced concrete; laminated glass 6 + 1.52 mm PVB + 6 mm in structural "
                        + "silicone, 20 mm bite", laminate: .facade)
            ]
        }
        return scenario
    }
}

extension SteelSection {
    /// A square hollow section `side` wide with walls `wall` thick, its properties from its
    /// dimensions with square corners (the SCI's tables, with rounded corners, give 2–4% less).
    public static func squareHollow(side: Float, wall: Float) -> Self {
        let inner = side - 2 * wall
        return Self(
            name: String(format: "SHS %.0f × %.0f × %.1f", side * 1000, side * 1000, wall * 1000),
            depth: side,
            width: side, area: side * side - inner * inner,
            secondMoment: (pow(side, 4) - pow(inner, 4)) / 12,
            plasticModulus: (pow(side, 3) - pow(inner, 3)) / 4)
    }
}
