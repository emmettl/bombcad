import Foundation
import simd

/// F. C. F. Alsubaei's perimeter walls under field blasts: *Performance of protective perimeter
/// walls subjected to explosions in reducing the blast resultants on buildings*, Master's thesis,
/// Western University, 2015 (hdl:20.500.14721/35930). The derived numbers are in
/// `Fixtures/Alsubaei2015/walls.json`, with what is known and not known of each test.
///
/// ANFO charges on a table in front of a reinforced concrete wall on a buried footing, wing walls
/// either side to stop the wave wrapping round its ends, and pressure gauges on steel pipe
/// columns behind it, facing the charge. The air alone is checked here, with the wall rigid: the
/// columns' peaks with no wall, and how much the wall takes off them.
public enum PerimeterWallTests {
    /// The thesis's TNT equivalence of ANFO, for pressure and impulse alike (its Table 4.1).
    public static let tntFactor: Float = 0.82

    /// One test arrangement: the wall and the columns behind it, along the line from the charge.
    public struct Layout: Sendable {
        public var name: String
        /// From the charge's centre to the wall's front face, and the charge's height above the
        /// ground.
        public var chargeToWall: Float
        public var heightOfBurst: Float
        public var wallHeight: Float
        public var wallThickness: Float
        /// A flange on top of the wall (a canopy), reaching this far beyond each face, and its
        /// depth; zero for a plain wall.
        public var canopyReach: Float = 0
        public var canopyDepth: Float = 0
        /// From the charge's centre to each column's front face, and the gauges' heights on them.
        public var chargeToColumns: [Float]
        public var gaugeHeights: [Float]
        /// The air reaches `margin` behind the charge and beyond the last column, and `ceiling`
        /// above the top gauge; the domain is `width` across, the wall spanning it.
        public var margin: Float
        public var width: Float
        public var ceiling: Float

        /// The wall's top, canopy included.
        public var top: Float { wallHeight + canopyDepth }
    }

    /// Chapters 4 and 5: the half-scale plane wall PWS, 1 m high and 0.2 m thick, the charge 2 m
    /// in front at 0.5 m, columns 4.2, 8.2 and 11.85 m from the charge.
    public static let halfScale = Layout(
        name: "Half-scale plane wall, charge 2 m in front", chargeToWall: 2, heightOfBurst: 0.5,
        wallHeight: 1,
        wallThickness: 0.2, chargeToColumns: [4.2, 8.2, 11.85], gaugeHeights: [0.75, 2.25, 3.75, 5.25],
        margin: 1,
        width: 8, ceiling: 1.5)

    /// Chapter 6: the same wall, the charge 3 m in front, columns 5.2, 9.2 and 12.85 m from it.
    public static let halfScaleStreet = Layout(
        name: "Half-scale plane wall, charge 3 m in front", chargeToWall: 3, heightOfBurst: 0.5,
        wallHeight: 1,
        wallThickness: 0.2, chargeToColumns: [5.2, 9.2, 12.85], gaugeHeights: [0.75, 2.25, 3.75, 5.25],
        margin: 1,
        width: 8, ceiling: 1.5)

    /// Chapter 7: the full-scale wall with a canopy, a stem 2 m high and 0.4 m thick under a flange
    /// 1.2 m wide and 0.4 m deep (the thesis's Figure 7.2; its Figure 7.7 and text give the wall
    /// as 2 m high overall), the charge 4 m in front at 1 m, a column 16.4 m from the charge.
    public static let canopied = Layout(
        name: "Full-scale wall with a canopy, charge 4 m in front", chargeToWall: 4, heightOfBurst: 1,
        wallHeight: 2, wallThickness: 0.4, canopyReach: 0.4, canopyDepth: 0.4, chargeToColumns: [16.4],
        gaugeHeights: [1.5, 4.5, 7.5, 10.5], margin: 2, width: 16, ceiling: 2.5)

    /// A measured set of column peaks, gauges from the lowest up; nil where a gauge failed.
    public struct Measured: Sendable {
        public var anfo: Float
        public var chargeToColumn: Float
        public var values: [Float?]
    }

