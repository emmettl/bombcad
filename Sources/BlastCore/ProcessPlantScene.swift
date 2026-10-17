import Foundation
import simd

/// An accidental vapour cloud explosion at a process plant, beside the buildings people work in:
/// the layout of BP's Texas City refinery on 23 March 2005 as the US Chemical Safety Board
/// reported it (Investigation Report 2005-04-I-TX, March 2007), drawn smaller (see
/// docs/process-plant-explosion.md for every figure and its source).
///
/// - A congested process area, 34 by 40 m: two pipe racks of three tiers and the blowdown drum
///   and its stack, with a tower and vessels, all rigid.
/// - A cloud of stoichiometric propane over it, 6 m deep, standing for the raffinate's vapour
///   (C5 to C8 alkanes, medium reactivity in the Baker–Strehlow–Tang scheme, as propane is); lit
///   7.6 m from the drum, where the idling pickup stood.
/// - A steel blast-resistant module (12 × 3.66 × 3.14 m, a 40 × 12 × 10.3 ft unit of 1/4 in
///   plate on a steel frame) 37 m from the drum, the double-wide trailer's distance, and a
///   steel-skinned portable cabin (30 × 8 ft, the QA/QC trailer's plan) 46 m from it, both
///   resting on the ground.
/// - Further off, a brick control room at 62 m and a concrete office at 108 m, as envelope
///   buildings with windows, for their components' damage.
public enum ProcessPlantScene {
    /// The drum's centre on plan: every distance in the scene is measured from it, as the CSB's are.
    public static let drum = SIMD2<Float>(20, 40)
    public static let domain = SIMD3<Float>(150, 80, 24)
    /// Where the pickup stood: 25 ft (7.6 m) from the drum.
    public static let ignition = SIMD3<Float>(27.6, 40, 0.5)
    /// The cloud: the process area and 10 m beyond it towards the buildings, 6 m deep.
    public static let cloud = Box(min: SIMD3(0, 16, 0), max: SIMD3(46, 64, 6))
    /// The burning velocity's multiple for the congestion the model does not resolve, fitted to
    /// the CSB's estimate at the trailers.
    public static let congestionFactor: Float = 6.5

    static let controlRoomID = UUID(uuidString: "6A0C0B1E-0000-4000-8000-000000000001")!
    static let officeID = UUID(uuidString: "6A0C0B1E-0000-4000-8000-000000000002")!

    /// The rigid plant: pipe racks, the drum and its stack, a tower and two vessels.
    static var plant: [Box] {
        var boxes: [Box] = []
        // Two pipe racks along x, 8 m wide, 34 m long, portal columns every 6 m; three tiers at
        // 4, 7 and 10 m, each of five pipes 0.5 m across at 1.5 m centres (a third of the tier's
        // area blocked, "high" congestion's 40% being the next step up) on cross beams.
        let columnsAt: [Float] = [2, 8, 14, 20, 26, 32, 36]
        for y0: Float in [26, 46] {
            for x in columnsAt {
                for y in [y0, y0 + 7.5] {
                    boxes.append(Box(x: x...(x + 0.5), y: y...(y + 0.5), height: 10.5))
                }
            }
            for z: Float in [4, 7, 10] {
                for x in columnsAt {
                    boxes.append(Box(min: SIMD3(x, y0, z - 0.3), max: SIMD3(x + 0.5, y0 + 8, z)))
                }
                for n in 0..<5 {
                    let y = y0 + 0.5 + 1.5 * Float(n)
                    boxes.append(Box(min: SIMD3(2, y, z), max: SIMD3(36.5, y + 0.5, z + 0.5)))
                }
            }
        }
        // The blowdown drum, 3 m across and 8 m tall, and its stack to the domain's top (36 m
        // above ground at Texas City). The raffinate splitter tower, 3.8 m across (52 m tall there).
        boxes.append(Box(min: SIMD3(18.5, 38.5, 0), max: SIMD3(21.5, 41.5, 8)))
        boxes.append(Box(min: SIMD3(19.6, 39.6, 8), max: SIMD3(20.4, 40.4, 23)))
        boxes.append(Box(min: SIMD3(6, 38, 0), max: SIMD3(9.8, 41.8, 22)))
        // Horizontal vessels on saddles, 3 m across and 8 m long.
        boxes.append(Box(min: SIMD3(4, 18, 0), max: SIMD3(12, 21, 3)))
        boxes.append(Box(min: SIMD3(24, 57, 0), max: SIMD3(32, 60, 3)))
        return boxes
    }

