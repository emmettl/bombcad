import Foundation
import simd

/// A twelve-storey block of flats of large precast panels, of the Ronan Point type: storey-high
/// load-bearing wall panels standing on precast floors, joined by breakable connections, with no
/// frame. A showcase of progressive collapse through the joints, not a validated model.
///
/// Proportions and joints follow the inquiry into Ronan Point's partial collapse (H. Griffiths,
/// A. Pugsley and O. Saunders, *Report of the Inquiry into the Collapse of Flats at Ronan Point,
/// Canning Town*, Ministry of Housing and Local Government, HMSO, 1968):
/// - **Panels** (§103): wall panels a storey high, about 8 ft, and six or seven inches thick, of
///   solid concrete; floors of precast slabs seven inches thick spanning 13 to 15 ft between the
///   flank and cross walls and resting at their ends upon them (§101). Concrete specified at
///   5,700 psi on works cubes at 28 days (§108), about 31 MPa on cylinders.
/// - **Plan:** the corner flat's depth to the corridor, 29 ft (Plan (b)), the walls' bays 14 ft 4
///   in apart. Ronan Point had 22 storeys and five flats a floor about a central corridor (§39);
///   this block keeps one side of it, three bays long, and twelve storeys.
/// - **Joints** (§104–106, §112–113, Figures C–F): each wall panel stands on dry-packed mortar on
///   the floor below and the floors rest on the walls; at the flank (end) walls (joint H.2) the
///   floor is tied to the wall only by a strap over a lifting bolt, which the inquiry found
///   loosely bolted through oval slots, and the joint holds by friction; at the cross walls the
///   ends of opposing floor slabs are joined by in-situ concrete with bars.
///
/// As meshed here, on elements of 87.5 mm (two through each wall and floor):
/// - each storey's floor is one plate over the whole plan, continuous over the cross walls (the
///   in-situ joint with its bars), and each wall line is one panel along its length (the
///   vertical joints of Figure C, in-situ concrete through U-bars, taken as continuous);
/// - each wall stands on the floor below across a gap of one element and the floor above rests
///   on it across another (the joints as `Anchorage.betweenParts`): at the flank walls friction
///   alone (`resting(friction: 0.7)`, mortar on concrete as Batalha's seats measured), at the
///   cross walls a construction joint (1 MPa tension, 1.3 MPa cohesion, friction 0.7);
/// - the non-load-bearing face walls, 87.5 mm of lighter concrete with a window in each bay,
///   hang between the wall lines, bonded to them as on the ledges of §102;
/// - the ground floor's walls are clamped to the podium.
public enum LargePanelBlock {
    /// The element size: two through the 175 mm (7 in) walls and floors.
    public static let h: Float = 0.0875
    public static let storeys = 12
    /// A storey: a wall panel 26 elements (2.275 m) high, a joint, the floor (2), a joint.
    public static let storeyHeight: Float = 30 * h
    /// Along the block (x): four wall lines 50 elements (4.375 m) apart, centre to centre.
    public static let length: Float = 150 * h
    /// Across it (y): the flat's depth, 8.75 m.
    public static let depth: Float = 100 * h
    public static var height: Float { Float(storeys) * storeyHeight }
    /// The wall lines' extents along x, flank, cross, cross, flank.
    public static let wallLines: [(low: Float, high: Float)] = [
        (0, 2 * h), (49 * h, 51 * h), (99 * h, 101 * h), (148 * h, 150 * h),
    ]
    /// The bays between them.
    public static let bays: [(low: Float, high: Float)] = [
        (2 * h, 49 * h), (51 * h, 99 * h), (101 * h, 148 * h),
    ]

    /// The block's corner in the domain.
    static let origin = SIMD3<Float>(4, 4, 0)

    /// The base of storey `s` (0 at the ground).
    public static func base(ofStorey s: Int) -> Float { Float(s) * storeyHeight }

