import Foundation
import simd

/// "Twelve-storey office, steel and glass": a speculative office of modern construction, its
/// proportions from steel construction guidance (docs/office-tower.md gives the sources):
/// - 12 storeys of 3.8 m floor to floor (3.6–4.0 m for speculative offices), 45.6 m high;
/// - a 22.5 m square floor plate on a 7.5 m column grid, three bays each way;
/// - a reinforced concrete core in the middle bay, 7.5 m square, of 300 mm walls (lift and stair
///   shafts, a doorway into it on every floor), which keeps the frame standing;
/// - composite floors: 130 mm of concrete on a 60 mm steel deck, spanning 2.5 m between 356 UB
///   secondary beams, on 457 UB primary beams along the column lines, all on the slab's
///   midsurface (sharing its nodes: full shear connection, without the composite section's lever
///   arm), joined rigidly to the columns;
/// - twelve 305 UC perimeter columns, each a rectangle of steel scaled to the section;
/// - a unitised curtain wall on every face: a frame of aluminium mullions at 1.5 m and transoms,
///   one storey high and fixed to the slab edges, glazed with 10 mm toughened glass from 0.25 m
///   above each floor to 2.95 m, with an opaque spandrel above to the next floor.
/// Across a 20 m street stand two five-storey neighbours as envelopes (rigid, exposure only),
/// their windows panes judged by envelope damage; 1,000 kg, a van's worth, stands at the kerb,
/// 5 m from the tower's front.
extension ScenarioPreset {
    /// The aluminium frame of the curtain wall (6063-T6: E = 70 GPa, 160 MPa proof stress), meshed
    /// as one plate 150 mm thick, a mullion's depth, and scaled so that a strip one element (0.25 m)
    /// wide bends as stiffly and as strongly as a 65 × 150 mm hollow mullion of 3 mm walls
    /// (I = 3.6e-6 m⁴, plastic modulus 6.0e-5 m³, 3.4 kg/m) and weighs as much.
    static let curtainWallFrame: StructureMaterial = {
        let (strip, depth): (Float, Float) = (0.25, 0.15)
        let (secondMoment, plasticModulus, mass): (Float, Float, Float) = (3.6e-6, 6.0e-5, 3.4)
        return StructureMaterial(
            name: "Aluminium curtain-wall frame",
            density: mass / (strip * depth),
            youngsModulus: 70e9 * secondMoment / (strip * depth * depth * depth / 12),
            poissonRatio: 0.33,
            yieldStress: 160e6 * plasticModulus / (strip * depth * depth / 4),
            hardeningModulus: 0, failureStrain: 0.08)
    }()