    /// A building of plates as shells on a frame of bars as beams, resting on the ground.
    static func steelBox(
        at origin: SIMD3<Float>, size: SIMD3<Float>, plate: Float, frame: Float, spacing: Float,
        elementSize: Float
    ) -> StructureModel {
        let (x0, y0, z0) = (origin.x, origin.y, origin.z)
        let (x1, y1, z1) = (x0 + size.x, y0 + size.y, z0 + size.z)
        var solids: [Box] = [
            Box(min: SIMD3(x0, y0, z0), max: SIMD3(x1, y0 + plate, z1)),  // walls
            Box(min: SIMD3(x0, y1 - plate, z0), max: SIMD3(x1, y1, z1)),
            Box(min: SIMD3(x0, y0, z0), max: SIMD3(x0 + plate, y1, z1)),
            Box(min: SIMD3(x1 - plate, y0, z0), max: SIMD3(x1, y1, z1)),
            Box(min: SIMD3(x0, y0, z1 - plate), max: SIMD3(x1, y1, z1)),  // roof
            Box(min: SIMD3(x0, y0, z0), max: SIMD3(x1, y1, z0 + plate)),  // floor
        ]
        // Frame columns inside the long walls, and roof joists across, at `spacing`.
        let along = max(1, Int((size.x / spacing).rounded()))
        for n in 0...along {
            let x = min(x0 + Float(n) * size.x / Float(along), x1 - frame)
            for y in [y0 + plate, y1 - plate - frame] {
                solids.append(Box(min: SIMD3(x, y, z0), max: SIMD3(x + frame, y + frame, z1)))
            }
            solids.append(Box(min: SIMD3(x, y0, z1 - plate - frame), max: SIMD3(x + frame, y1, z1 - plate)))
        }
        var model = StructureModel(solids: solids, material: .structuralSteel, elementSize: elementSize)
        model.elementKind = .shell
        model.baseAnchorage = .resting(friction: 0.5)
        return model
    }

    /// The blast-resistant module: 40 × 12 × 10.3 ft (12.2 × 3.66 × 3.14 m), walls, roof and floor
    /// of 1/4 in (6.35 mm) plate, flat here where the real plate is corrugated, on 0.1 m steel bars
    /// standing for its HSS frame (the stiffness of an HSS 6 × 6 × 3/8, at twice its mass) at about
    /// 1.5 m: seven columns along each long wall, as the units tested by Omega-Risk had.
    static var module: StructureModel {
        let x = drum.x + 37
        return steelBox(
            at: SIMD3(x, 34, 0), size: SIMD3(3.66, 12.2, 3.14), plate: 0.00635, frame: 0.1, spacing: 1.5,
            elementSize: 0.25)
    }

    /// The portable cabin: 30 × 8 ft (9.14 × 2.44 m), 2.6 m high, of 1.5 mm steel sheet on 50 mm
    /// steel bars at 1.2 m: an ordinary site cabin, a metal trailer in the CSB's terms.
    static var cabin: StructureModel {
        steelBox(
            at: SIMD3(drum.x + 46, 18, 0), size: SIMD3(2.44, 9.14, 2.6), plate: 0.0015, frame: 0.05,
            spacing: 1.2, elementSize: 0.25)
    }

