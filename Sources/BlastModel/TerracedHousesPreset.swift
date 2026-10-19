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

    /// A roof slope of 100 x 50 mm rafters at 400 mm with their battens, smeared into a plate of
    /// timber 50 mm thick with its grain up the slope (`grainAxis` 2 on a plane at a pitch, along
    /// its second edge): the rafters' bending stiffness per metre (2.5 rafters of I = 4.17e6
    /// mm^4, the plate's 50 mm), their and the battens' mass (9 kg/m^2: rafters at 370 kg/m^3 and
    /// 25 x 38 mm battens at 100 mm gauge), and their bending capacity (the plate's strength along
    /// the grain 0.5 of C16's, the rafters' section modulus per metre over the plate's). 100 x 50
    /// rafters span about 2.5 m at 30-45 degrees under tiles (building control's span tables, e.g.
    /// Eden District Council's), so a pitched roof of the 1930s has a purlin at mid-slope.
    static var rafteredRoof: StructureMaterial {
        var properties = TimberProperties.strengthClass(.c16)
        properties.grainAxis = 2
        properties.tensionAlong *= 0.5
        properties.compressionAlong *= 0.5
        return .timber(name: "Raftered roof (C16)", density: 180, properties: properties)
    }

    /// What a roof is covered with, as laid on its battens.
    public enum RoofCovering: String, CaseIterable, Sendable {
        /// Nibbed clay plain tiles at 100 mm gauge, 73.2 kg/m^2 (Keymer's, as laid; clay plain
        /// tiles run 55 to 75).
        case plainClayTiles
        /// Concrete interlocking tiles, 50 kg/m^2 at 75 mm headlap (Marley's Modern and Wessex).
        case concreteInterlockingTiles
        /// Welsh slate, about 25 kg/m^2 (20 to 27 in builders' tables).
        case welshSlate

        /// Mass as laid, kg/m^2.
        public var mass: Float {
            switch self {
            case .plainClayTiles: 73.2
            case .concreteInterlockingTiles: 50
            case .welshSlate: 25
            }
        }

        /// The covering as a layer 25 mm thick of its mass, which holds together only weakly:
        /// tiles and slates overlap but are not joined, so a covering lifted off its roof breaks
        /// up into pieces of about an element and is thrown as debris. Its stiffness is nominal.
        public var material: StructureMaterial {
            var material = StructureMaterial.concrete(
                name: rawValue == "welshSlate" ? "Slates (as laid)" : "Roof tiles (as laid)",
                compressiveStrength: 30e6, density: mass / RoofCovering.thickness)
            material.youngsModulus = 1e9
            material.tensileStrength = 10e3
            material.fractureEnergy = 1
            material.erosionOpening = 0.003
            return material
        }

        package static let thickness: Float = 0.025
    }

    /// A roof covering resting on its battens: on its weight alone, with friction, its nails
    /// left out (BS 5534 nails nibbed plain tiles on every fourth or fifth course and every slate;
    /// no measured pull-out of either was found), so that suction greater than its weight lifts
    /// it. Once it has slid half an element off the roof it is off for good.
    public static let roofCoveringSeat = Anchorage(
        normalStiffness: 1e9, shearStiffness: 1e9, tensileStrength: 0, tensionOpening: 0, cohesion: 0,
        cohesionSlip: 0, friction: 0.5, betweenParts: true)

    /// A covering on a pitched roof: nibbed plain tiles hang on their battens by their nibs, and
    /// BS 5534 nails every tile of every fifth course twice (Marley's and Wienerberger's summaries of
    /// it), so the covering does not slide down a roof steeper than its friction, as the flat
    /// roof's (`roofCoveringSeat`) would: its seat holds along the slope (a cohesion of 5 kPa,
    /// ten times the downhill share of 73 kg/m^2 of tiles at 40 degrees; the nibs' and nails'
    /// own strength was not found) until the covering lifts off its battens by their depth
    /// (25 mm, 38 x 25 mm battens), or slid 10 mm, off its nibs, when it rests on friction alone,
    /// as the flat roof's does. Its normal is the slope's (`normal`), and it ties only the
    /// covering's faces (`solids`) to the slope's nodes (`slope`).
    public static func pitchedCoveringSeat(normal: SIMD3<Float>, solids: [Int], slope: Int) -> Anchorage {
        var law = Anchorage(
            normalStiffness: 1e9, shearStiffness: 1e9, tensileStrength: 1, tensionOpening: 0.025,
            cohesion: 5e3, cohesionSlip: 0.01, friction: 0.5, betweenParts: true)
        law.jointNormal = normal
        law.solids = solids
        law.partners = [slope]
        return law
    }

    /// Wall ties across a cavity, smeared over the wall at 2.47 a square metre (one per 900 mm
    /// across and 450 mm up, the standard layout, PD 6697 and Approved Document A; LABC Warranty,
    /// "Wall tie replacement in existing buildings", 2020, for ties of the 1930s): each pulls out
    /// at 1.18 kN and buckles at 0.55 kN, the mean axial strengths of as-built ties in Messali and
    /// Ravenshorst's database (TU Delft report CM1B05-WP1, 2019, Table 12: 3.6 mm wire ties tested
    /// in old cavity walls). Arslan et al. (Construction and Building Materials 266, 2021, 121141)
    /// give the shape: stiff to about half the peak, the peak at 4 to 12 mm, then a slow slide
    /// out of the mortar to nothing near 50 mm; here 0.3 kN/mm, held to 10 mm, gone at 50 mm.
    /// Ties carry next to no shear (0.1 to 0.2 kN at 20 mm, Skroumpelou et al., 2018), so the
    /// joint has no cohesion. Once buckled the leaves close the cavity freely and then bear on
    /// each other, with friction.
    ///
    /// - Parameter cavity: The gap between the leaves, in metres.
    public static func cavityWallTies(cavity: Float) -> Anchorage {
        let density: Float = 1 / (0.9 * 0.45)
        var law = Anchorage(
            normalStiffness: 0.3e6 * density, shearStiffness: 0.3e6 * density,
            tensileStrength: 1.18e3 * density, tensionPlateau: 0.01, tensionOpening: 0.05, cohesion: 0,
            cohesionSlip: 0, friction: 0.6, bearingCapacity: 0.55e3 * density, betweenParts: true)
        law.closingGap = cavity
        return law
    }

    /// A joist's end in its pocket in a brick wall, unstrapped as in houses before the 1980s (LABC
    /// Warranty, 2020: older walls get "no restraint" from the floors): it bears on the brick,
    /// can lift off it, and is held along its length by friction alone, until it has slid out of
    /// the pocket. Messali and Ravenshorst (2019, Tables 1 and 2, TU Delft's tests of joists in
    /// pockets) found 0.5 to 0.7 kN to pull a joist out, as friction of 0.6 to 0.95 (here 0.7)
    /// and an initial shear strength of 0.02 to 0.06 MPa (here 0.04, lost over 2 mm) on the
    /// joists' bearing, 47 mm joists at 400 mm resting 100 mm in the wall: 0.0118 m^2 per metre
    /// of wall, spread over the plate's edge of `bearingArea` m^2 per metre.
    public static func joistPocket(bearingArea: Float) -> Anchorage {
        let contact: Float = 2.5 * 0.047 * 0.1
        return Anchorage(
            tensileStrength: 0, tensionOpening: 0, cohesion: 0.04e6 * contact / bearingArea,
            cohesionSlip: 0.002, friction: 0.7, betweenParts: true)
    }

    /// A short row of three two-storey terraced houses, as built in the UK from the 1930s:
    /// - **Walls:** cavity walls of two brick leaves, 102.5 mm each, 50 mm apart, at the front,
    ///   the back and the two gables, their leaves bonded round the corners and tied across the
    ///   cavity (`cavityWallTies`); one-brick (215 mm) party walls between the houses.
    /// - **Floors and roof:** timber joists spanning between the party walls and gables, smeared
    ///   into plates (`joistedFloor`), their ends resting in pockets 100 mm deep in the walls
    ///   (`joistPocket`) and stopping 25 mm short of the front and back walls, which they do not
    ///   restrain; the pitched roof as a flat roof of the same make at the eaves, under its
    ///   covering (`RoofCovering`, plain clay tiles unless given) on battens
    ///   (`roofCoveringSeat`).
    /// - **Size:** 5 m wide and 8.5 m deep (about 42 m^2 a floor) with 2.6 m storeys.
    /// - **Openings:** a window on each floor front and back, and a front door, open (no glass).
    /// - **The charge:** 25 kg in the street, 10 m in front of the middle house
    ///   (`terracedRow(title:charge:standoff:height:)` puts others elsewhere).
    ///
    /// Sources: the University of the West of England's Construction Web, "Evolution of building
    /// elements" (cavity walls of two brick leaves from the 1930s; 200 x 50 mm joists at 300 to
    /// 400 mm built into the walls; cut roofs carried on the party walls); the English Housing
    /// Survey, "Floor space in English homes" (2018: terraced houses of 80 to 86 m^2). The storey
    /// height is assumed. Pre-1919 terraces, about a third of them, have solid one-brick walls
    /// instead.
    static func terracedHousesScenario(title: String) -> Scenario {
        terracedRow(title: title)
    }

    /// The row of terraced houses (`terracedHousesScenario`) with a charge of `charge` kg of TNT
    /// `standoff` m in front of the middle house's front wall, `height` m above the ground. The
    /// domain's open faces are `faceClearance` m from the charge and the row, 4 m/kg^(1/3) unless
    /// given (`Scenario.structureFaceClearance`), and never nearer than 6 m in front, 8 m to
    /// the sides and 7.5 m behind.
    public static func terracedRow(
        title: String, charge: Float = 25, standoff: Float = 10, height: Float = 0.8,
        covering: RoofCovering? = .plainClayTiles, faceClearance: Float? = nil, pitch: Float? = 40
    ) -> Scenario {
        let clearance = faceClearance ?? Scenario.structureFaceClearance * cbrt(charge)
        let leaf: Float = 0.1025
        let cavity: Float = 0.05
        let wall = 2 * leaf + cavity
        let party: Float = 0.215
        let x0 = (standoff + max(clearance, 6)).rounded(.up)
        let x1 = x0 + 8.5
        let y0 = max(clearance, 8).rounded(.up)
        let ys: [Float] = [y0, y0 + 5, y0 + 10, y0 + 15]
        let floors: [Float] = [2.6, 5.2]
        let joists: Float = 0.098
        let top = floors.last! + joists
        // A pitched roof: two slopes over the row's depth, front and back, from the eaves at the
        // walls' tops to a ridge along the row; the gables and party walls rise to it.
        let run = (x1 - x0) / 2
        let rise = pitch.map { run * tan($0 * .pi / 180) } ?? 0
        let ridge = top + rise
        // Clear of a wall's face where the joists' plates end, enough for the plate's last nodes
        // to stay apart from the wall's (the mesh keeps nodes half an element apart).
        let clear: Float = 0.025
        let bearing: Float = 0.1
        let h: Float = 0.125
        // Cavity walls: two leaves each, from `start` to `end` along the wall; the outer leaves
        // run to the corners, where they meet, the inner ones to the inner corners.
        func cavityWall(
            along axis: Int, outer: Float, inward: Float, from start: Float, to end: Float, up: Float = top
        )
            -> [Box]
        {
            [(outer, Float(0)), (outer + inward * (leaf + cavity), leaf + cavity)].map { face, inset in
                let low = min(face, face + inward * leaf)
                return axis == 0
                    ? Box(min: SIMD3(low, start + inset, 0), max: SIMD3(low + leaf, end - inset, up))
                    : Box(min: SIMD3(start + inset, low, 0), max: SIMD3(end - inset, low + leaf, up))
            }
        }
        var walls: [Box] = []
        walls += cavityWall(along: 0, outer: x0, inward: 1, from: ys[0], to: ys[3])  // front
        walls += cavityWall(along: 0, outer: x1, inward: -1, from: ys[0], to: ys[3])  // back
        walls += cavityWall(along: 1, outer: ys[0], inward: 1, from: x0, to: x1, up: ridge)  // gables
        walls += cavityWall(along: 1, outer: ys[3], inward: -1, from: x0, to: x1, up: ridge)
        for y in ys[1...2] {
            walls.append(
                Box(min: SIMD3(x0 + wall, y - party / 2, 0), max: SIMD3(x1 - wall, y + party / 2, ridge)))
        }
        // Floors and roof, house by house between the party walls, joists spanning across them,
        // each end seated in its wall.
        var plates: [Box] = []
        var seats: [(region: Box, face: Float)] = []
        for (low, high) in zip(ys, ys.dropFirst()) {
            let start = (low == ys[0] ? low + wall : low + party / 2) + clear
            let end = (high == ys[3] ? high - wall : high - party / 2) - clear
            for z in floors {
                plates.append(
                    Box(
                        min: SIMD3(x0 + wall + clear, start, z - joists),
                        max: SIMD3(x1 - wall - clear, end, z)))
                // The seats reach from the wall's far face to `bearing` past the plate's edge, the
                // last half element the edge nodes' own share (`ShellSolver.setUpPairs`).
                let far = (low == ys[0] ? low : low - party / 2)
                let farHigh = (high == ys[3] ? high : high + party / 2)
                seats.append(
                    (Box(min: SIMD3(x0, far, z - joists), max: SIMD3(x1, start + bearing - h / 2, z)), 1))
                seats.append(
                    (Box(min: SIMD3(x0, end - bearing + h / 2, z - joists), max: SIMD3(x1, farHigh, z)), -1))
            }
        }
        // The covering over the whole row, over the roof and the walls' tops (which stand a
        // joist's depth above the roof): 60 mm above them, more than its battens, so that the
        // mesh (which keeps nodes half an element apart) keeps the covering's nodes apart from
        // the walls'.
        let battens: Float = 0.06
        let roofing = Box(
            min: SIMD3(x0, ys[0], top + battens),
            max: SIMD3(x1, ys[3], top + battens + RoofCovering.thickness))
        // On a pitched roof: the two slopes from the eaves over the walls' outer faces to the
        // ridge, each with a purlin under it at mid-slope built into the gables and party walls
        // (100 x 175 mm C24, assumed: a cut roof's purlins were carried on the party walls), and
        // the covering on its battens, parallel to the slope, its midsurface 62.5 mm above the
        // slope's (half the slope, 25 mm battens, half the covering).
        let middle = (x0 + x1) / 2
        let slopes =
            pitch == nil
            ? []
            : [
                Box(min: SIMD3(x0, ys[0], top), max: SIMD3(middle, ys[3], ridge)),
                Box(min: SIMD3(middle, ys[0], top), max: SIMD3(x1, ys[3], ridge)),
            ]
        let slopeInclinations = [
            Inclination(rise: 0, upwards: true, thickness: 0.05, trimsWalls: true),
            Inclination(rise: 0, upwards: false, thickness: 0.05, trimsWalls: true),
        ]
        let angle = (pitch ?? 0) * .pi / 180
        let slopeNormals = [
            SIMD3<Float>(-sin(angle), 0, cos(angle)), SIMD3<Float>(sin(angle), 0, cos(angle)),
        ]
        let purlinSection = SIMD2<Float>(0.1, 0.175)
        let purlinX = [x0 + run / 2, x1 - run / 2]
        // The purlin's top 10 mm under the slope's underside.
        let purlinTop = top + rise / 2 - 0.025 / cos(angle) - 0.01
        let purlins =
            pitch == nil
            ? []
            : purlinX.map { x in
                Box(
                    min: SIMD3(x - purlinSection.x / 2, ys[0], purlinTop - purlinSection.y),
                    max: SIMD3(x + purlinSection.x / 2, ys[3], purlinTop))
            }
        let offset: Float = 0.0625
        let coverings =
            covering == nil
            ? []
            : pitch == nil
                ? [roofing]
                : zip(slopes, slopeNormals).map {
                    Box(min: $0.min + offset * $1, max: $0.max + offset * $1)
                }
        let pieces = walls + plates + slopes + purlins
        var structure = StructureModel(solids: pieces + coverings, material: .masonry, elementSize: h)
        for index in walls.count..<(walls.count + plates.count) {
            structure.setMaterial(Self.joistedFloor(grainAxis: 1), of: index)
        }
        let firstSlope = walls.count + plates.count
        for (n, inclination) in slopeInclinations.enumerated() where pitch != nil {
            structure.setMaterial(Self.rafteredRoof, of: firstSlope + n)
            structure.setInclination(inclination, of: firstSlope + n)
        }
        for n in purlins.indices {
            structure.setMaterial(.timber(.c24, grainAxis: 1), of: firstSlope + slopes.count + n)
        }
        let coveringSolids = Array(pieces.count..<(pieces.count + coverings.count))
        if let covering {
            for (n, index) in coveringSolids.enumerated() {
                structure.setMaterial(covering.material, of: index)
                if pitch != nil {
                    var inclination = slopeInclinations[n]
                    inclination.thickness = RoofCovering.thickness
                    inclination.trimsWalls = false
                    structure.setInclination(inclination, of: index)
                }
            }
        }
        structure.elementKind = .shell
        // Ties across each cavity, the whole wall, the inner leaf's nodes tied to the outer's; the
        // gables' up to the ridge.
        let ties = Self.cavityWallTies(cavity: cavity)
        for (region, inward) in [
            (Box(min: SIMD3(x0, ys[0], 0), max: SIMD3(x0 + wall, ys[3], top)), SIMD3<Float>(1, 0, 0)),
            (Box(min: SIMD3(x1 - wall, ys[0], 0), max: SIMD3(x1, ys[3], top)), SIMD3<Float>(-1, 0, 0)),
            (Box(min: SIMD3(x0, ys[0], 0), max: SIMD3(x1, ys[0] + wall, ridge)), SIMD3<Float>(0, 1, 0)),
            (Box(min: SIMD3(x0, ys[3] - wall, 0), max: SIMD3(x1, ys[3], ridge)), SIMD3<Float>(0, -1, 0)),
        ] {
            var law = ties
            law.jointNormal = inward
            // The leaves alone: a gable's region, up to the ridge, holds the slope's and the tiles'
            // edges too.
            if pitch != nil {
                law.solids = Array(walls.indices)
                law.partners = Array(walls.indices)
            }
            structure.supports.append(region)
            structure.setAnchorage(law, ofSupport: structure.supports.count - 1)
        }
        // Joist ends: the plate's edge stands for the joists' ends over half an element.
        let pocket = Self.joistPocket(bearingArea: structure.elementSize / 2)
        for seat in seats {
            structure.supports.append(seat.region)
            structure.setAnchorage(pocket, ofSupport: structure.supports.count - 1)
        }
        if pitch == nil {
            // The covering on the roof's and walls' nodes, from just below the roof's midsurface
            // (so that the roof's underside, which faces down too, is outside it and not tied).
            if covering != nil {
                structure.supports.append(
                    Box(min: SIMD3(x0, ys[0], floors.last! - joists / 2 - 0.02), max: roofing.max))
                structure.setAnchorage(Self.roofCoveringSeat, ofSupport: structure.supports.count - 1)
            }
        } else {
            // The rafters' feet on the front and back walls' tops, notched over their wall plates
            // to bear level (a birdsmouth), and the rafters over the purlins, as the joists' ends
            // are held (`joistPocket`, unstrapped and unnailed): house by house, front then back,
            // eaves then purlin. Then where the slopes bear on the gables and party walls, each
            // slope on its own, short of the ridge (whose nodes both share).
            // What the slopes bear on: the walls, plates and purlins, never the tiles of a lower
            // course, which lie under the rafters further up.
            let bearers = Array(0..<firstSlope) + purlins.indices.map { firstSlope + slopes.count + $0 }
            func seat(_ region: Box, slope: Int) {
                var law = pocket
                law.solids = [firstSlope + slope]
                law.partners = bearers
                structure.supports.append(region)
                structure.setAnchorage(law, ofSupport: structure.supports.count - 1)
            }
            let reach: Float = 0.2
            for house in 0..<3 {
                let low = house == 0 ? ys[0] : ys[house] + 0.01
                let high = house == 2 ? ys[3] : ys[house + 1] - 0.01
                for slope in 0..<2 {
                    let face = slope == 0 ? x0 : x1 - wall
                    seat(
                        Box(min: SIMD3(face, low, top - h), max: SIMD3(face + wall, high, top + 0.4)),
                        slope: slope)
                }
                for slope in 0..<2 {
                    let x = purlinX[slope]
                    seat(
                        Box(
                            min: SIMD3(x - reach, low, purlinTop - purlinSection.y - 0.01),
                            max: SIMD3(x + reach, high, purlinTop + 0.3)), slope: slope)
                }
            }
            for (low, high) in [(ys[0], ys[0] + wall)] + ys[1...2].map({ ($0 - party / 2, $0 + party / 2) })
                + [(ys[3] - wall, ys[3])]
            {
                // Past the front and back walls' seats, so that no point of a slope is seated twice.
                seat(
                    Box(min: SIMD3(x0 + wall, low, top - h), max: SIMD3(middle - 0.01, high, ridge + 0.1)),
                    slope: 0)
                seat(
                    Box(min: SIMD3(middle + 0.01, low, top - h), max: SIMD3(x1 - wall, high, ridge + 0.1)),
                    slope: 1)
            }
            // Each slope's covering on it.
            for (n, solid) in coveringSolids.enumerated() {
                let region =
                    n == 0
                    ? Box(min: SIMD3(x0 - 0.2, ys[0], top - 0.2), max: SIMD3(middle, ys[3], ridge + 0.3))
                    : Box(min: SIMD3(middle, ys[0], top - 0.2), max: SIMD3(x1 + 0.2, ys[3], ridge + 0.3))
                structure.supports.append(region)
                structure.setAnchorage(
                    Self.pitchedCoveringSeat(normal: slopeNormals[n], solids: [solid], slope: firstSlope + n),
                    ofSupport: structure.supports.count - 1)
            }
        }
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
        let centre = (ys[1] + ys[2]) / 2
        return Scenario(
            name: title,
            domainSize: SIMD3(
                max(x1 + 7.5, x0 - standoff + clearance).rounded(.up), ys[3] + y0,
                max(12, ridge + 0.5 + clearance).rounded(.up)),
            boxes: [],
            charge: Charge(mass: charge, position: SIMD3(x0 - standoff, centre, height)),
            gauges: [
                Gauge("Front wall", at: SIMD3(x0 - 0.1, centre - 1, 1.5)),
                Gauge("Front room", at: SIMD3(x0 + 2, centre - 1, 1.5)),
                Gauge("Back room", at: SIMD3(x1 - 2, centre - 1, 1.5)),
                Gauge("Behind the houses", at: SIMD3(x1 + 2, centre, 1.5)),
            ],
            structure: structure)
    }
}