    /// A window in each bay of each face: 2.1 m wide, 1.4 m high, its sill 0.875 m up.
    public static func window(storey s: Int, bay b: Int, back: Bool) -> Box {
        let z0 = base(ofStorey: s) + 10 * h
        let middle = 0.5 * (bays[b].low + bays[b].high)
        let y: ClosedRange<Float> = back ? (depth - h - 0.01)...(depth + 0.01) : -0.01...(h + 0.01)
        return Box(
            min: origin + SIMD3(middle - 12 * h, y.lowerBound, z0),
            max: origin + SIMD3(middle + 12 * h, y.upperBound, z0 + 16 * h))
    }

    /// The structure.
    /// The structure, `storeys` high (twelve unless asked).
    public static func model(storeys: Int = storeys) -> StructureModel {
        let o = origin
        var walls: [Box] = []
        var floors: [Box] = []
        var faces: [Box] = []
        for s in 0..<storeys {
            let z0 = base(ofStorey: s)
            for line in wallLines {
                walls.append(
                    Box(min: o + SIMD3(line.low, 0, z0), max: o + SIMD3(line.high, depth, z0 + 26 * h)))
            }
            for bay in bays {
                for (y0, y1) in [(Float(0), h), (depth - h, depth)] {
                    faces.append(
                        Box(min: o + SIMD3(bay.low, y0, z0), max: o + SIMD3(bay.high, y1, z0 + 26 * h)))
                }
            }
            floors.append(Box(min: o + SIMD3(0, 0, z0 + 27 * h), max: o + SIMD3(length, depth, z0 + 29 * h)))
        }
        // Concrete specified at 5,700 psi on cubes, about 31 MPa on cylinders; mild steel bars.
        let mild = SteelProperties(
            yieldStress: 250e6, ultimateStress: 410e6, ultimateStrain: 0.15, ruptureStrain: 0.25)
        var wall = StructureMaterial.concrete(
            name: "Precast wall panel", compressiveStrength: 31e6, steel: mild)
        wall.rateDependent = true
        // The floor slabs are cored: about four fifths solid.
        var floor = StructureMaterial.concrete(
            name: "Precast floor slab", compressiveStrength: 31e6, density: 1920, steel: mild)
        floor.rateDependent = true
        var face = StructureMaterial.concrete(
            name: "Face wall", compressiveStrength: 20e6, density: 1800, steel: mild)
        face.rateDependent = true
        var model = StructureModel(
            solids: walls + floors + faces, material: wall, elementSize: h, fixedBase: true)
        for index in walls.indices {
            // A light mesh at the middle of the panel, for handling.
            model.setReinforcement(.mats(areaPerMetre: 142e-6, depth: h, bothFaces: false), of: index)
        }
        for index in floors.indices {
            // Bars in the slabs' soffits, 10 mm at 150 mm each way, 30 mm in.
            model.setReinforcement(
                .mats(areaPerMetre: 524e-6, depth: 0.03, bothFaces: false), of: walls.count + index)
            model.setMaterial(floor, of: walls.count + index)
        }
        for index in faces.indices {
            model.setReinforcement(
                .mats(areaPerMetre: 142e-6, depth: h / 2, bothFaces: false),
                of: walls.count + floors.count + index)
            model.setMaterial(face, of: walls.count + floors.count + index)
        }
        model.autoReinforce()
        model.openings = (0..<storeys).flatMap { s in
            (0..<bays.count).flatMap { b in
                [window(storey: s, bay: b, back: false), window(storey: s, bay: b, back: true)]
            }
        }
        // The joints: under each floor (the walls below carrying it) and over it (the walls above
        // standing on it), along each wall line.
        var flank = Anchorage.resting(friction: 0.7)
        flank.betweenParts = true
        var cross = Anchorage.constructionJoint
        cross.betweenParts = true
        for s in 0..<storeys {
            let z0 = base(ofStorey: s)
            for (n, line) in wallLines.enumerated() {
                let law = n == 0 || n == wallLines.count - 1 ? flank : cross
                for gap in s == storeys - 1 ? [26 * h] : [26 * h, 29 * h] {
                    model.supports.append(
                        Box(
                            min: o + SIMD3(line.low - 0.01, -0.01, z0 + gap - 0.01),
                            max: o + SIMD3(line.high + 0.01, depth + 0.01, z0 + gap + h + 0.01)))
                    model.supportAnchorages.append(law)
                }
            }
        }
        return model
    }

