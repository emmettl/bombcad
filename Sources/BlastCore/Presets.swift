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
        case .internalExplosion: "Internal explosion (test)"
        }
    }

    /// Reinforcement of the deformable presets: 12 mm bars at 200 mm centres, both ways, in
    /// each face (565 mm² per metre), with their centres 40 mm below the surface.
    static let barArea: Float = 565e-6
    static let barDepth: Float = 0.04

    public var scenario: Scenario {
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
                // Masonry needs far less: 50 kg breaches one panel and cracks the rest.
                charge: Charge(mass: self == .infilledFrame ? 50 : 250, position: SIMD3(18, 10, 1)),
                gauges: [
                    Gauge("Front column", at: SIMD3(20.2, 12.9, 1.5)),
                    Gauge("Under first slab", at: SIMD3(20, 16, 3)),
                    Gauge("Behind", at: SIMD3(20, 22, 1.5)),
                ],
                structure: structure)

        case .internalExplosion:
            // The reinforced concrete chamber of Shang et al. (2026), half of it: see ChamberTest.
            return ChamberTest.scenario()

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