    /// Peak reflected pressure on the columns with no wall, kPa (Tables 4.3–4.5 and 4.9–4.11).
    public static let halfScaleNoWall: [Measured] = [
        Measured(anfo: 2.44, chargeToColumn: 8.2, values: [35.10, 30.34, 27.72, 37.03]),
        Measured(anfo: 6.46, chargeToColumn: 8.2, values: [69.02, 67.85, 63.85, 69.64]),
        Measured(anfo: 14, chargeToColumn: 8.2, values: [148.86, 131.21, 120.04, 124.11]),
        Measured(anfo: 2.44, chargeToColumn: 11.85, values: [28.68, 30.75, 16.82, 26.34]),
        Measured(anfo: 6.46, chargeToColumn: 11.85, values: [49.64, 53.92, 36.48, 46.40]),
        Measured(anfo: 14, chargeToColumn: 11.85, values: [82.19, 83.43, 65.92, 89.64]),
    ]

    /// The plane wall's factor on the columns' peaks, behind it over without it (Tables 5.8–5.10).
    public static let halfScaleFactors: [Measured] = [
        Measured(anfo: 6.46, chargeToColumn: 4.2, values: [nil, 0.48, 0.57, nil]),
        Measured(anfo: 10.05, chargeToColumn: 4.2, values: [nil, 0.43, 0.80, nil]),
        Measured(anfo: 6.46, chargeToColumn: 8.2, values: [nil, 0.61, 0.67, 0.81]),
        Measured(anfo: 10.05, chargeToColumn: 8.2, values: [nil, 0.59, 0.66, 0.80]),
        Measured(anfo: 6.46, chargeToColumn: 11.85, values: [0.83, 0.66, 0.77, 0.88]),
        Measured(anfo: 10.05, chargeToColumn: 11.85, values: [0.89, 0.67, 0.77, 0.68]),
    ]

    /// Peak reflected pressure on the columns with no wall, chapter 6, kPa (Tables 6.3–6.6).
    public static let streetNoWall: [Measured] = [
        Measured(anfo: 7.248, chargeToColumn: 9.2, values: [76.6, 71.4, 71.0, 73.2]),
        Measured(anfo: 15.05, chargeToColumn: 9.2, values: [140.8, 130.8, 125.4, 130.8]),
        Measured(anfo: 7.248, chargeToColumn: 12.85, values: [53.2, 51.2, 42.8, 58.0]),
        Measured(anfo: 15.05, chargeToColumn: 12.85, values: [82.3, 78.0, 72.6, 89.2]),
    ]

    /// Chapter 6's plane wall with the street level: its factor on the lowest gauge's peak, one
    /// less the reductions in the legends of Figures 6.10–6.13.
    public static let streetFactors: [Measured] = [
        Measured(anfo: 7.248, chargeToColumn: 9.2, values: [0.50, nil, nil, nil]),
        Measured(anfo: 15.05, chargeToColumn: 9.2, values: [0.48, nil, nil, nil]),
        Measured(anfo: 7.248, chargeToColumn: 12.85, values: [0.73, nil, nil, nil]),
        Measured(anfo: 15.05, chargeToColumn: 12.85, values: [0.87, nil, nil, nil]),
    ]

    /// The full-scale column's peaks with no wall (Table 7.4) and behind the foam-faced canopied
    /// walls (read off Figure 7.33, to about 2 kPa), 125 kg at 16.4 m, kPa.
    public static let canopiedNoWall = Measured(
        anfo: 125, chargeToColumn: 16.4, values: [232.6, 149.6, 141.2, 158.6])
    public static let canopiedBehind: [(wall: String, values: [Float])] = [
        ("T-RC-W2", [142, 124, 112, 108]),
        ("T-RC-W3", [127, 116, 102, 99]),
        ("T-RC-W4", [169, 125, 126, 120]),
    ]

