import Foundation
import Metal
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

    /// Runs the air alone: `anfo` kg of ANFO in the layout, with the wall rigid or without it, on
    /// cells of `cellSize` (refined by `refinement` where the shock is), until the wave has
    /// passed the last column.
    public static func runAir(
        device: MTLDevice, layout: Layout, anfo: Float, wall: Bool, cellSize: Float = 0.05,
        refinement: Int = 1,
        columnWidth: Float? = nil, wallLength: Float? = nil, duration: Double? = nil,
        progress: ((String) -> Void)? = nil
    ) throws -> AirResult {
        let started = ContinuousClock.now
        let scenario = scenario(
            layout, anfo: anfo, wall: wall, columnWidth: columnWidth, wallLength: wallLength,
            cellSize: cellSize)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        solver.configuration.mappedCharge = true
        solver.configuration.refinement = refinement
        try solver.load(scenario)
        // The wave runs faster than sound, so by sound's time to the last column and 20 ms more
        // its positive phase has passed every gauge.
        let last = Double(layout.chargeToColumns.max() ?? 0)
        let end = duration ?? last / Double(scenario.atmosphere.soundSpeed()) + 0.02
        var nextReport = 0.005
        while solver.time < end {
            let batch = solver.advance(steps: 16, timeLimit: end)
            if batch.steps == 0 && !solver.airIsAsleep { break }
            if let progress, solver.time >= nextReport {
                nextReport += 0.005
                progress(String(format: "%4.1f ms", solver.time * 1000))
            }
        }
        let ambient = scenario.atmosphere.pressure
        var readings: [[Reading]] = []
        for c in layout.chargeToColumns.indices {
            var column: [Reading] = []
            for (g, height) in layout.gaugeHeights.enumerated() {
                let samples = solver.gaugeHistories[c * layout.gaugeHeights.count + g]
                let peak = (samples.map(\.pressure).max() ?? ambient) - ambient
                var impulse: Float = 0
                for (a, b) in zip(samples, samples.dropFirst()) {
                    impulse += Float(b.time - a.time) * max(0.5 * (a.pressure + b.pressure) - ambient, 0)
                }
                let arrival = samples.first { $0.pressure > ambient + 0.05 * peak }?.time ?? 0
                column.append(
                    Reading(
                        column: c, height: height, peak: peak, impulse: impulse,
                        reflected: columnWidth == nil ? normalReflection(peak, ambient: ambient) : peak,
                        arrival: arrival))
            }
            readings.append(column)
        }
        let elapsed = ContinuousClock.now - started
        return AirResult(
            layout: layout, anfo: anfo, wall: wall, columns: columnWidth != nil, cellSize: cellSize,
            readings: readings, histories: solver.gaugeHistories,
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }
}
