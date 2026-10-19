import BlastModel
import Foundation
import Metal
import simd

extension PerimeterWallTests {
    /// Runs the air alone: `anfo` kg of ANFO in the layout, with the wall rigid or without it, on
    /// cells of `cellSize` (refined by `refinement` where the shock is), until the wave has
    /// passed the last column.
    public static func runAir(
        device: MTLDevice, layout: Layout, anfo: Float, wall: Bool, cellSize: Float = 0.05,
        refinement: Int = 1,
        columnWidth: Float? = nil, wallLength: Float? = nil, duration: Double? = nil,
        afterburning: Bool = SolverConfiguration.recommended.afterburning,
        airModel: AirModel? = nil, openFaces: OpenFaces = SolverConfiguration.recommended.openFaces,
        balloonStart: Bool = false, progress: ((String) -> Void)? = nil
    ) throws -> AirResult {
        let started = ContinuousClock.now
        let scenario = scenario(
            layout, anfo: anfo, wall: wall, columnWidth: columnWidth, wallLength: wallLength,
            cellSize: cellSize)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        // The mapped one-dimensional start since 18 October 2026; `balloonStart` keeps the hot-gas
        // balloon these comparisons were recorded on before then (with afterburning; the ideal gas
        // was mapped already).
        solver.configuration.mappedCharge =
            balloonStart ? !afterburning : SolverConfiguration.recommended.mappedCharge
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

    /// Runs `wall` on `base` under `anfo` kg of ANFO at its layout's place, loaded by the air on
    /// cells of `cellSize`, meshed with elements of `elementSize`, for `duration` seconds. The wing
    /// walls either side are rigid, `gap` clear of its ends. For the blockwork, `bars` puts the
    /// thesis's bars in it as though bonded (its cells were filled with foam, though the text also
    /// calls them grouted), and `joints` meshes it as units and mortar joints rather than as one
    /// material. On a footing, `footing` gives its width across the wall and its depth
    /// instead of the thesis's (the canopied wall's) or half of them (the half-scale wall's). The
    /// air reaches `clearance` times the wall's height behind it and above it (at least 3 m);
    /// with `roomy`, every open face is moved out to `Scenario.structureFaceClearance`, the wing
    /// walls carried on to the faces.
    public static func runWall(
        device: MTLDevice, wall: Wall, base: Base, anfo: Float, cellSize: Float = 0.05,
        elementSize: Float = 0.05, duration: Double = 0.2, gap: Float = 0.05, bars: Bool = true,
        joints: Bool = true,
        crackWidth: Float = 0.1e-3, footing: SIMD2<Float>? = nil, clearance: Float = 3,
        afterburning: Bool = SolverConfiguration.recommended.afterburning,
        airModel: AirModel? = nil, openFaces: OpenFaces = SolverConfiguration.recommended.openFaces,
        roomy: Bool = false, balloonStart: Bool = false, progress: ((String) -> Void)? = nil
    ) throws -> WallResult {
        let started = ContinuousClock.now
        let layout = wall.layout
        let t = layout.wallThickness
        let height = layout.wallHeight
        let behind = max(clearance * layout.top, 3)
        var size = SIMD3(
            2 * layout.margin + layout.chargeToWall + t + behind, layout.width,
            max(clearance * layout.top, layout.top + 3))
        var charge = SIMD3(layout.margin, layout.width / 2, layout.heightOfBurst)
        var y0 = (layout.width - wall.length) / 2
        if roomy {
            // The faces' room from the stem alone (`Scenario.openFaceRoom`), then the scene moved by it.
            let front = charge.x + layout.chargeToWall
            let stem = Box(min: SIMD3(front, y0, 0), max: SIMD3(front + t, y0 + wall.length, layout.top))
            let pad = Scenario(
                name: layout.name, domainSize: size, boxes: [],
                charge: Charge(mass: anfo * tntFactor, position: charge), gauges: [],
                structure: StructureModel(solids: [stem], material: concrete, elementSize: elementSize)
            ).openFaceRoom(step: 0.5)
            size += pad.low + pad.high
            charge += pad.low
            y0 += pad.low.y
        }
        let front = charge.x + layout.chargeToWall
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
        for (a, b) in [(Float(0), y0 - gap), (y1 + gap, size.y)] where b > a {
            boxes.append(Box(min: SIMD3(front, a, 0), max: SIMD3(front + t, b, height)))
            if layout.canopyDepth > 0 {
                boxes.append(
                    Box(
                        min: SIMD3(front - layout.canopyReach, a, height),
                        max: SIMD3(front + t + layout.canopyReach, b, layout.top)))
            }
        }
        let middle = charge.y
        let scenario = Scenario(
            name: layout.name, domainSize: size, boxes: boxes,
            charge: Charge(mass: anfo * tntFactor, position: charge),
            gauges: [
                Gauge("Face, mid-height", at: SIMD3(front - 0.5 * cellSize, middle, height / 2)),
                Gauge("Back, mid-height", at: SIMD3(front + t + 0.5 * cellSize, middle, height / 2)),
            ],
            structure: model)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        // The mapped one-dimensional start since 18 October 2026; `balloonStart` keeps the hot-gas
        // balloon these comparisons were recorded on before then (with afterburning; the ideal gas
        // was mapped already).
        solver.configuration.mappedCharge =
            balloonStart ? !afterburning : SolverConfiguration.recommended.mappedCharge
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