    /// One gauge's reading: its peak overpressure and positive impulse, and the arrival of the
    /// wave, and the peak a face square to the wave there would see.
    public struct Reading: Sendable {
        public var column: Int
        public var height: Float
        /// Pa, and Pa s.
        public var peak: Float
        public var impulse: Float
        /// On a face: the peak recorded beside the column's face. In the open: the peak's normal
        /// reflection, by the Rankine–Hugoniot relations for air (γ = 1.4).
        public var reflected: Float
        public var arrival: Double

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            column: Int,
            height: Float,
            peak: Float,
            impulse: Float,
            reflected: Float,
            arrival: Double
        ) {
            self.column = column
            self.height = height
            self.peak = peak
            self.impulse = impulse
            self.reflected = reflected
            self.arrival = arrival
        }
    }

    public struct AirResult: Sendable {
        public var layout: Layout
        public var anfo: Float
        public var wall: Bool
        public var columns: Bool
        public var cellSize: Float
        /// Column by column, gauges from the lowest up.
        public var readings: [[Reading]]
        public var histories: [[GaugeSample]]
        public var wallSeconds: Double

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            layout: Layout,
            anfo: Float,
            wall: Bool,
            columns: Bool,
            cellSize: Float,
            readings: [[Reading]],
            histories: [[GaugeSample]],
            wallSeconds: Double
        ) {
            self.layout = layout
            self.anfo = anfo
            self.wall = wall
            self.columns = columns
            self.cellSize = cellSize
            self.readings = readings
            self.histories = histories
            self.wallSeconds = wallSeconds
        }
    }

    /// The peak overpressure on a rigid face square to a plane shock of overpressure `incident`
    /// in air at `ambient` (γ = 1.4): 2p (7p₀ + 4p) / (7p₀ + p).
    public static func normalReflection(_ incident: Float, ambient: Float = 101_325) -> Float {
        2 * incident * (7 * ambient + 4 * incident) / (7 * ambient + incident)
    }

    /// The columns' places across the line from the charge: staggered, as the thesis's were, so
    /// that none stands in another's shadow.
    static func columnOffset(_ index: Int) -> Float { [0, 1, -1][index % 3] }

    /// The scene: the charge of `anfo` kg of ANFO at the layout's place, the wall rigid (if
    /// `wall`) across the whole domain or `wallLength` of it, and, if `columnWidth` is given,
    /// square rigid columns that wide with the gauges beside their front faces; otherwise the
    /// gauges are in the open where the columns' faces would be.
    public static func scenario(
        _ layout: Layout, anfo: Float, wall: Bool, columnWidth: Float?, wallLength: Float?, cellSize: Float
    ) -> Scenario {
        let charge = SIMD3(layout.margin, layout.width / 2, layout.heightOfBurst)
        let last = layout.chargeToColumns.max() ?? 0
        let size = SIMD3(
            2 * layout.margin + last + (columnWidth ?? 0), layout.width,
            max(layout.gaugeHeights.max() ?? 0, layout.top) + layout.ceiling)
        var boxes: [Box] = []
        if wall {
            let length = wallLength ?? layout.width
            let y0 = (layout.width - length) / 2
            let front = charge.x + layout.chargeToWall
            boxes.append(
                Box(
                    min: SIMD3(front, y0, 0),
                    max: SIMD3(front + layout.wallThickness, y0 + length, layout.wallHeight)))
            if layout.canopyDepth > 0 {
                boxes.append(
                    Box(
                        min: SIMD3(front - layout.canopyReach, y0, layout.wallHeight),
                        max: SIMD3(front + layout.wallThickness + layout.canopyReach, y0 + length, layout.top)
                    ))
            }
        }
        var gauges: [Gauge] = []
        for (c, distance) in layout.chargeToColumns.enumerated() {
            let y = charge.y + columnOffset(c)
            let face = charge.x + distance
            if let columnWidth {
                boxes.append(
                    Box(
                        min: SIMD3(face, y - columnWidth / 2, 0),
                        max: SIMD3(face + columnWidth, y + columnWidth / 2, size.z)))
            }
            for (g, height) in layout.gaugeHeights.enumerated() {
                let x = columnWidth == nil ? face : face - 0.5 * cellSize
                gauges.append(
                    Gauge(
                        String(format: "B%d P%d, %.2f m at %.2f m", c + 1, g + 1, distance, height),
                        at: SIMD3(x, y, height)))
            }
        }
        return Scenario(
            name: layout.name, domainSize: size, boxes: boxes,
            charge: Charge(mass: anfo * tntFactor, position: charge), gauges: gauges)
    }

    // MARK: - The walls' own response

    /// The walls whose response was observed.
    public enum Wall: String, CaseIterable, Sendable {
        /// Chapter 5's half-scale plane wall PWS, 2 m long, 1 m high and 0.2 m thick, 10 mm bars at
        /// 200 mm in both faces, on a footing in backfill.
        case halfScale
        /// Chapter 7's full-scale wall with a canopy, 4 m long, its stem 2 m high and 0.4 m thick,
        /// 20 mm bars at 200 mm in both faces, on a footing 2.2 m wide and 0.6 m deep in backfill.
        case canopied
        /// Chapter 8's double-leaf blockwork, 4 m long, 2 m high and 0.4 m thick, a 20 mm bar in
        /// every cell; its base is not described.
        case masonry

        public var layout: Layout {
            switch self {
            case .halfScale: PerimeterWallTests.halfScale
            case .canopied, .masonry:
                {
                    var layout = PerimeterWallTests.canopied
                    if self == .masonry {
                        layout.name = "Full-scale blockwork, charge 4 m in front"
                        layout.canopyReach = 0
                        layout.canopyDepth = 0
                    }
                    return layout
                }()
            }
        }

        /// Along the wall, in metres; the wing walls carry on beyond.
        public var length: Float { self == .halfScale ? 2 : 4 }
    }

    /// How the wall's base is held.
    public enum Base: String, CaseIterable, Sendable {
        /// Cast on starter bars (as many as the wall's vertical bars, at their yield) onto a footing
        /// set flush into the ground, a medium dense sand bearing on its base and sides: the
        /// thesis's construction for the concrete walls.
        case footing
        /// Clamped.
        case clamped
        /// Cast on the same starter bars onto ground that does not move.
        case dowelled
        /// A mortar bed or construction joint without bars, on ground that does not move.
        case joint
    }

    /// Grade 60 bars: 420 MPa yield, 620 MPa ultimate (ASTM A615's minima).
    public static let grade60 = SteelProperties(
        yieldStress: 420e6, ultimateStress: 620e6, ultimateStrain: 0.08, ruptureStrain: 0.12)

    /// The thesis's 40 MPa concrete with Grade 60 bars, strengthening with strain rate.
    public static let concrete: StructureMaterial = {
        var material = StructureMaterial.concrete(
            name: "40 MPa reinforced concrete", compressiveStrength: 40e6, steel: grade60)
        material.rateDependent = true
        return material
    }()

    /// Hollow concrete blockwork as the model's own (`StructureMaterial.concreteBlock`), laid in
    /// the thesis's 400 × 200 mm units, with Grade 60 bars where `bars`.
    public static func blockwork(bars: Bool) -> StructureMaterial {
        var material = StructureMaterial.concreteBlock
        material.name = bars ? "Reinforced blockwork" : "Blockwork"
        material.units?.length = 0.4
        material.units?.courseHeight = 0.2
        material.steel = bars ? grade60 : nil
        return material
    }

    /// What a strip of blockwork did (`blockworkPanel`): how far its top's and its mid-height's
    /// back face went away from the load, the fastest node, the share of elements removed, and
    /// the largest compaction (V0 / V - 1) any element was squeezed to while confined.
    public struct PanelResult: Sendable {
        public var peakTop: Float = 0
        public var finalTop: Float = 0
        public var peakMiddle: Float = 0
        public var fastest: Float = 0
        public var erodedFraction: Double = 0
        public var compaction: Float = 0

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            peakTop: Float = 0,
            finalTop: Float = 0,
            peakMiddle: Float = 0,
            fastest: Float = 0,
            erodedFraction: Double = 0,
            compaction: Float = 0
        ) {
            self.peakTop = peakTop
            self.finalTop = finalTop
            self.peakMiddle = peakMiddle
            self.fastest = fastest
            self.erodedFraction = erodedFraction
            self.compaction = compaction
        }
    }

    /// What the wall did, at the middle of its length.
    public struct WallResult: Sendable {
        public var wall: Wall
        public var base: Base
        public var anfo: Float
        /// Displacement away from the charge of the back face's top and of its middle height (the
        /// stem's, for the canopied wall): the largest, and where each is at the end.
        public var peakTop: Float = 0
        public var finalTop: Float = 0
        public var peakMiddle: Float = 0
        public var finalMiddle: Float = 0
        /// The face's peak overpressure and positive impulse at mid-height (Pa, Pa s), and the back
        /// face's impulse over 50 ms from the wave's arrival at the face, both phases, positive
        /// pushing towards the charge.
        public var facePeak: Float = 0
        public var faceImpulse: Float = 0
        public var backImpulse: Float = 0
        /// Crack openings (m) across each element row up the front and back faces, the widest
        /// along the wall's length and the fraction of its length open past `crackWidth`, and the
        /// fraction open past it on a horizontal plane (a crack running along the wall).
        public var frontWidest: [Float] = []
        public var frontSpread: [Float] = []
        public var frontHorizontal: [Float] = []
        public var backWidest: [Float] = []
        public var backSpread: [Float] = []
        public var backHorizontal: [Float] = []
        public var crackWidth: Float = 0
        /// The element size, and the base's largest opening and the share of its ties broken.
        public var elementSize: Float = 0
        public var baseOpening: Float = 0
        public var baseSeparated: Float = 0
        /// On a footing: its largest rotation (radians, away from the charge) and where it ends.
        public var footingRotation: Float = 0
        public var footingSlide: Float = 0
        /// The share of elements removed, and the fastest node at the end (m/s): pieces thrown.
        public var erodedFraction: Double = 0
        public var fastest: Float = 0
        public var summary = StructureSummary()
        public var wallSeconds: Double = 0

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            wall: Wall,
            base: Base,
            anfo: Float,
            peakTop: Float = 0,
            finalTop: Float = 0,
            peakMiddle: Float = 0,
            finalMiddle: Float = 0,
            facePeak: Float = 0,
            faceImpulse: Float = 0,
            backImpulse: Float = 0,
            frontWidest: [Float] = [],
            frontSpread: [Float] = [],
            frontHorizontal: [Float] = [],
            backWidest: [Float] = [],
            backSpread: [Float] = [],
            backHorizontal: [Float] = [],
            crackWidth: Float = 0,
            elementSize: Float = 0,
            baseOpening: Float = 0,
            baseSeparated: Float = 0,
            footingRotation: Float = 0,
            footingSlide: Float = 0,
            erodedFraction: Double = 0,
            fastest: Float = 0,
            summary: StructureSummary = StructureSummary(),
            wallSeconds: Double = 0
        ) {
            self.wall = wall
            self.base = base
            self.anfo = anfo
            self.peakTop = peakTop
            self.finalTop = finalTop
            self.peakMiddle = peakMiddle
            self.finalMiddle = finalMiddle
            self.facePeak = facePeak
            self.faceImpulse = faceImpulse
            self.backImpulse = backImpulse
            self.frontWidest = frontWidest
            self.frontSpread = frontSpread
            self.frontHorizontal = frontHorizontal
            self.backWidest = backWidest
            self.backSpread = backSpread
            self.backHorizontal = backHorizontal
            self.crackWidth = crackWidth
            self.elementSize = elementSize
            self.baseOpening = baseOpening
            self.baseSeparated = baseSeparated
            self.footingRotation = footingRotation
            self.footingSlide = footingSlide
            self.erodedFraction = erodedFraction
            self.fastest = fastest
            self.summary = summary
            self.wallSeconds = wallSeconds
        }
    }
}
