import Foundation
import simd

extension ScenarioPreset {
    /// A floor or flat roof of 47 x 200 mm C24 joists at 400 mm under 22 mm boards, smeared into
    /// a plate of timber 98 mm thick with its grain along `grainAxis` (the joists' span): the
    /// joists' bending stiffness per metre (2.5 joists of I = 31.3e6 mm^4), their and the boards'
    /// mass (19 kg/m^2, as a density of 196 kg/m^3 over 98 mm), and their bending capacity (the
    /// plate's strength along the grain is 0.49 of C24's, the joists' section modulus per metre
    /// over the plate's). The mesh's 125 mm elements cannot hold the joists themselves.
    static func joistedFloor(grainAxis: Int) -> StructureMaterial {
        var properties = TimberProperties.strengthClass(.c24)
        properties.grainAxis = grainAxis
        properties.tensionAlong *= 0.49
        properties.compressionAlong *= 0.49
        return .timber(name: "Joisted floor (C24)", density: 196, properties: properties)
    }

    /// A short row of three two-storey terraced houses, as built in the UK from the 1930s:
    /// - **Walls:** cavity walls of two brick leaves, 102.5 mm each, 50 mm apart, at the front,
    ///   the back and the two gables; one-brick (215 mm) party walls between the houses. The
    ///   leaves are not tied (wall ties are not modelled).
    /// - **Floors and roof:** timber joists spanning between the party walls, smeared into plates
    ///   (`joistedFloor`); the pitched roof as a flat roof of the same make at the eaves.
    /// - **Size:** 5 m wide and 8.5 m deep (about 42 m^2 a floor) with 2.6 m storeys.
    /// - **Openings:** a window on each floor front and back, and a front door, open (no glass).
    /// - **The charge:** 25 kg in the street, 10 m in front of the middle house.
    ///
    /// Sources: the University of the West of England's Construction Web, "Evolution of building
    /// elements" (cavity walls of two brick leaves from the 1930s; 200 x 50 mm joists at 300 to
    /// 400 mm built into the walls; cut roofs carried on the party walls); the English Housing
    /// Survey, "Floor space in English homes" (2018: terraced houses of 80 to 86 m^2). The storey
    /// height is assumed. Pre-1919 terraces, about a third of them, have solid one-brick walls
    /// instead.
    static func terracedHousesScenario(title: String) -> Scenario {
        let leaf: Float = 0.1025
        let cavity: Float = 0.05
        let wall = 2 * leaf + cavity
        let party: Float = 0.215
        let (x0, x1): (Float, Float) = (16, 24.5)
        let ys: [Float] = [8, 13, 18, 23]
        let floors: [Float] = [2.6, 5.2]
        let joists: Float = 0.098
        let top = floors.last! + joists
        // Cavity walls: two leaves each.
        func cavityWall(along axis: Int, at low: Float, from start: Float, to end: Float) -> [Box] {
            [low, low + leaf + cavity].map { face in
                axis == 0
                    ? Box(min: SIMD3(face, start, 0), max: SIMD3(face + leaf, end, top))
                    : Box(min: SIMD3(start, face, 0), max: SIMD3(end, face + leaf, top))
            }
        }
        var walls: [Box] = []
        walls += cavityWall(along: 0, at: x0, from: ys[0], to: ys[3])  // front
        walls += cavityWall(along: 0, at: x1 - wall, from: ys[0], to: ys[3])  // back
        walls += cavityWall(along: 1, at: ys[0], from: x0 + wall, to: x1 - wall)  // gables
        walls += cavityWall(along: 1, at: ys[3] - wall, from: x0 + wall, to: x1 - wall)
        for y in ys[1...2] {
            walls.append(
                Box(min: SIMD3(x0 + wall, y - party / 2, 0), max: SIMD3(x1 - wall, y + party / 2, top)))
        }
        // Floors and roof, house by house between the party walls, joists spanning across them.
        var plates: [Box] = []
        for (low, high) in zip(ys, ys.dropFirst()) {
            let start = low == ys[0] ? low + wall : low + party / 2
            let end = high == ys[3] ? high - wall : high - party / 2
            for z in floors {
                plates.append(
                    Box(min: SIMD3(x0 + wall, start, z - joists), max: SIMD3(x1 - wall, end, z)))
            }
        }
        var structure = StructureModel(solids: walls + plates, material: .masonry, elementSize: 0.125)
        for index in walls.count..<(walls.count + plates.count) {
            structure.setMaterial(Self.joistedFloor(grainAxis: 1), of: index)
        }
        structure.elementKind = .shell
        // Openings through both leaves: front and back windows on each floor, a front door.
        var openings: [Box] = []
        for low in ys.dropLast() {
            for x in [x0, x1 - wall] {
                for (z, height) in [(Float(0.9), Float(1.4)), (Float(3.4), Float(1.2))] {
                    openings.append(
                        Box(
                            min: SIMD3(x - 0.1, low + 2.6, z),
                            max: SIMD3(x + wall + 0.1, low + 4.0, z + height)))
                }
            }
            openings.append(
                Box(min: SIMD3(x0 - 0.1, low + 0.7, 0), max: SIMD3(x0 + wall + 0.1, low + 1.6, 2.1)))
        }
        structure.openings = openings
        let middle = (ys[1] + ys[2]) / 2
        return Scenario(
            name: title, domainSize: SIMD3(32, 31, 12), boxes: [],
            charge: Charge(mass: 25, position: SIMD3(6, middle, 0.8)),
            gauges: [
                Gauge("Front wall", at: SIMD3(x0 - 0.1, middle - 1, 1.5)),
                Gauge("Front room", at: SIMD3(x0 + 2, middle - 1, 1.5)),
                Gauge("Back room", at: SIMD3(x1 - 2, middle - 1, 1.5)),
                Gauge("Behind the houses", at: SIMD3(x1 + 2, middle, 1.5)),
            ],
            structure: structure)
    }
}