    static func officeTowerScenario(title: String) -> Scenario {
        let storey: Float = 3.8
        let slab: Float = 0.13
        let bay: Float = 7.5
        let (x0, y0): (Float, Float) = (18.75, 30)
        let (x1, y1) = (x0 + 3 * bay, y0 + 3 * bay)
        let floors = (1...12).map { Float($0) * storey }
        let top = floors.last!
        let mids = floors.map { $0 - slab / 2 }

        var solids: [Box] = []
        var materials: [StructureMaterial?] = []
        var reinforcement: [Reinforcement] = []
        func add(_ box: Box, _ material: StructureMaterial?, bars: Reinforcement = .none) {
            solids.append(box)
            materials.append(material)
            reinforcement.append(bars)
        }

        // Columns: 305 UC, their depth across the façade they stand in.
        let column = SteelSection.uc305x305x118
        let columnSteel = column.equivalent()
        for i in 0...3 {
            for j in 0...3 where i == 0 || i == 3 || j == 0 || j == 3 {
                let (x, y) = (x0 + Float(i) * bay, y0 + Float(j) * bay)
                let (dx, dy) = (column.rectangleWidth / 2, column.depth / 2)
                add(Box(min: SIMD3(x - dx, y - dy, 0), max: SIMD3(x + dx, y + dy, top)), columnSteel)
            }
        }
        // The core: 300 mm walls centred on the middle bay's grid lines.
        let (c0, c1) = (x0 + bay, x0 + 2 * bay)
        let (d0, d1) = (y0 + bay, y0 + 2 * bay)
        let t: Float = 0.3
        for box in [
            Box(min: SIMD3(c0 - t / 2, d0 - t / 2, 0), max: SIMD3(c1 + t / 2, d0 + t / 2, top)),
            Box(min: SIMD3(c0 - t / 2, d1 - t / 2, 0), max: SIMD3(c1 + t / 2, d1 + t / 2, top)),
            Box(min: SIMD3(c0 - t / 2, d0 + t / 2, 0), max: SIMD3(c0 + t / 2, d1 - t / 2, top)),
            Box(min: SIMD3(c1 - t / 2, d0 + t / 2, 0), max: SIMD3(c1 + t / 2, d1 - t / 2, top)),
        ] {
            add(box, nil, bars: .automatic)
        }
        // Floors: the slab to just inside the curtain wall.
        let edge: Float = 0.175
        var slabIndices: [Int] = []
        for z in floors {
            add(Box(min: SIMD3(x0 - edge, y0 - edge, z - slab), max: SIMD3(x1 + edge, y1 + edge, z)), nil)
            slabIndices.append(solids.count - 1)
        }
        // Beams on each slab's midsurface: 457 UB primaries on the column lines both ways (but not
        // along the core's walls), 356 UB secondaries at 2.5 m between them.
        let primary = SteelSection.ub457x191x67
        let secondary = SteelSection.ub356x171x45
        // Each no wider than 0.24 m, so that its faces lie within half an element of its line and
        // are not made lines of the mesh (whose shortest elements would set the time step).
        let beamWidth = { (section: SteelSection) in min(section.rectangleWidth, 0.24) }
        let primarySteel = primary.equivalent(width: beamWidth(primary))
        let secondarySteel = secondary.equivalent(width: beamWidth(secondary))
        func beam(
            _ section: SteelSection, _ steel: StructureMaterial, along k: Int, at line: Float, from a: Float,
            to b: Float, z: Float
        ) {
            let w = beamWidth(section) / 2
            var low = SIMD3<Float>(0, 0, z - section.depth / 2)
            var high = SIMD3<Float>(0, 0, z + section.depth / 2)
            low[k] = a
            high[k] = b
            low[1 - k] = line - w
            high[1 - k] = line + w
            add(Box(min: low, max: high), steel)
        }
        for z in mids {
            for j in 0...3 {
                let line = Float(j) * bay
                // Along x on y = y0 + line, and along y on x = x0 + line.
                let spans: [(Float, Float)] =
                    j == 1 || j == 2 ? [(Float(0), bay), (2 * bay, 3 * bay)] : [(Float(0), 3 * bay)]
                for (a, b) in spans {
                    beam(primary, primarySteel, along: 0, at: y0 + line, from: x0 + a, to: x0 + b, z: z)
                    beam(primary, primarySteel, along: 1, at: x0 + line, from: y0 + a, to: y0 + b, z: z)
                }
            }
            for k in [1, 2, 4, 5, 7, 8] {
                let line = x0 + Float(k) * bay / 3
                let middle = k == 4 || k == 5
                let spans: [(Float, Float)] =
                    middle ? [(Float(0), bay), (2 * bay, 3 * bay)] : [(Float(0), 3 * bay)]
                for (a, b) in spans {
                    beam(secondary, secondarySteel, along: 1, at: line, from: y0 + a, to: y0 + b, z: z)
                }
            }
        }
        // The curtain wall: on each face, a frame one storey high from slab edge to slab edge (the
        // ground floor's from the ground), 150 mm deep, its plane 0.25 m out from the column lines;
        // in it, a vision lite 1.25 m wide in each 1.5 m module, from 0.25 m above the floor to
        // 2.95 m, glazed with 10 mm toughened glass.
        let out: Float = 0.25
        let depth: Float = 0.15
        let pane: Float = 0.01
        var openings: [Box] = []
        let bases = [Float(0)] + mids.dropLast()
        for (n, base) in bases.enumerated() {
            let floor = n == 0 ? Float(0) : floors[n - 1]
            let head = mids[n]
            // Front and back (normal y), then the sides (normal x).
            for (k, plane) in [(1, y0 - out), (1, y1 + out), (0, x0 - out), (0, x1 + out)] {
                let along = 1 - k
                // Each runs past the corner to the other faces' planes, so that they meet there.
                let (start, end) =
                    along == 0
                    ? (x0 - out - depth / 2, x1 + out + depth / 2)
                    : (y0 - out - depth / 2, y1 + out + depth / 2)
                var low = SIMD3<Float>(0, 0, base)
                var high = SIMD3<Float>(0, 0, head)
                low[k] = plane - depth / 2
                high[k] = plane + depth / 2
                low[along] = start
                high[along] = end
                add(Box(min: low, max: high), Self.curtainWallFrame)
                let origin = along == 0 ? x0 : y0
                for module in 0..<15 {
                    var hole = SIMD3<Float>(0, 0, floor + 0.25)
                    var holeHigh = SIMD3<Float>(0, 0, floor + 2.95)
                    hole[k] = plane - depth / 2 - 0.01
                    holeHigh[k] = plane + depth / 2 + 0.01
                    hole[along] = origin + Float(module) * 1.5 + 0.125
                    holeHigh[along] = origin + Float(module + 1) * 1.5 - 0.125
                    openings.append(Box(min: hole, max: holeHigh))
                    var glass = Box(min: hole, max: holeHigh)
                    glass.min[k] = plane - pane / 2
                    glass.max[k] = plane + pane / 2
                    add(glass, .toughenedGlass)
                }
            }
        }

        var structure = StructureModel(solids: solids, elementSize: 0.25)
        structure.elementKind = .shell
        for (index, material) in materials.enumerated() {
            if let material { structure.setMaterial(material, of: index) }
            structure.setReinforcement(reinforcement[index], of: index)
        }
        structure.autoReinforce()
        // The slab: its deck (about 1,200 mm² of steel a metre, 30 mm up) as bars along its span,
        // across the secondary beams, and an A193 mesh 30 mm below its top.
        for index in slabIndices {
            structure.addMat(
                to: structure.solids[index], thicknessAxis: 2, areaPerMetre: 1200e-6,
                transverseAreaPerMetre: 0,
                longitudinalAxis: 0, depth: 0.03, faces: (true, false))
            structure.addMat(
                to: structure.solids[index], thicknessAxis: 2, areaPerMetre: 193e-6, depth: 0.03,
                faces: (false, true))
        }
        // A doorway into the core on every floor, through its front wall; and the lites.
        let doors = ([Float(0)] + floors.dropLast()).map { floor in
            Box(
                min: SIMD3(x0 + 1.5 * bay - 0.5, d0 - t, floor),
                max: SIMD3(x0 + 1.5 * bay + 0.5, d0 + t, floor + 2.1))
        }
        structure.openings = doors + openings

        var scenario = Scenario(
            name: title, domainSize: SIMD3(60, 60, 52), boxes: [],
            charge: Charge(mass: 1000, position: SIMD3(x0 + 1.5 * bay, y0 - 5, 1)),
            gauges: [
                Gauge("Front glass, ground floor", at: SIMD3(x0 + 1.5 * bay - 0.75, y0 - out - 0.2, 1.5)),
                Gauge(
                    "Front glass, sixth floor",
                    at: SIMD3(x0 + 1.5 * bay - 0.75, y0 - out - 0.2, floors[4] + 1.5)),
                Gauge("Across the street", at: SIMD3(x0 + 1.5 * bay, 10.2, 1.5)),
                Gauge("Roof", at: SIMD3(x0 + 1.5 * bay, y0 + 1.5 * bay, top + 0.5)),
            ],
            structure: structure)
        // Across the street: two five-storey blocks, 24 m by 8 m, their fronts at y = 10 with a
        // window of 6 mm glass 1.5 m by 1.8 m every 3 m along each storey.
        for (n, (a, b)) in [(Float(3), Float(27)), (Float(33), Float(57))].enumerated() {
            let (front, back, height): (Float, Float, Float) = (10, 2, 17.5)
            let wall: Float = 0.3
            let walls = [
                Box(min: SIMD3(a, front - wall, 0), max: SIMD3(b, front, height)),
                Box(min: SIMD3(a, back, 0), max: SIMD3(b, back + wall, height)),
                Box(min: SIMD3(a, back + wall, 0), max: SIMD3(a + wall, front - wall, height)),
                Box(min: SIMD3(b - wall, back + wall, 0), max: SIMD3(b, front - wall, height)),
                Box(min: SIMD3(a, back, height), max: SIMD3(b, front, height + 0.3)),
            ]
            var windows: [Box] = []
            var glass: [Box] = []
            for level in 0..<5 {
                for slot in 0..<8 {
                    let x = a + 1.5 + Float(slot) * 3
                    let z = Float(level) * 3.5 + 0.9
                    windows.append(
                        Box(min: SIMD3(x, front - wall - 0.01, z), max: SIMD3(x + 1.5, front + 0.01, z + 1.8))
                    )
                    // The pane fills its opening through the wall's thickness, so that the air sees the
                    // window closed at any cell size (a 6 mm box holds no cell's centre); envelope damage
                    // takes the glass's thickness from the building's construction.
                    glass.append(Box(min: SIMD3(x, front - wall, z), max: SIMD3(x + 1.5, front, z + 1.8)))
                }
            }
            let id = UUID(uuidString: String(format: "0FF1CE00-0000-4000-8000-%012d", n + 1))!
            if let envelope = try? BuildingEnvelope(solids: walls, openings: windows, panes: glass) {
                _ = try? scenario.addEnvelopeObject(
                    envelope, name: n == 0 ? "Across the street, left" : "Across the street, right", id: id)
            }
        }
        return scenario
    }
}
