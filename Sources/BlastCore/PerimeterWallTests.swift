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
        afterburning: Bool = SolverConfiguration.recommended.afterburning,
        airModel: AirModel? = nil, openFaces: OpenFaces = SolverConfiguration.recommended.openFaces,
        progress: ((String) -> Void)? = nil
    ) throws -> AirResult {
        let started = ContinuousClock.now
        let scenario = scenario(
            layout, anfo: anfo, wall: wall, columnWidth: columnWidth, wallLength: wallLength,
            cellSize: cellSize)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        solver.configuration.mappedCharge = !afterburning
        solver.configuration.afterburning = afterburning
        solver.configuration.openFaces = openFaces
        // As the app's "Afterburning and hot air": both or neither.
        solver.configuration.airModel = airModel ?? (afterburning ? .thermallyPerfect : .idealGas)
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
    }

    /// A strip of the blockwork wall alone, `length` long (on the dowelled base with its bars, on
    /// a construction joint without), its front face pushed by a pressure rising at once to
    /// `peak` Pa and falling to zero over `duration` seconds, with no air, for `time` seconds.
    /// The defaults are near what the 25 kg charge put on the wall's face. With `heldEnds` its
    /// ends cannot move along the wall, as in the middle of a long wall. With `bars` and `joints`
    /// this is the arrangement that once ran away under that charge.
    public static func blockworkPanel(
        device: MTLDevice, length: Float = 0.2, heldEnds: Bool = true, bars: Bool = true, joints: Bool = true,
        peak: Float = 2.5e6, duration: Float = 1.3e-3, time: Float = 0.03, elementSize: Float = 0.05,
        progress: ((String) -> Void)? = nil
    ) throws -> PanelResult {
        let t: Float = 0.4
        let height: Float = 2
        let stem = Box(min: SIMD3(0, 0, 0), max: SIMD3(t, length, height))
        var model = StructureModel(solids: [stem], material: blockwork(bars: bars), elementSize: elementSize)
        model.unitJoints = joints
        let area: Float = 314e-6 / 0.2
        if bars {
            model.addMat(
                to: stem, thicknessAxis: 0, areaPerMetre: area, transverseAreaPerMetre: 113e-6 / 0.2,
                longitudinalAxis: 2, depth: 0.1)
            model.baseAnchorage = Anchorage.dowelled(ratio: 2 * area / t, yieldStrength: grade60.yieldStress)
        } else {
            model.baseAnchorage = .constructionJoint
        }
        let solver = try StructureSolver(device: device, model: model)
        solver.appliedLoad = PressureLoad(
            axis: 0, positiveSide: false, history: [SIMD2(0, peak), SIMD2(duration, 0), SIMD2(1e3, 0)])
        let h = model.elementSize
        let iBack = Int((t / h).rounded())
        let jEnd = Int((length / h).rounded())
        let jMiddle = jEnd / 2
        let kTop = Int((height / h).rounded())
        if heldEnds {
            solver.mutateNodes { nodes in
                for k in 0...kTop {
                    for j in [0, jEnd] {
                        for i in 0...iBack {
                            if let n = solver.storedNode(i, j, k) { nodes[n].restrain(y: true) }
                        }
                    }
                }
            }
        }
        var result = PanelResult()
        let steps = max(Int((Float(0.5e-3) / solver.criticalTimeStep).rounded()), 1)
        var elapsed: Float = 0
        while elapsed < time {
            solver.advance(steps: steps)
            elapsed += Float(steps) * solver.criticalTimeStep
            let top = solver.displacement(iBack, jMiddle, kTop).x
            let middle = solver.displacement(iBack, jMiddle, kTop / 2).x
            result.peakTop = max(result.peakTop, top)
            result.peakMiddle = max(result.peakMiddle, middle)
            var fastest: Float = 0
            solver.mutateNodes { nodes in
                for node in nodes where node.mass > 0 {
                    fastest = max(fastest, simd_length(SIMD3(node.vx, node.vy, node.vz)))
                }
            }
            result.fastest = max(result.fastest, fastest)
            progress?(
                String(
                    format: "%5.1f ms: top %7.1f mm, middle %7.1f mm, fastest %9.2f m/s, removed %.1f%%",
                    elapsed * 1000, top * 1000, middle * 1000, fastest, solver.summary().erodedFraction * 100)
            )
        }
        result.finalTop = solver.displacement(iBack, jMiddle, kTop).x
        result.erodedFraction = solver.summary().erodedFraction
        for k in 0..<solver.ez {
            for j in 0..<solver.ey {
                for i in 0..<solver.ex {
                    result.compaction = max(result.compaction, solver.compaction(i, j, k))
                }
            }
        }
        return result
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
    }

    /// Runs `wall` on `base` under `anfo` kg of ANFO at its layout's place, loaded by the air on
    /// cells of `cellSize`, meshed with elements of `elementSize`, for `duration` seconds. The wing
    /// walls either side are rigid, `gap` clear of its ends. For the blockwork, `bars` puts the
    /// thesis's bars in it as though bonded (its cells were filled with foam, though the text also
    /// calls them grouted), and `joints` meshes it as units and mortar joints rather than as one
    /// material. On a footing, `footing` gives its width across the wall and its depth
    /// instead of the thesis's (the canopied wall's) or half of them (the half-scale wall's). The
    /// air reaches `clearance` times the wall's height behind it and above it (at least 3 m).
    public static func runWall(
        device: MTLDevice, wall: Wall, base: Base, anfo: Float, cellSize: Float = 0.05,
        elementSize: Float = 0.05, duration: Double = 0.2, gap: Float = 0.05, bars: Bool = true,
        joints: Bool = true,
        crackWidth: Float = 0.1e-3, footing: SIMD2<Float>? = nil, clearance: Float = 3,
        afterburning: Bool = SolverConfiguration.recommended.afterburning,
        airModel: AirModel? = nil, openFaces: OpenFaces = SolverConfiguration.recommended.openFaces,
        progress: ((String) -> Void)? = nil
    ) throws -> WallResult {
        let started = ContinuousClock.now
        let layout = wall.layout
        let t = layout.wallThickness
        let height = layout.wallHeight
        let behind = max(clearance * layout.top, 3)
        let size = SIMD3(
            2 * layout.margin + layout.chargeToWall + t + behind, layout.width,
            max(clearance * layout.top, layout.top + 3))
        let charge = SIMD3(layout.margin, layout.width / 2, layout.heightOfBurst)
        let front = charge.x + layout.chargeToWall
        let y0 = (layout.width - wall.length) / 2
        let y1 = y0 + wall.length
        let stem = Box(min: SIMD3(front, y0, 0), max: SIMD3(front + t, y1, height))
        var solids = [stem]
        if layout.canopyDepth > 0 {
            solids.append(
                Box(
                    min: SIMD3(front - layout.canopyReach, y0, height),
                    max: SIMD3(front + t + layout.canopyReach, y1, layout.top)))
        }
        var model: StructureModel
        var verticalRatio: Float
        switch wall {
        case .halfScale:
            model = StructureModel(solids: solids, material: concrete, elementSize: elementSize)
            // 10 mm at 200 mm, 20 mm cover.
            let area: Float = 78.5e-6 / 0.2
            model.addMat(to: stem, thicknessAxis: 0, areaPerMetre: area, depth: 0.03)
            verticalRatio = 2 * area / t
        case .canopied:
            model = StructureModel(solids: solids, material: concrete, elementSize: elementSize)
            // 20 mm at 200 mm in the stem, 40 mm cover and 10 mm links; 12 mm at 200 mm in the canopy.
            let area: Float = 314e-6 / 0.2
            model.addMat(to: stem, thicknessAxis: 0, areaPerMetre: area, depth: 0.06)
            model.addMat(to: solids[1], thicknessAxis: 2, areaPerMetre: 113e-6 / 0.2, depth: 0.05)
            verticalRatio = 2 * area / t
        case .masonry:
            model = StructureModel(solids: solids, material: blockwork(bars: bars), elementSize: elementSize)
            model.unitJoints = joints
            // A 20 mm bar in each cell, the cells 200 mm apart along the middle of each leaf; 12 mm
            // in the bed joints, taken as one bar a course in each leaf.
            let area: Float = 314e-6 / 0.2
            if bars {
                model.addMat(
                    to: stem, thicknessAxis: 0, areaPerMetre: area, transverseAreaPerMetre: 113e-6 / 0.2,
                    longitudinalAxis: 2, depth: 0.1)
            }
            verticalRatio = bars ? 2 * area / t : 0
        }
        switch base {
        case .clamped: model.baseAnchorage = nil
        case .joint: model.baseAnchorage = .constructionJoint
        case .dowelled, .footing:
            var law =
                verticalRatio > 0
                ? Anchorage.dowelled(ratio: verticalRatio, yieldStrength: grade60.yieldStress)
                : .constructionJoint
            if base == .footing {
                // The footing's width across the wall (the canopied wall's 2.2 m, the half-scale's
                // taken as half that), centred under it, flush with the ground.
                let width: Float = footing?.x ?? (wall == .halfScale ? 1.1 : 2.2)
                let depth: Float = footing?.y ?? (wall == .halfScale ? 0.3 : 0.6)
                law.footing = Footing(
                    overhang: SIMD2((width - t) / 2, 0), thickness: depth, embedment: Embedment(depth: depth))
            }
            model.baseAnchorage = law
        }
        // The wing walls, rigid, either side.
        var boxes: [Box] = []
        for (a, b) in [(Float(0), y0 - gap), (y1 + gap, layout.width)] where b > a {
            boxes.append(Box(min: SIMD3(front, a, 0), max: SIMD3(front + t, b, height)))
            if layout.canopyDepth > 0 {
                boxes.append(
                    Box(
                        min: SIMD3(front - layout.canopyReach, a, height),
                        max: SIMD3(front + t + layout.canopyReach, b, layout.top)))
            }
        }
        let middle = layout.width / 2
        let scenario = Scenario(
            name: layout.name, domainSize: size, boxes: boxes,
            charge: Charge(mass: anfo * tntFactor, position: charge),
            gauges: [
                Gauge("Face, mid-height", at: SIMD3(front - 0.5 * cellSize, middle, height / 2)),
                Gauge("Back, mid-height", at: SIMD3(front + t + 0.5 * cellSize, middle, height / 2)),
            ],
            structure: model)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        solver.configuration.mappedCharge = !afterburning
        solver.configuration.afterburning = afterburning
        solver.configuration.openFaces = openFaces
        // As the app's "Afterburning and hot air": both or neither.
        solver.configuration.airModel = airModel ?? (afterburning ? .thermallyPerfect : .idealGas)
        try solver.load(scenario)
        guard let structure = solver.structure else { throw BlastError.allocationFailed("structure") }
        let h = structure.model.elementSize
        func index(_ value: Float, _ axis: Int) -> Int {
            Int(((value - structure.origin[axis]) / h).rounded())
        }
        let iBack = index(front + t, 0)
        let iFront = index(front, 0)
        let jMiddle = index(middle, 1)
        let kTop = index(height, 2)
        let kMiddle = index(height / 2, 2)
        func sway(_ k: Int) -> Float { structure.displacement(iBack, jMiddle, k).x }

        var result = WallResult(wall: wall, base: base, anfo: anfo)
        result.crackWidth = crackWidth
        result.elementSize = h
        var nextReport = 0.01
        while solver.time < duration {
            let batch = solver.advance(steps: 16, timeLimit: duration)
            if batch.steps == 0 && !solver.airIsAsleep { break }
            result.peakTop = max(result.peakTop, sway(kTop))
            result.peakMiddle = max(result.peakMiddle, sway(kMiddle))
            if let anchors = structure.anchorSummary() {
                result.baseOpening = max(result.baseOpening, anchors.maxOpening)
            }
            if let footing = structure.footingSummaries().first {
                result.footingRotation = max(result.footingRotation, footing.rotation.y)
            }
            if let progress, solver.time >= nextReport {
                nextReport += 0.01
                progress(
                    String(
                        format: "%4.0f ms: top %6.1f mm, middle %6.1f mm", solver.time * 1000,
                        sway(kTop) * 1000,
                        sway(kMiddle) * 1000))
            }
        }
        result.finalTop = sway(kTop)
        result.finalMiddle = sway(kMiddle)
        if let anchors = structure.anchorSummary() {
            result.baseSeparated = Float(anchors.separated) / Float(max(anchors.nodes, 1))
        }
        if let footing = structure.footingSummaries().first { result.footingSlide = footing.displacement.x }

        // Cracks up each face: the elements next to it, row by row.
        let jRange = index(y0, 1)..<index(y1, 1)
        for (column, faceIndex) in [(iFront, true), (iBack - 1, false)] {
            var widest: [Float] = []
            var spread: [Float] = []
            var horizontal: [Float] = []
            for k in 0..<kTop {
                let openings = jRange.map { structure.crackOpening(column, $0, k) * h }
                // Open cracks whose widest plane is horizontal, running along the wall.
                let flat = jRange.filter { j in
                    guard structure.crackOpening(column, j, k) * h > crackWidth else { return false }
                    let planes = structure.crackPlanes(column, j, k)
                    let history = planes.history
                    let n =
                        history.x >= history.y && history.x >= history.z
                        ? 0 : (history.y >= history.z ? 1 : 2)
                    return planes.normals.count == 3 && abs(planes.normals[n].z) > 0.7
                }
                let count = Float(max(openings.count, 1))
                widest.append(openings.max() ?? 0)
                spread.append(Float(openings.filter { $0 > crackWidth }.count) / count)
                horizontal.append(Float(flat.count) / count)
            }
            if faceIndex {
                result.frontWidest = widest
                result.frontSpread = spread
                result.frontHorizontal = horizontal
            } else {
                result.backWidest = widest
                result.backSpread = spread
                result.backHorizontal = horizontal
            }
        }
        var fastest: Float = 0
        structure.mutateNodes { nodes in
            for node in nodes where node.mass > 0 {
                fastest = max(fastest, simd_length(SIMD3(node.vx, node.vy, node.vz)))
            }
        }
        result.fastest = fastest
        result.summary = structure.summary()
        result.erodedFraction = result.summary.erodedFraction

        let ambient = scenario.atmosphere.pressure
        let face = solver.gaugeHistories[0]
        let back = solver.gaugeHistories[1]
        result.facePeak = (face.map(\.pressure).max() ?? ambient) - ambient
        for (a, b) in zip(face, face.dropFirst()) {
            result.faceImpulse += Float(b.time - a.time) * max(0.5 * (a.pressure + b.pressure) - ambient, 0)
        }
        let arrival = face.first { $0.pressure > ambient + 0.01 * result.facePeak }?.time ?? 0
        for (a, b) in zip(back, back.dropFirst()) where a.time >= arrival && b.time <= arrival + 0.05 {
            result.backImpulse += Float(b.time - a.time) * (0.5 * (a.pressure + b.pressure) - ambient)
        }
        let elapsed = ContinuousClock.now - started
        result.wallSeconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        return result
    }
}
