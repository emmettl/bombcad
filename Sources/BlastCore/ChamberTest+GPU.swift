import BlastModel
import Foundation
import Metal
import simd

extension ChamberTest {
    public static func run(
        device: MTLDevice, cellSize: Float = 0.1, elementSize: Float = 0.1, downstand: Bool = true,
        ties: Bool = true, elastic: Bool = false, chargeScale: Float = 1,
        afterburning: Bool = SolverConfiguration.recommended.afterburning,
        afterburnEnergy: Float? = nil, airModel: AirModel = SolverConfiguration.recommended.airModel,
        openFaces: OpenFaces = SolverConfiguration.recommended.openFaces,
        duration: Double = 0.3, refinement: Int = 1, roomy: Bool = true,
        mappedCharge: Bool = SolverConfiguration.recommended.mappedCharge,
        radiativeCooling: RadiativeCooling? = SolverConfiguration.recommended.radiativeCooling
    ) throws -> Result {
        // `roomy`: the open faces (across and the top) moved out to `Scenario.structureFaceClearance`,
        // as compared since 18 October 2026; in the box of 1 m either side and 2 m above, the
        // roof's edge rose 50 mm and was left 28 mm up against 46-47 and 24-25 (docs/validation.md,
        // "Open faces at the clearance rule").
        let pad =
            roomy ? scenario(elementSize: elementSize).openFaceRoom(step: 0.5) : (low: .zero, high: .zero)
        return try run(
            device: device,
            scenario: scenario(
                elementSize: elementSize, downstand: downstand, ties: ties, elastic: elastic,
                chargeScale: chargeScale, pad: pad),
            cellSize: cellSize, duration: duration, afterburning: afterburning,
            afterburnEnergy: afterburnEnergy, airModel: airModel, openFaces: openFaces,
            refinement: refinement,
            mappedCharge: mappedCharge, radiativeCooling: radiativeCooling)
    }

    /// The chamber with its vent closed and no charge, filled with air at `overpressure` (Pa)
    /// from the start: a step load on the walls and roof that lasts, from which the pressure the
    /// roof can resist is found as the largest that does not throw it.
    public static func pressureTest(
        device: MTLDevice, overpressure: Float, cellSize: Float = 0.1, elementSize: Float = 0.1,
        duration: Double = 0.3
    ) throws -> Result {
        var scenario = scenario(elementSize: elementSize, chargeScale: 0)
        scenario.boxes.append(
            Box(min: SIMD3(roofEdge, inside.low, roof.low), max: SIMD3(mirror, inside.high, roof.high)))
        return try run(
            device: device, scenario: scenario, cellSize: cellSize, duration: duration,
            interiorOverpressure: overpressure)
    }