    /// The two events the presets show.
    public enum Event: String, Sendable, CaseIterable {
        /// Methane in the back half of the corner flat on the tenth floor (Ronan Point's was
        /// town gas, in the hall of a corner flat on the eighteenth of 22), lit at the cooker;
        /// the flat's two windows break at 3 kPa.
        case gas
        /// A charge in the street, 8 m from the far flank wall at the ground.
        case street
    }

    /// The tenth floor (index 9), whose corner flat holds the gas.
    public static let gasStorey = 9
    public static let streetCharge: Float = 250
    public static let streetDistance: Float = 8

    public static func scenario(_ event: Event, name: String, storeys: Int = storeys) -> Scenario {
        let o = origin
        let model = model(storeys: storeys)
        let height = Float(storeys) * storeyHeight
        switch event {
        case .gas:
            let z0 = base(ofStorey: gasStorey)
            // The joints' gaps are a mesh's device (each wall and floor a part, a gap of one
            // element apart); in the building they are mortar. The air sees a cell as solid when
            // a third of it is full of elements, and on cells finer than two of them (0.175 m)
            // a row of cells along each gap is left open: the flat vented through slots round
            // every wall, 4.5 m² of them, and its gas burnt at under 0.3 kPa. So the gaps above
            // and below the corner flat, out to the far side of its cross wall, are filled with
            // rigid scenery for the air, as the mortar bed and screed: they do not touch the
            // panels, and stay where they are when the panels move.
            let floor = z0  // the top of the bed on the floor below
            let ceiling = z0 + 26 * h
            let beds = [z0 - h, z0 + 26 * h].map {
                Box(min: o + SIMD3(0, 0, $0), max: o + SIMD3(wallLines[1].high, depth, $0 + h))
            }
            let bay = bays[0]
            let region = Box(
                min: o + SIMD3(bay.low, 0.5 * depth, floor), max: o + SIMD3(bay.high, depth - h, ceiling))
            let cooker = o + SIMD3(bay.high - 0.5, depth - h - 0.4, z0 + 0.9)
            var scenario = Scenario(
                name: name, domainSize: SIMD3(o.x + length + 4, o.y + depth + 4, height + 4), boxes: beds,
                charge: Charge(mass: 0, position: cooker),
                gauges: [
                    Gauge(
                        "Corner flat, middle",
                        at: o + SIMD3(0.5 * (bay.low + bay.high), 0.5 * depth, z0 + 1.2)),
                    Gauge("Flank wall, inside", at: o + SIMD3(bay.low + 0.3, 0.5 * depth, z0 + 1.2)),
                    Gauge("Outside the flank", at: o + SIMD3(-1, 0.5 * depth, z0 + 1.2)),
                ],
                structure: model)
            scenario.deflagration = Deflagration(gas: .methane, region: region, ignition: cooker)
            scenario.ventPanels = [false, true].map {
                VentPanel(box: window(storey: gasStorey, bay: 0, back: $0), releasePressure: 3000)
            }
            return scenario
        case .street:
            let x = o.x + length + streetDistance
            return Scenario(
                name: name, domainSize: SIMD3(x + 6, o.y + depth + 4, height + 4), boxes: [],
                charge: Charge(mass: streetCharge, position: SIMD3(x, o.y + 0.5 * depth, 1)),
                gauges: [
                    Gauge("Flank wall, ground floor", at: SIMD3(o.x + length + 0.4, o.y + 0.5 * depth, 1.2)),
                    Gauge(
                        "Flank wall, fourth floor",
                        at: SIMD3(o.x + length + 0.4, o.y + 0.5 * depth, 3 * storeyHeight + 1.2)),
                    Gauge("Roof", at: SIMD3(o.x + 0.5 * length, o.y + 0.5 * depth, height + 0.5)),
                ],
                structure: model)
        }
    }
}
