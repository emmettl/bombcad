import Foundation
import simd

/// Populated scenes for freestanding objects: every object in the air, moving through its load
/// and contact (see `FreestandingMotion`, `ExperimentalRigidWorldSimulation`). Their structures
/// are rigid blocks, held still; the objects rest on the ground under gravity, held by friction
/// alone, fixed to nothing. Nothing here is validated against an experiment.
public enum PopulatedScene: String, CaseIterable, Codable, Sendable {
    /// The car park layout with 17 saloons parked in three rows, 100 kg in a car on the ground
    /// floor.
    case carPark
    /// A room with tables, chairs, a desk, a sofa and cabinets as boxes, 1 kg inside.
    case furnishedRoom
    /// The crowded case: 48 boxes stacked three high in a pen beside 2 kg.
    case crowdedPen

    public var title: String {
        switch self {
        case .carPark: "Car park with parked cars"
        case .furnishedRoom: "Furnished room"
        case .crowdedPen: "Crowded pen of boxes"
        }
    }

    /// Air cells and refinement over the objects for the study: 0.075 m at the cars resolves
    /// their 0.15 m under-gap exactly (two cells), and 0.05 m at the furniture gives a chair's
    /// side nine cells.
    public var resolution: (cellSize: Float, refinement: Int) {
        switch self {
        case .carPark: (0.15, 2)
        case .furnishedRoom: (0.1, 2)
        case .crowdedPen: (0.2, 2)
        }
    }

    /// A stable identity for the `n`th object, so that the scene is the same each time it is made.
    static func identity(_ scene: Int, _ n: Int) -> UUID {
        UUID(uuidString: String(format: "5C3E0000-0000-4000-8000-%04X%08X", scene, n))!
    }

    public var scenario: Scenario {
        switch self {
        case .carPark: Self.carParkScenario()
        case .furnishedRoom: Self.furnishedRoomScenario()
        case .crowdedPen: Self.crowdedPenScenario()
        }
    }

    /// The car park layout (`ScenarioPreset.carPark`): two decks and a roof of 250 mm slab on
    /// 400 mm columns on a 7.5 m grid, here rigid blocks. Saloons stand side by side in 2.4 m
    /// bays, noses along y: a row in each of the two spans between column lines, and one in the
    /// open beside the building. The charge, 100 kg 0.8 m up, is in the bay of the first row's
    /// second car, which is not modelled.
    static func carParkScenario() -> Scenario {
        var scene = ScenarioPreset.carPark.scenario
        let blocks = scene.structure?.solids ?? []
        scene.structure = nil
        scene.name = PopulatedScene.carPark.title
        scene.objects = []
        scene.boxes = blocks
        let xs = [11.35, 13.75, 16.15, 19.15, 21.55, 23.95]
        let rows = [13.75, 21.25, 6.85]
        let heading = SIMD4<Double>(0, 0, sin(Double.pi / 4), cos(Double.pi / 4))
        var cars: [RigidCarDefinition] = []
        for (r, y) in rows.enumerated() {
            for x in xs where !(r == 0 && x == 13.75) {
                cars.append(
                    try! .saloon(
                        id: identity(1, cars.count), name: "Row \(r + 1), car \(cars.count + 1)",
                        position: SIMD3(x, y, 0), orientation: heading))
            }
        }
        scene.rigidCars = cars
        scene.gauges = [
            Gauge("Next bay", at: SIMD3(16.15, 13.75, 2.0)),
            Gauge("Second row", at: SIMD3(16.15, 18.5, 1.0)),
            Gauge("Outside", at: SIMD3(16.15, 9.5, 1.0)),
        ]
        return scene
    }

