import simd

public enum ScenarioPreset: String, CaseIterable, Identifiable, Sendable {
    case openGround
    case singleBuilding
    case streetCanyon
    case courtyard
    case blastWall
    case concreteBox
    case frame
    case infilledFrame
    case threeStorey
    case tallFrame
    case coreTower
    case columnCloseIn
    case protectedBuilding
    case glassFacade
    case carPark
    case underpass
    case blockHouse
    case blockWall
    case internalExplosion

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openGround: "Open ground"
        case .singleBuilding: "Single building"
        case .streetCanyon: "Street canyon"
        case .courtyard: "Courtyard"
        case .blastWall: "Deformable wall"
        case .concreteBox: "Deformable building"
        case .frame: "Two-storey frame"
        case .infilledFrame: "Frame with masonry infill"
        case .threeStorey: "Three-storey building"
        case .tallFrame: "Eight-storey frame"
        case .coreTower: "Twelve-storey tower"
        case .columnCloseIn: "Column, close-in"
        case .protectedBuilding: "Wall in front of a building"
        case .glassFacade: "Glass façade"
        case .carPark: "Car park"
        case .underpass: "Underpass"
        case .blockHouse: "Block-built house"
        case .blockWall: "Blockwork wall"
        case .internalExplosion: "Internal explosion (test)"
        }
    }

    /// Reinforcement of the deformable presets: 12 mm bars at 200 mm centres, both ways, in
    /// each face (565 mm² per metre), with their centres 40 mm below the surface.
    static let barArea: Float = 565e-6
    static let barDepth: Float = 0.04

    public var scenario: Scenario {
        var result = authoredScenario
        // Presets are reproducible inputs, including those assembled by editing other presets.
        let body = result.structure
        result.objects = result.boxes.enumerated().map {
            SceneObject.legacyBlock($0.element, index: $0.offset)
        }
        if let body { result.objects.append(.legacyStructure(body)) }
        return result
    }

    private var authoredScenario: Scenario {
        let domain = SIMD3<Float>(64, 64, 32)
        switch self {
        case .openGround:
            // A surface burst on rigid ground: by symmetry this equals a free-air burst of twice
            // the mass, which makes it directly comparable with empirical free-air curves.
            return Scenario(
                name: title, domainSize: domain, boxes: [],
                charge: Charge(mass: 100, position: SIMD3(32, 32, 0)),
                gauges: [5, 10, 15, 20, 25].map { range in
                    Gauge("\(Int(range)) m", at: SIMD3(32 + range, 32, 0.05))
                })

        case .singleBuilding:
            return Scenario(
                name: title, domainSize: domain,
                boxes: [Box(x: 36...52, y: 20...44, height: 18)],
                charge: Charge(mass: 100, position: SIMD3(22, 32, 1)),
                gauges: [
                    Gauge("Front, low", at: SIMD3(35.9, 32, 1.5)),
                    Gauge("Front, high", at: SIMD3(35.9, 32, 15)),
                    Gauge("Roof", at: SIMD3(44, 32, 18.1)),
                    Gauge("Side", at: SIMD3(44, 19.9, 1.5)),
                    Gauge("Rear", at: SIMD3(52.1, 32, 1.5)),
                ])

        case .streetCanyon:
            return Scenario(
                name: title, domainSize: domain,
                boxes: [
                    Box(x: 4...22, y: 6...24, height: 18),
                    Box(x: 26...44, y: 6...24, height: 24),
                    Box(x: 48...60, y: 6...24, height: 15),
                    Box(x: 4...18, y: 40...58, height: 21),
                    Box(x: 22...42, y: 40...58, height: 15),
                    Box(x: 46...60, y: 40...58, height: 27),
                ],
                charge: Charge(mass: 100, position: SIMD3(30, 29, 1)),
                gauges: [
                    Gauge("Near façade", at: SIMD3(32, 23.9, 1.5)),
                    Gauge("Far façade", at: SIMD3(32, 40.1, 1.5)),
                    Gauge("Down street", at: SIMD3(54, 32, 1.5)),
                    Gauge("Side alley", at: SIMD3(24, 12, 1.5)),
                    Gauge("Roof", at: SIMD3(35, 15, 24.1)),
                ])

        case .courtyard:
            return Scenario(
                name: title, domainSize: domain,
                boxes: [
                    Box(x: 16...24, y: 16...48, height: 15),
                    Box(x: 40...48, y: 16...48, height: 15),
                    Box(x: 24...40, y: 40...48, height: 15),
                ],
                charge: Charge(mass: 100, position: SIMD3(32, 26, 1)),
                gauges: [
                    Gauge("Back wall", at: SIMD3(32, 39.9, 1.5)),
                    Gauge("Side wall", at: SIMD3(24.1, 30, 1.5)),
                    Gauge("Courtyard mouth", at: SIMD3(32, 12, 1.5)),
                    Gauge("Behind building", at: SIMD3(32, 50, 1.5)),
                ])

        case .blastWall:
            // A free-standing cantilever wall, 250 mm thick and 3 m high, 6 m from the charge.
            let wall = Box(x: 18...18.25, y: 10...22, height: 3)
            var structure = StructureModel(solids: [wall], elementSize: 0.0625)
            structure.addMat(to: wall, thicknessAxis: 0, areaPerMetre: Self.barArea, depth: Self.barDepth)
            return Scenario(
                name: title, domainSize: SIMD3(32, 32, 16), boxes: [],
                charge: Charge(mass: 50, position: SIMD3(12, 16, 1)),
                gauges: [
                    Gauge("Wall, front", at: SIMD3(17.9, 16, 1.5)),
                    Gauge("Wall, behind", at: SIMD3(18.4, 16, 1.5)),
                    Gauge("5 m behind", at: SIMD3(23, 16, 1.5)),
                ],
                structure: structure)

        case .concreteBox:
            // A single-storey box with 250 mm walls and roof slab, two windows facing the charge
            // and a door in the side.
            let walls: [(box: Box, axis: Int)] = [
                (Box(x: 16...16.25, y: 11...21, height: 3.5), 0),
                (Box(x: 25.75...26, y: 11...21, height: 3.5), 0),
                (Box(x: 16...26, y: 11...11.25, height: 3.5), 1),
                (Box(x: 16...26, y: 20.75...21, height: 3.5), 1),
                (Box(min: SIMD3(16, 11, 3.25), max: SIMD3(26, 21, 3.5)), 2),
            ]
            var structure = StructureModel(
                solids: walls.map(\.box),
                openings: [
                    Box(min: SIMD3(15.9, 12.5, 1), max: SIMD3(16.35, 14.5, 2.25)),
                    Box(min: SIMD3(15.9, 17.5, 1), max: SIMD3(16.35, 19.5, 2.25)),
                    Box(min: SIMD3(20, 10.9, 0), max: SIMD3(21, 11.35, 2.25)),
                ],
                elementSize: 0.0625)
            for wall in walls {
                structure.addMat(
                    to: wall.box, thicknessAxis: wall.axis, areaPerMetre: Self.barArea, depth: Self.barDepth)
            }
            return Scenario(
                name: title, domainSize: SIMD3(32, 32, 16), boxes: [],
                charge: Charge(mass: 100, position: SIMD3(8, 16, 1)),
                gauges: [
                    Gauge("Front wall", at: SIMD3(15.9, 16, 1.5)),
                    Gauge("Inside", at: SIMD3(21, 16, 1.5)),
                    Gauge("Roof", at: SIMD3(21, 16, 3.6)),
                    Gauge("Behind", at: SIMD3(26.1, 16, 1.5)),
                ],
                structure: structure)

        case .frame, .infilledFrame:
            // A two-storey, two-bay concrete frame: 375 mm square columns on a 6 m grid carrying
            // 250 mm flat slabs, with the charge beside the middle front column.
            let columnSize: Float = 0.375
            let top: Float = 7
            var solids: [Box] = []
            var columns: [Box] = []
            for x in [14, 20, 26] as [Float] {
                for y in [13, 19] as [Float] {
                    columns.append(Box(x: x...(x + columnSize), y: y...(y + columnSize), height: top))
                }
            }
            let slabs = [3.25, 6.75].map { (level: Float) in
                Box(min: SIMD3(14, 13, level), max: SIMD3(26 + columnSize, 19 + columnSize, level + 0.25))
            }
            solids = columns + slabs
            var structure = StructureModel(solids: solids, elementSize: 0.125)
            for column in columns {
                // 2% longitudinal steel with ties, smeared through the column.
                structure.reinforcement.append(
                    ReinforcementLayer(region: column, ratio: SIMD3(0.004, 0.004, 0.02)))
            }
            for slab in slabs {
                // 12 mm bars at 150 mm centres, both ways, top and bottom.
                structure.addMat(to: slab, thicknessAxis: 2, areaPerMetre: 754e-6, depth: Self.barDepth)
            }
            if self == .infilledFrame {
                // Unreinforced masonry panels, 250 mm thick, filling both storeys of the front
                // face between the columns and the slabs, bonded to them.
                for (x0, x1) in [(14.375, 20), (20.375, 26)] as [(Float, Float)] {
                    for (z0, z1) in [(0, 3.25), (3.5, 6.75)] as [(Float, Float)] {
                        structure.solids.append(Box(min: SIMD3(x0, 13, z0), max: SIMD3(x1, 13.25, z1)))
                        structure.setMaterial(.masonry, of: structure.solids.count - 1)
                    }
                }
            }
            return Scenario(
                name: title, domainSize: SIMD3(40, 32, 16), boxes: [],
                // 2,000 kg brings the frame down: since bars hold cracked sections together and
                // resist sliding across cracks, and cracks turn with the stress until they open,
                // 1,000 kg leaves it standing. Masonry needs far less: 50 kg breaches one panel
                // and cracks the rest.
                charge: Charge(mass: self == .infilledFrame ? 50 : 2000, position: SIMD3(18, 10, 1)),
                gauges: [
                    Gauge("Front column", at: SIMD3(20.2, 12.9, 1.5)),
                    Gauge("Under first slab", at: SIMD3(20, 16, 3)),
                    Gauge("Behind", at: SIMD3(20, 22, 1.5)),
                ],
                structure: structure)

        case .columnCloseIn:
            // A 400 mm square column, 4 m high, held at its top by the floor it carries, with
            // 2% of steel along it and ties, and 500 kg 1.8 m from its face: close in, where a
            // column is broken by shear and its concrete torn off rather than bent (it loses
            // elements and swings 200 mm on 0.125 m air). At 200 kg it cracks and swings 30 mm, or
            // 48 mm on 0.0625 m air: the column is only a few air cells across, so it wants a
            // fine grid.
            let column = Box(x: 15.8...16.2, y: 15.8...16.2, height: 4)
            var structure = StructureModel(solids: [column], elementSize: 0.05)
            structure.reinforcement.append(
                ReinforcementLayer(region: column, ratio: SIMD3(0.004, 0.004, 0.02)))
            structure.supports = [Box(min: SIMD3(15, 15, 3.97), max: SIMD3(17, 17, 5))]
            return Scenario(
                name: title, domainSize: SIMD3(24, 24, 8), boxes: [],
                charge: Charge(mass: 500, position: SIMD3(14, 16, 1)),
                gauges: [
                    Gauge("Column, front", at: SIMD3(15.75, 16, 1)),
                    Gauge("Column, behind", at: SIMD3(16.3, 16, 1)),
                    Gauge("5 m behind", at: SIMD3(21, 16, 1)),
                ],
                structure: structure)

        case .protectedBuilding:
            // The single-storey building of "Deformable building" with a 3 m cantilever wall
            // between it and the same charge: what a blast wall takes off the building.
            var scenario = Self.concreteBox.scenario
            scenario.name = title
            guard var structure = scenario.structure else { return scenario }
            let wall = Box(x: 12...12.25, y: 8...24, height: 3)
            structure.solids.append(wall)
            structure.addMat(to: wall, thicknessAxis: 0, areaPerMetre: Self.barArea, depth: Self.barDepth)
            scenario.structure = structure
            scenario.gauges.insert(Gauge("Wall, front", at: SIMD3(11.9, 16, 1.5)), at: 0)
            return scenario

        case .glassFacade:
            // The two-storey frame of "Two-storey frame" with its front bays glazed: panes of
            // 10 mm annealed glass, meshed as shells, held in the frame. 20 kg in the street,
            // 10 m out: enough to break glass, far too little to harm the frame.
            var scenario = Self.frame.scenario
            scenario.name = title
            guard var structure = scenario.structure else { return scenario }
            let pane: Float = 0.01
            let y: Float = 13.18
            for (x0, x1) in [(14.375, 20), (20.375, 26)] as [(Float, Float)] {
                for (z0, z1) in [(0, 3.25), (3.5, 6.75)] as [(Float, Float)] {
                    structure.solids.append(Box(min: SIMD3(x0, y, z0), max: SIMD3(x1, y + pane, z1)))
                    let index = structure.solids.count - 1
                    structure.setMaterial(.annealedGlass, of: index)
                    structure.setElementKind(.shell, of: index)
                }
            }
            structure.shellElementSize = 0.125
            structure.shellLayers = 4
            scenario.structure = structure
            scenario.charge = Charge(mass: 20, position: SIMD3(20, 3, 1))
            scenario.gauges = [
                Gauge("Glass, ground floor", at: SIMD3(17, 13.1, 1.5)),
                Gauge("Glass, first floor", at: SIMD3(17, 13.1, 5)),
                Gauge("Inside", at: SIMD3(17, 16, 1.5)),
            ]
            return scenario

        case .carPark:
            // An open-sided car park: two decks and a roof of 250 mm flat slab on 400 mm columns
            // on a 7.5 m grid, 2.85 m floor to floor, with 100 kg in a car on the ground floor.
            let column: Float = 0.4
            let xs: [Float] = [10, 17.5, 25]
            let ys: [Float] = [10, 17.5, 25]
            let levels: [Float] = [2.6, 5.45, 8.3]
            let top = levels.last! + 0.25
            var columns: [Box] = []
            for x in xs {
                for y in ys {
                    columns.append(Box(x: x...(x + column), y: y...(y + column), height: top))
                }
            }
            let slabs = levels.map {
                Box(
                    min: SIMD3(xs.first!, ys.first!, $0),
                    max: SIMD3(xs.last! + column, ys.last! + column, $0 + 0.25))
            }
            var structure = StructureModel(solids: columns + slabs, elementSize: 0.125)
            for box in columns {
                structure.reinforcement.append(
                    ReinforcementLayer(region: box, ratio: SIMD3(0.004, 0.004, 0.02)))
            }
            for slab in slabs {
                structure.addMat(to: slab, thicknessAxis: 2, areaPerMetre: 754e-6, depth: Self.barDepth)
            }
            return Scenario(
                name: title, domainSize: SIMD3(36, 36, 12), boxes: [],
                charge: Charge(mass: 100, position: SIMD3(13.75, 13.75, 0.8)),
                gauges: [
                    Gauge("Under the first deck", at: SIMD3(13.75, 13.75, 2.5)),
                    Gauge("Next bay", at: SIMD3(21.25, 13.75, 1.5)),
                    Gauge("Outside", at: SIMD3(30, 13.75, 1.5)),
                ],
                structure: structure)

        case .underpass:
            // A reinforced concrete box underpass, 6 m wide and 5 m high inside, with 500 mm
            // walls, floor and roof, 30 m long and open at both ends, and 100 kg inside: the
            // tube keeps the blast from spreading, so it reaches far along it.
            let walls: [(box: Box, axis: Int)] = [
                (Box(min: SIMD3(4, 12.5, 0), max: SIMD3(34, 13, 6)), 1),
                (Box(min: SIMD3(4, 19, 0), max: SIMD3(34, 19.5, 6)), 1),
                (Box(min: SIMD3(4, 13, 0), max: SIMD3(34, 19, 0.5)), 2),
                (Box(min: SIMD3(4, 13, 5.5), max: SIMD3(34, 19, 6)), 2),
            ]
            var structure = StructureModel(solids: walls.map(\.box), elementSize: 0.125)
            for wall in walls {
                structure.addMat(to: wall.box, thicknessAxis: wall.axis, areaPerMetre: 754e-6, depth: 0.05)
            }
            return Scenario(
                name: title, domainSize: SIMD3(38, 32, 12), boxes: [],
                charge: Charge(mass: 100, position: SIMD3(19, 16, 1.5)),
                gauges: [
                    Gauge("Wall beside the charge", at: SIMD3(19, 13.1, 1.5)),
                    Gauge("10 m along", at: SIMD3(29, 16, 1.5)),
                    Gauge("Outside the portal", at: SIMD3(36, 16, 1.5)),
                    Gauge("Beside the underpass", at: SIMD3(19, 24, 1.5)),
                ],
                structure: structure)

        case .blockHouse:
            // A two-storey house, 8 m deep and 9 m wide, of 200 mm concrete blockwork (a 150 mm
            // block wall inside, with a doorway), with a 200 mm reinforced concrete first floor
            // and flat roof; windows front and back on both floors and a front door. Meshed with
            // shells, which suit walls and slabs this thin. 25 kg in the street, 10 m in front.
            let (x0, x1): (Float, Float) = (16, 24)
            let (y0, y1): (Float, Float) = (12, 21)
            let t: Float = 0.2
            let floors: [Float] = [2.6, 5.4]
            let top = floors.last! + t
            let walls: [Box] = [
                Box(min: SIMD3(x0, y0, 0), max: SIMD3(x0 + t, y1, top)),  // front
                Box(min: SIMD3(x1 - t, y0, 0), max: SIMD3(x1, y1, top)),  // back
                Box(min: SIMD3(x0 + t, y0, 0), max: SIMD3(x1 - t, y0 + t, top)),  // sides
                Box(min: SIMD3(x0 + t, y1 - t, 0), max: SIMD3(x1 - t, y1, top)),
                Box(min: SIMD3(20, y0 + t, 0), max: SIMD3(20.15, y1 - t, floors[0])),  // inside, ground floor
            ]
            let slabs = floors.map { Box(min: SIMD3(x0 + t, y0 + t, $0), max: SIMD3(x1 - t, y1 - t, $0 + t)) }
            var structure = StructureModel(solids: walls + slabs, elementSize: 0.125)
            for index in walls.indices { structure.setMaterial(.concreteBlock, of: index) }
            for slab in slabs {
                structure.addMat(to: slab, thicknessAxis: 2, areaPerMetre: Self.barArea, depth: Self.barDepth)
            }
            structure.elementKind = .shell
            var openings: [Box] = []
            for x in [x0, x1 - t] {
                for (z, height) in [(Float(0.9), Float(1.3)), (Float(3.5), Float(1.3))] {
                    for y in [y0 + 1.5, y1 - 2.7] {
                        openings.append(
                            Box(min: SIMD3(x - 0.1, y, z), max: SIMD3(x + t + 0.1, y + 1.2, z + height)))
                    }
                }
            }
            // The front door and the doorway inside.
            openings.append(Box(min: SIMD3(x0 - 0.1, 15.9, 0), max: SIMD3(x0 + t + 0.1, 16.9, 2.1)))
            openings.append(Box(min: SIMD3(19.9, 16, 0), max: SIMD3(20.25, 17, 2.1)))
            structure.openings = openings
            return Scenario(
                name: title, domainSize: SIMD3(32, 32, 12), boxes: [],
                charge: Charge(mass: 25, position: SIMD3(6, 16.5, 0.8)),
                gauges: [
                    Gauge("Front wall", at: SIMD3(15.9, 14, 1.5)),
                    Gauge("Front room", at: SIMD3(18, 14, 1.5)),
                    Gauge("Back room", at: SIMD3(22, 14, 1.5)),
                    Gauge("Behind the house", at: SIMD3(26, 16.5, 1.5)),
                ],
                structure: structure)

        case .blockWall:
            // A boundary wall of concrete blockwork, 225 mm thick, 2 m high and 9 m long between
            // short return walls, unreinforced. Its 75 mm solid elements are a third of a course
            // and a sixth of a block, so the blocks and their mortar joints are meshed: the wall
            // cracks along its bed joints and in steps between them. 5 kg, 6 m in front.
            let h: Float = 0.075
            let (y0, y1): (Float, Float) = (11.4, 20.4)
            let height = 27 * h
            let walls = [
                Box(min: SIMD3(18, y0, 0), max: SIMD3(18 + 3 * h, y1, height)),
                Box(min: SIMD3(18 + 3 * h, y0, 0), max: SIMD3(18 + 23 * h, y0 + 3 * h, height)),
                Box(min: SIMD3(18 + 3 * h, y1 - 3 * h, 0), max: SIMD3(18 + 23 * h, y1, height)),
            ]
            let structure = StructureModel(solids: walls, material: .concreteBlock, elementSize: h)
            return Scenario(
                name: title, domainSize: SIMD3(32, 32, 16), boxes: [],
                charge: Charge(mass: 5, position: SIMD3(12, 15.9, 0.8)),
                gauges: [
                    Gauge("Wall, front", at: SIMD3(17.9, 15.9, 1)),
                    Gauge("Wall, behind", at: SIMD3(18.4, 15.9, 1)),
                    Gauge("5 m behind", at: SIMD3(23, 15.9, 1.5)),
                ],
                structure: structure)

        case .internalExplosion:
            // The reinforced concrete chamber of Shang et al. (2026), half of it: see ChamberTest.
            return ChamberTest.scenario()

        case .tallFrame:
            // An eight-storey concrete frame, 28 m high: three bays by two of 6 m, 3.5 m storeys,
            // 250 mm flat slabs and 450 mm columns with 2.5% of steel, meshed as shells and
            // beams of 0.25 m. The charge stands 3 m from a ground-floor column in the middle
            // of the long face; what it breaks there decides whether the floors above can
            // bridge the gap or come down onto those below. At 500 kg it sways 0.9 m and stands;
            // at 1,000 and 2,000 kg the first floor punches off its columns and drops, and the
            // rest stands; at 4,000 kg, a truck bomb, the lower floors punch through and fall, and
            // whether the rest follow changes with small differences: one version of the model
            // brought the whole frame down, the next left six floors standing.
            let column: Float = 0.45
            let storey: Float = 3.5
            let xs: [Float] = [16, 22, 28, 34]
            let ys: [Float] = [14, 20, 26]
            let levels = (1...8).map { Float($0) * storey - 0.25 }
            let top = levels.last! + 0.25
            var columns: [Box] = []
            for x in xs {
                for y in ys {
                    columns.append(Box(x: x...(x + column), y: y...(y + column), height: top))
                }
            }
            let slabs = levels.map {
                Box(
                    min: SIMD3(xs.first!, ys.first!, $0),
                    max: SIMD3(xs.last! + column, ys.last! + column, $0 + 0.25))
            }
            var structure = StructureModel(solids: columns + slabs, elementSize: 0.25)
            structure.elementKind = .shell
            for index in columns.indices {
                structure.setReinforcement(.column(longitudinal: 0.025, ties: 0.005), of: index)
            }
            for index in slabs.indices {
                structure.setReinforcement(
                    .mats(areaPerMetre: 754e-6, depth: Self.barDepth, bothFaces: true),
                    of: columns.count + index)
            }
            structure.autoReinforce()
            return Scenario(
                name: title, domainSize: SIMD3(56, 44, 36), boxes: [],
                charge: Charge(mass: 4000, position: SIMD3(22.2, 11, 1)),
                gauges: [
                    Gauge("Front column", at: SIMD3(22.2, 13.9, 1.5)),
                    Gauge("Under first floor", at: SIMD3(25, 17, 3)),
                    Gauge("Roof", at: SIMD3(25, 20, top + 0.5)),
                ],
                structure: structure)

        case .coreTower:
            // A twelve-storey tower, 42 m high: a 6 m square concrete core of 300 mm walls (lift
            // and stair shafts, with a doorway on each floor) in the middle of a 20 m square
            // floor plate, 250 mm flat slabs on twelve perimeter columns of 500 mm with 2.5% of
            // steel, meshed as shells and beams of 0.25 m. The charge stands 3 m from the
            // middle column of the front face. Up to 2,000 kg the tower loses its front columns
            // and its lowest floor, and the core and floors above bridge them; at 4,000 kg the
            // floors punch off their columns and the core goes over.
            let column: Float = 0.5
            let storey: Float = 3.5
            let (x0, x1): (Float, Float) = (18, 38)
            let (y0, y1): (Float, Float) = (14, 34)
            let levels = (1...12).map { Float($0) * storey - 0.25 }
            let top = levels.last! + 0.25
            let grid: [Float] = [0, 20.0 / 3, 40.0 / 3, 20 - column]
            var columns: [Box] = []
            for (n, a) in grid.enumerated() {
                for b in n == 0 || n == 3 ? grid : [grid[0], grid[3]] {
                    columns.append(
                        Box(x: (x0 + a)...(x0 + a + column), y: (y0 + b)...(y0 + b + column), height: top))
                }
            }
            let (c0, c1): (Float, Float) = (25, 31)
            let (d0, d1): (Float, Float) = (21, 27)
            let t: Float = 0.3
            let core = [
                Box(min: SIMD3(c0, d0, 0), max: SIMD3(c0 + t, d1, top)),
                Box(min: SIMD3(c1 - t, d0, 0), max: SIMD3(c1, d1, top)),
                Box(min: SIMD3(c0 + t, d0, 0), max: SIMD3(c1 - t, d0 + t, top)),
                Box(min: SIMD3(c0 + t, d1 - t, 0), max: SIMD3(c1 - t, d1, top)),
            ]
            let slabs = levels.map { Box(min: SIMD3(x0, y0, $0), max: SIMD3(x1, y1, $0 + 0.25)) }
            var structure = StructureModel(solids: columns + core + slabs, elementSize: 0.25)
            structure.elementKind = .shell
            for index in columns.indices {
                structure.setReinforcement(.column(longitudinal: 0.025, ties: 0.005), of: index)
            }
            for index in slabs.indices {
                structure.setReinforcement(
                    .mats(areaPerMetre: 754e-6, depth: Self.barDepth, bothFaces: true),
                    of: columns.count + core.count + index)
            }
            structure.autoReinforce()
            // A doorway into the core on every floor, through its front wall.
            structure.openings = ([0] + levels.dropLast().map { $0 + 0.25 }).map { floor in
                Box(min: SIMD3(27.5, d0 - 0.1, floor), max: SIMD3(28.5, d0 + t + 0.1, floor + 2.1))
            }
            return Scenario(
                name: title, domainSize: SIMD3(56, 48, 52), boxes: [],
                charge: Charge(mass: 4000, position: SIMD3(x0 + 20.0 / 3 + 0.25, y0 - 3, 1)),
                gauges: [
                    Gauge("Front column", at: SIMD3(x0 + 20.0 / 3 + 0.25, y0 - 0.1, 1.5)),
                    Gauge("Core, front", at: SIMD3(28, d0 - 0.1, 1.5)),
                    Gauge("Roof", at: SIMD3(28, 24, top + 0.5)),
                ],
                structure: structure)

        case .threeStorey:
            // A three-storey concrete frame, three bays by two of 6 m, with 250 mm flat slabs and
            // 375 mm columns, clad on all four faces in 250 mm masonry with a window in every
            // panel. The charge stands 8 m in front of the middle of the long face.
            let h: Float = 0.125
            let column: Float = 0.375
            let xs: [Float] = [16, 22, 28, 34]
            let ys: [Float] = [14, 20, 26]
            let levels: [Float] = [3.25, 6.75, 10.25]
            let top = levels.last! + 0.25
            var columns: [Box] = []
            for x in xs {
                for y in ys {
                    columns.append(Box(x: x...(x + column), y: y...(y + column), height: top))
                }
            }
            let slabs = levels.map {
                Box(
                    min: SIMD3(xs.first!, ys.first!, $0),
                    max: SIMD3(xs.last! + column, ys.last! + column, $0 + 0.25))
            }
            var structure = StructureModel(solids: columns + slabs, elementSize: h)
            for box in columns {
                structure.reinforcement.append(
                    ReinforcementLayer(region: box, ratio: SIMD3(0.004, 0.004, 0.02)))
            }
            for slab in slabs {
                structure.addMat(to: slab, thicknessAxis: 2, areaPerMetre: 754e-6, depth: Self.barDepth)
            }
            // Masonry panels between the columns and from slab to slab, on the outer faces.
            let floors: [(Float, Float)] = [
                (0, levels[0]), (levels[0] + 0.25, levels[1]), (levels[1] + 0.25, levels[2]),
            ]
            var windows: [Box] = []
            for (z0, z1) in floors {
                for (x0, x1) in zip(xs, xs.dropFirst()) {
                    for y in [ys.first!, ys.last! + column - 0.25] {
                        structure.solids.append(
                            Box(min: SIMD3(x0 + column, y, z0), max: SIMD3(x1, y + 0.25, z1)))
                        structure.setMaterial(.masonry, of: structure.solids.count - 1)
                        let middle = (x0 + column + x1) / 2
                        windows.append(
                            Box(
                                min: SIMD3(middle - 1, y - 0.1, z0 + 1),
                                max: SIMD3(middle + 1, y + 0.35, z0 + 2.25)))
                    }
                }
                for (y0, y1) in zip(ys, ys.dropFirst()) {
                    for x in [xs.first!, xs.last! + column - 0.25] {
                        structure.solids.append(
                            Box(min: SIMD3(x, y0 + column, z0), max: SIMD3(x + 0.25, y1, z1)))
                        structure.setMaterial(.masonry, of: structure.solids.count - 1)
                    }
                }
            }
            structure.openings = windows
            return Scenario(
                name: title, domainSize: SIMD3(56, 44, 20), boxes: [],
                charge: Charge(mass: 100, position: SIMD3(25, 6, 1)),
                gauges: [
                    Gauge("Front face", at: SIMD3(25, 13.9, 1.5)),
                    Gauge("Inside, ground floor", at: SIMD3(25, 17, 1.5)),
                    Gauge("Behind", at: SIMD3(25, 30, 1.5)),
                ],
                structure: structure)
        }
    }
}