    /// Runs a variant of the test's scenario, with the air inside the chamber raised by
    /// `interiorOverpressure` (Pa) at the start.
    public static func run(
        device: MTLDevice, scenario: Scenario, cellSize: Float, duration: Double,
        interiorOverpressure: Float = 0, afterburning: Bool = SolverConfiguration.recommended.afterburning,
        afterburnEnergy: Float? = nil,
        airModel: AirModel = SolverConfiguration.recommended.airModel,
        openFaces: OpenFaces = SolverConfiguration.recommended.openFaces, refinement: Int = 1,
        contact: ContactMode? = nil, mappedCharge: Bool = SolverConfiguration.recommended.mappedCharge,
        radiativeCooling: RadiativeCooling? = SolverConfiguration.recommended.radiativeCooling,
        progress: ((String) -> Void)? = nil, prepare: ((StructureSolver) -> Void)? = nil
    ) throws -> Result {
        // The scene as `scenario(pad:)` moved it across.
        let dy = scenario.charge.position.y - chargePositions[0].y
        let sideWalls = (low: Self.sideWalls.low + dy, high: Self.sideWalls.high + dy)
        let inside = (low: Self.inside.low + dy, high: Self.inside.high + dy)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        let defaults = SolverConfiguration()
        if afterburning != defaults.afterburning || airModel != defaults.airModel
            || openFaces != defaults.openFaces || refinement > 1 || afterburnEnergy != nil || mappedCharge
            || radiativeCooling != nil
        {
            solver.configuration.afterburning = afterburning
            // Each charge from its own mapped one-dimensional start, as runs start since 18 October
            // 2026 (0.36 m out here, the sleeves' walls 0.45 m off).
            solver.configuration.mappedCharge = mappedCharge
            // The gas losing what it radiates, as runs do since 19 October 2026.
            solver.configuration.radiativeCooling = afterburning ? radiativeCooling : nil
            solver.configuration.openFaces = openFaces
            solver.configuration.airModel = airModel
            solver.configuration.refinement = refinement
            if let afterburnEnergy { solver.configuration.afterburnEnergy = afterburnEnergy }
            try solver.load(scenario)
        }
        if interiorOverpressure != 0 {
            let grid = solver.grid
            let room = Box(
                min: SIMD3(endWallFace, inside.low, floorTop), max: SIMD3(mirror, inside.high, roof.high))
            let pressure = scenario.atmosphere.pressure + interiorOverpressure
            solver.mutateState { cells in
                for k in 0..<grid.nz {
                    for j in 0..<grid.ny {
                        for i in 0..<grid.nx where !solver.isSolid(i, j, k) {
                            let centre = (SIMD3(Float(i), Float(j), Float(k)) + 0.5) * grid.cellSize
                            guard room.contains(centre) else { continue }
                            cells[grid.index(i, j, k)] = solver.cellState(
                                Primitive(density: scenario.atmosphere.density, pressure: pressure))
                        }
                    }
                }
            }
            solver.restart()
        }
        guard let structure = solver.structure else { throw BlastError.allocationFailed("structure") }
        if let contact { structure.contactMode = contact }
        // For benchmarks: a hook before the run, such as a shorter step.
        prepare?(structure)
        let h = structure.model.elementSize
        let edge = SIMD3<Float>(roofEdge, 5 + dy, roof.high)
        let start = ContinuousClock.now
        var history: [SIMD2<Float>] = []
        // The top node of the roof at the edge, at mid-span.
        let i = Int(((edge.x - structure.origin.x) / h).rounded())
        let j = Int(((edge.y - structure.origin.y) / h).rounded())
        let k = (0...structure.ez).last { structure.storedNode(i, j, $0) != nil } ?? 0
        func lattice(_ point: SIMD3<Float>) -> (Int, Int, Int) {
            let index = ((point - structure.origin) / h).rounded(.toNearestOrAwayFromZero)
            return (Int(index.x), Int(index.y), Int(index.z))
        }
        let probePoints: [(String, (Int, Int, Int), SIMD3<Float>)] = [
            ("Side wall W1, middle", lattice(SIMD3(endWallFace + 2.5, sideWalls.low, 3.5)), SIMD3(0, -1, 0)),
            (
                "Roof, middle", lattice(SIMD3((endWallFace + roofEdge) / 2, 5 + dy, roof.high - 0.5 * h)),
                SIMD3(0, 0, 1)
            ),
        ]
        var probes = probePoints.map { ($0.0, [SIMD2<Float>]()) }
        // From the chamber at rest under its own weight, as the test's deflections were measured.
        solver.settleStructures()
        let rest = structure.displacement(i, j, k).z
        let restProbes = probePoints.map { probe in
            dot(structure.displacement(probe.1.0, probe.1.1, probe.1.2), probe.2)
        }
        var nextReport = 0.01
        while solver.time < duration {
            let result = solver.advance(steps: 16, timeLimit: duration)
            if result.steps == 0 && !solver.airIsAsleep { break }
            history.append(SIMD2(Float(solver.time), structure.displacement(i, j, k).z - rest))
            if let progress, solver.time >= nextReport {
                nextReport += 0.01
                let summary = structure.summary()
                let seconds = (ContinuousClock.now - start).components.seconds
                progress(
                    String(
                        format: "%3.0f ms: roof edge %4.0f mm, %d elements failed, %d s", solver.time * 1000,
                        (structure.displacement(i, j, k).z - rest) * 1000, summary.erodedElements, seconds))
            }
            for (n, probe) in probePoints.enumerated() {
                let (a, b, c) = probe.1
                probes[n].1.append(
                    SIMD2(Float(solver.time), dot(structure.displacement(a, b, c), probe.2) - restProbes[n]))
            }
        }
        let elapsed = ContinuousClock.now - start
        let parts: [(String, (SIMD3<Float>) -> Bool)] = [
            ("End wall", { $0.x < endWallFace }),
            ("Side walls, below 4 m", { $0.z < 4 && ($0.y < inside.low || $0.y > inside.high) }),
            (
                "Side walls, above 4 m",
                { $0.z >= 4 && $0.z < roof.low && ($0.y < inside.low || $0.y > inside.high) }
            ),
            ("Roof slab, within 0.5 m of the end wall", { $0.z >= roof.low && $0.x < endWallFace + 0.5 }),
            (
                "Roof slab, over the side walls",
                { $0.z >= roof.low && ($0.y < inside.low || $0.y > inside.high) }
            ),
            ("Roof slab, elsewhere", { $0.z >= roof.low }),
            (
                "Down-stand",
                {
                    $0.z < roof.low && $0.x > roofEdge - 0.8 && $0.y > inside.low + 0.5
                        && $0.y < inside.high - 0.5
                }
            ),
            ("Chamfers", { $0.z < roof.low && $0.y > inside.low && $0.y < inside.high }),
        ]
        var failures = parts.map { ($0.0, 0, 0) }
        for k in 0..<structure.ez {
            for j in 0..<structure.ey {
                for i in 0..<structure.ex {
                    let flag = structure.flag(i, j, k)
                    guard flag != .empty else { continue }
                    let centre = structure.referencePosition(i, j, k) + 0.5 * h
                    guard let part = parts.firstIndex(where: { $0.1(centre) }) else { continue }
                    failures[part].2 += 1
                    if flag == .eroded { failures[part].1 += 1 }
                }
            }
        }
        let ambient = scenario.atmosphere.pressure
        let peaks = zip(scenario.gauges, solver.gaugeHistories).map { gauge, samples in
            (gauge.name, (samples.map(\.pressure).max() ?? ambient) - ambient)
        }
        return Result(
            gaugePeaks: peaks, gaugeHistories: solver.gaugeHistories, edgeHistory: history,
            probes: probes.map { (name: $0.0, history: $0.1) },
            summary: structure.summary(), failures: failures,
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }
}