    /// A 6 × 5 m room, 2.8 m high inside, of rigid blocks 0.3 m thick, with a 0.9 × 2.1 m door
    /// and a 1.2 × 1.2 m window. Furniture as solid boxes (a table's or chair's space beneath
    /// is filled), at typical masses, on the floor with friction 0.5 static and 0.4 sliding
    /// (wood or fabric on a hard floor). The charge, 1 kg, is 0.3 m up by one end wall.
    static func furnishedRoomScenario() -> Scenario {
        // Inside: x 4...10, y 4...9, z 0...2.8.
        let t: Float = 0.3
        let low = SIMD3<Float>(4, 4, 0)
        let high = SIMD3<Float>(10, 9, 2.8)
        var blocks: [Box] = [
            // Ceiling.
            Box(min: SIMD3(low.x - t, low.y - t, high.z), max: SIMD3(high.x + t, high.y + t, high.z + t)),
            // West wall, whole.
            Box(min: SIMD3(low.x - t, low.y - t, 0), max: SIMD3(low.x, high.y + t, high.z)),
            // North wall, whole.
            Box(min: SIMD3(low.x, high.y, 0), max: SIMD3(high.x + t, high.y + t, high.z)),
        ]
        // South wall, a door from x 8 to 8.9 up to 2.1 m.
        blocks += [
            Box(min: SIMD3(low.x, low.y - t, 0), max: SIMD3(8, low.y, high.z)),
            Box(min: SIMD3(8.9, low.y - t, 0), max: SIMD3(high.x + t, low.y, high.z)),
            Box(min: SIMD3(8, low.y - t, 2.1), max: SIMD3(8.9, low.y, high.z)),
        ]
        // East wall, a window from y 6 to 7.2 between 0.9 and 2.1 m.
        blocks += [
            Box(min: SIMD3(high.x, low.y, 0), max: SIMD3(high.x + t, 6, high.z)),
            Box(min: SIMD3(high.x, 7.2, 0), max: SIMD3(high.x + t, high.y, high.z)),
            Box(min: SIMD3(high.x, 6, 0), max: SIMD3(high.x + t, 7.2, 0.9)),
            Box(min: SIMD3(high.x, 6, 2.1), max: SIMD3(high.x + t, 7.2, high.z)),
        ]
        let pieces: [(String, SIMD3<Double>, SIMD3<Double>, Double)] = [
            // Name, centre of the base, size, mass.
            ("Dining table", SIMD3(7.6, 6.5, 0), SIMD3(1.6, 0.9, 0.75), 40),
            ("Chair 1", SIMD3(7.1, 5.7, 0), SIMD3(0.45, 0.45, 0.9), 6),
            ("Chair 2", SIMD3(8.1, 5.7, 0), SIMD3(0.45, 0.45, 0.9), 6),
            ("Chair 3", SIMD3(7.1, 7.3, 0), SIMD3(0.45, 0.45, 0.9), 6),
            ("Chair 4", SIMD3(8.1, 7.3, 0), SIMD3(0.45, 0.45, 0.9), 6),
            ("Desk", SIMD3(9.35, 8.0, 0), SIMD3(0.6, 1.2, 0.75), 30),
            ("Desk chair", SIMD3(8.75, 8.0, 0), SIMD3(0.5, 0.5, 0.9), 8),
            ("Sofa", SIMD3(5.1, 6.5, 0), SIMD3(0.9, 2.0, 0.8), 50),
            ("Cabinet", SIMD3(6.5, 8.75, 0), SIMD3(1.0, 0.45, 1.8), 60),
            ("Bookcase", SIMD3(5.0, 4.2, 0), SIMD3(0.8, 0.3, 2.0), 50),
            ("Side table", SIMD3(4.35, 8.6, 0), SIMD3(0.5, 0.5, 0.6), 8),
        ]
        let objects = pieces.enumerated().map { n, piece in
            try! RigidObjectDefinition(
                id: identity(2, n), name: piece.0, shape: .box(size: piece.2),
                position: piece.1 + SIMD3(0, 0, piece.2.z / 2), mass: piece.3, staticFriction: 0.5,
                slidingFriction: 0.4)
        }
        var scene = Scenario(
            name: PopulatedScene.furnishedRoom.title, domainSize: SIMD3(14, 13, 6), boxes: blocks,
            charge: Charge(mass: 1, position: SIMD3(9.2, 5.2, 0.3)),
            gauges: [
                Gauge("Room, far end", at: SIMD3(4.5, 6.5, 1.5)),
                Gauge("Window", at: SIMD3(9.9, 6.6, 1.5)),
                Gauge("Outside the door", at: SIMD3(8.45, 3, 1.0)),
            ])
        scene.rigidObjects = objects
        return scene
    }

    /// 48 boxes of 0.5–0.6 m and 20–40 kg, side by side almost touching, in three layers in a
    /// pen of rigid walls 1 m high, 2 kg 1.5 m from the pen's open side.
    static func crowdedPenScenario() -> Scenario {
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        var objects: [RigidObjectDefinition] = []
        for n in 0..<48 {
            let i = n % 4
            let j = (n / 4) % 4
            let k = n / 16
            let size = SIMD3<Double>(0.5, 0.5, 0.45) + 0.08 * random()
            objects.append(
                try! RigidObjectDefinition(
                    id: identity(3, n), name: "Box \(n + 1)", shape: .box(size: size),
                    position: SIMD3(
                        4.4 + 0.7 * Double(i) + 0.05 * random(), 4.4 + 0.7 * Double(j) + 0.05 * random(),
                        0.6 * Double(k) + size.z / 2),
                    mass: 20 + 20 * random(),
                    orientation: simd_quatd(angle: 0.2 * (random() - 0.5), axis: SIMD3(0, 0, 1)).vector))
        }
        let blocks = [
            Box(min: SIMD3(3.8, 3.8, 0), max: SIMD3(7.4, 4.0, 1)),
            Box(min: SIMD3(3.8, 7.2, 0), max: SIMD3(7.4, 7.4, 1)),
            Box(min: SIMD3(7.2, 4.0, 0), max: SIMD3(7.4, 7.2, 1)),
        ]
        var scene = Scenario(
            name: PopulatedScene.crowdedPen.title, domainSize: SIMD3(12, 11, 5), boxes: blocks,
            charge: Charge(mass: 2, position: SIMD3(2.3, 5.6, 0.5)))
        scene.rigidObjects = objects
        return scene
    }
}