    /// A single-storey building with windows in its walls facing the plant and away from it, on a
    /// footprint of whole metres. A block is solid in the air where it holds a cell's centre, so a
    /// wall thinner than a cell can fall between them and leave the building see-through: each wall
    /// and the roof stand 0.2 m inside the footprint's whole-metre lines, where they hold a centre
    /// on 0.5, 0.25 and 0.125 m cells alike. The panes fill their openings; the glass's own
    /// thickness is the construction's (`EnvelopeConstruction.glassThicknessM`).
    static func envelope(
        x: ClosedRange<Float>, y: ClosedRange<Float>, height: Float, wall: Float, windows: Int
    ) throws -> BuildingEnvelope {
        let inset: Float = 0.2
        let (x0, x1) = (x.lowerBound + inset, x.upperBound - inset)
        let (y0, y1) = (y.lowerBound + inset, y.upperBound - inset)
        let top = height - inset
        let solids = [
            Box(min: SIMD3(x0, y0, 0), max: SIMD3(x0 + wall, y1, top)),
            Box(min: SIMD3(x1 - wall, y0, 0), max: SIMD3(x1, y1, top)),
            Box(min: SIMD3(x0, y0, 0), max: SIMD3(x1, y0 + wall, top)),
            Box(min: SIMD3(x0, y1 - wall, 0), max: SIMD3(x1, y1, top)),
            Box(min: SIMD3(x0, y0, top - wall), max: SIMD3(x1, y1, top)),
        ]
        var openings: [Box] = []
        let span = (y1 - y0) / Float(windows)
        for n in 0..<windows {
            let low = y0 + span * (Float(n) + 0.5) - 0.6
            for face in [x0, x1 - wall] {
                openings.append(Box(min: SIMD3(face, low, 1), max: SIMD3(face + wall, low + 1.2, 2.2)))
            }
        }
        return try BuildingEnvelope(solids: solids, openings: openings, panes: openings)
    }

    public static var scenario: Scenario {
        var scenario = Scenario(
            name: ScenarioPreset.processPlantExplosion.title, domainSize: domain, boxes: plant,
            charge: Charge(mass: 0, position: ignition),
            gauges: [
                Gauge("In the process area", at: SIMD3(24, 36, 1.5)),
                Gauge("Free field, 37 m", at: SIMD3(drum.x + 37, 54, 1.5)),
                Gauge("Module, front", at: SIMD3(drum.x + 36.9, 40, 1.5)),
                Gauge("Cabin, front", at: SIMD3(drum.x + 45.9, 22.5, 1.5)),
                Gauge("Control room, front", at: SIMD3(81.9, 57, 1.5)),
                Gauge("Office, front", at: SIMD3(127.9, 40, 1.5)),
                Gauge("Free field, 100 m", at: SIMD3(drum.x + 100, 70, 1.5)),
            ],
            structure: module)
        _ = try? scenario.addStructureObject(cabin, name: "Portable cabin")
        scenario.objects[scenario.objects.firstIndex { $0.structure != nil }!].name = "Blast-resistant module"
        // The flame's speed-up by congestion, which the model does not resolve, as its burning
        // velocity times a factor fitted to the CSB's 2.5–2.8 psi at the trailers (6 gives 2.25 psi
        // at 37 m, 7 gives 3.2; 1, the model alone, 0.01 psi): see docs/process-plant-explosion.md.
        var acceleration = FlameAcceleration()
        acceleration.factor = congestionFactor
        scenario.deflagration = Deflagration(
            gas: .propane, region: cloud, ignition: ignition, acceleration: acceleration)
        // The ISOM unit's satellite control room was masonry (1.5–2.5 psi there, heavily damaged);
        // a 0.215 m brick control room, 9.6 m square and 4.8 m high, 62 m from the drum; and a 0.2 m
        // concrete office, 14.6 × 19.6 m and 4.8 m high, 108 m from it. Annealed glass, 6 mm.
        if let room = try? envelope(x: 82...92, y: 52...62, height: 5, wall: 0.215, windows: 3) {
            _ = try? scenario.addEnvelopeObject(room, name: "Control room (brick)", id: controlRoomID)
        }
        if let office = try? envelope(x: 128...143, y: 30...50, height: 5, wall: 0.2, windows: 5) {
            _ = try? scenario.addEnvelopeObject(office, name: "Office (concrete)", id: officeID)
        }
        scenario.envelopeConstructions = [
            EnvelopeConstruction(
                objectID: controlRoomID, walls: .unreinforcedMasonry, wallThicknessM: 0.215, source: .user,
                detail: "brick control room, as the ISOM satellite control room was masonry (CSB H.5)"),
            EnvelopeConstruction(
                objectID: officeID, source: .user, detail: "0.2 m reinforced concrete office, 0.3% each way"),
        ]
        return scenario
    }
}
