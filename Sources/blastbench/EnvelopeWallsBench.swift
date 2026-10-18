import BlastCore
import Foundation
import Metal
import simd

// `blastbench envelope-walls [--cases alsubaei-half,alsubaei-canopied,alsubaei-block25,alsubaei-block125,
//   keys-WR1A,keys-WR1B,keys-WR2C] [--time 0.25] [--out <dir>]`: freestanding walls as envelopes, judged
// one way as cantilevers from their foot (`EnvelopePanel`'s cantilever systems) on the loads the
// recorder takes on them, against what Alsubaei's and Keys's walls did. Each wall is put in its
// test's scene (PerimeterWallTests's and MasonryDebrisTests's geometry and charge) as an envelope,
// the air on the recommended settings; then judged by the app's own assessment (the envelope's
// construction) and with the wall as built (its bars, depths and strengths).

struct EnvelopeWallCase {
    var id: String
    var scenario: Scenario
    var owner: UUID
    var cellSize: Float
    var construction: EnvelopeConstruction
    /// The wall as built, as a cantilever.
    var asBuilt: SDOFSystem
    var masonry: Bool
    var measured: String
    var detailed: String
}

func envelopeWallCases(names: [String]?) -> [EnvelopeWallCase] {
    var cases: [EnvelopeWallCase] = []
    func want(_ id: String) -> Bool { names?.contains(id) ?? true }
    // Alsubaei's walls, laid out as `PerimeterWallTests.runWall` lays them, the wall an envelope.
    func alsubaei(
        _ id: String, wall: PerimeterWallTests.Wall, anfo: Float,
        construction: (UUID) -> EnvelopeConstruction,
        asBuilt: SDOFSystem, measured: String, detailed: String
    ) {
        guard want(id) else { return }
        let layout = wall.layout
        let cellSize: Float = 0.05
        let t = layout.wallThickness
        let height = layout.wallHeight
        let behind = max(3 * layout.top, 3)
        let size = SIMD3(
            2 * layout.margin + layout.chargeToWall + t + behind, layout.width,
            max(3 * layout.top, layout.top + 3))
        let charge = SIMD3(layout.margin, layout.width / 2, layout.heightOfBurst)
        let front = charge.x + layout.chargeToWall
        let y0 = (layout.width - wall.length) / 2
        let y1 = y0 + wall.length
        let gap: Float = 0.05
        var solids = [Box(min: SIMD3(front, y0, 0), max: SIMD3(front + t, y1, height))]
        if layout.canopyDepth > 0 {
            solids.append(
                Box(
                    min: SIMD3(front - layout.canopyReach, y0, height),
                    max: SIMD3(front + t + layout.canopyReach, y1, layout.top)))
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
        var scenario = Scenario(
            name: "Envelope wall \(id)", domainSize: size, boxes: boxes,
            charge: Charge(mass: anfo * PerimeterWallTests.tntFactor, position: charge),
            gauges: [
                Gauge("Face, mid-height", at: SIMD3(front - 0.5 * cellSize, layout.width / 2, height / 2))
            ])
        let owner = UUID(uuidString: "00000000-0000-4000-8200-000000000001")!
        _ = try? scenario.addEnvelopeObject(
            BuildingEnvelope(solids: solids, openings: []), name: id, id: owner)
        cases.append(
            EnvelopeWallCase(
                id: id, scenario: scenario, owner: owner, cellSize: cellSize,
                construction: construction(owner),
                asBuilt: asBuilt, masonry: false, measured: measured, detailed: detailed))
    }
    let concrete = PerimeterWallTests.concrete
    alsubaei(
        "alsubaei-half", wall: .halfScale, anfo: 14,
        construction: {
            EnvelopeConstruction(
                objectID: $0, walls: .reinforcedConcrete, wallThicknessM: 0.2,
                reinforcementRatio: 2 * 392.5e-6 / 0.2,
                source: .user, detail: "0.2 m, 40 MPa, 10 mm at 200 mm in each face", barsInBothFaces: true,
                barCoverM: 0.03, concreteStrengthMPa: 40, barYieldMPa: 420)
        },
        // 10 mm at 200 mm, the tension face's bars 30 mm in.
        asBuilt: EnvelopePanel.reinforcedConcreteCantilever(
            thickness: 0.2, depth: 0.17, steelArea: 78.5e-6 / 0.2, material: concrete, height: 1),
        measured: "light cracking at the foot of the front face, no significant deformation (after 12 shots)",
        detailed:
            "clamped: top 37 mm, left 25 mm, 2.2 mm crack at the foot; on starter bars over rigid ground 67 / 46 mm"
    )
    alsubaei(
        "alsubaei-canopied", wall: .canopied, anfo: 125,
        construction: {
            EnvelopeConstruction(
                objectID: $0, walls: .reinforcedConcrete, wallThicknessM: 0.4,
                reinforcementRatio: 2 * 1570e-6 / 0.4,
                source: .user,
                detail: "0.4 m stem, 40 MPa, 20 mm at 200 mm in each face, a 1,152 kg/m canopy",
                barsInBothFaces: true, barCoverM: 0.06, concreteStrengthMPa: 40, barYieldMPa: 420,
                capMassKgPerM: 1.2 * 0.4 * 2400)
        },
        // 20 mm at 200 mm, 60 mm in; the canopy (1.2 × 0.4 m) carried on its top.
        asBuilt: EnvelopePanel.reinforcedConcreteCantilever(
            thickness: 0.4, depth: 0.34, steelArea: 314e-6 / 0.2, material: concrete, height: 2,
            topMass: 1.2 * 0.4 * Double(concrete.density)),
        measured: "unfaced: crack along the foot of the front face, three flexural cracks across the back, "
            + "no significant deformation; foam-faced: 7.3, 12.3 and 34.8 mm at mid-height",
        detailed: "clamped: mid-height 25 mm, top 54 mm, left 17 mm; front 1.5 mm at the foot")
    var block = PerimeterWallTests.blockwork(bars: true)
    if block.steel == nil { block.steel = PerimeterWallTests.grade60 }
    for (anfo, measured, detailed) in [
        (
            Float(25), "top 28 mm (double-integrated); bed joints cracked front and back, no spalling",
            "units and joints on starter bars: top 37 mm, left 21 mm"
        ),
        (125, "collapsed, debris about 15 m away", "every version comes apart"),
    ] {
        alsubaei(
            "alsubaei-block\(Int(anfo))", wall: .masonry, anfo: anfo,
            construction: {
                EnvelopeConstruction(
                    objectID: $0, walls: .reinforcedBlockwork, wallThicknessM: 0.4,
                    reinforcementRatio: 2 * 1570e-6 / 0.4, source: .user,
                    detail: "0.4 m hollow blockwork, 20 mm bars 100 mm in from each face",
                    barsInBothFaces: true,
                    barCoverM: 0.1, barYieldMPa: 420, blockworkGrouted: false)
            },
            // Hollow blocks with a 20 mm bar in every cell along the middle of each leaf (100 mm
            // in), the cells filled with foam: a reinforced wall of the blockwork's strength.
            asBuilt: EnvelopePanel.reinforcedConcreteCantilever(
                thickness: 0.4, depth: 0.3, steelArea: 314e-6 / 0.2, material: block, height: 2),
            measured: measured, detailed: detailed)
    }
    // Keys's walls in the open, as `MasonryDebrisTests.run` lays them out.
    // WR1C, rebuilt in weaker mortar a week before and repeated as WR2C, is left out as in the record.
    for trial in MasonryDebrisTests.trials where want("keys-\(trial.id)") && trial.id != "WR1C" {
        let cellSize: Float = 0.1
        let clearance: Float = 8
        let width = 1 + 2 * clearance
        let front = clearance + trial.standoff
        let wall = Box(
            min: SIMD3(front, width / 2 - 0.5, 0), max: SIMD3(front + 0.1025, width / 2 + 0.5, 2))
        var scenario = Scenario(
            name: "Envelope wall keys-\(trial.id)", domainSize: SIMD3(front + clearance, width, 10),
            boxes: [],
            charge: Charge(mass: 41, position: SIMD3(clearance, width / 2, 0)),
            gauges: [Gauge("Face", at: SIMD3(front - 0.5 * cellSize, width / 2, 1))])
        let owner = UUID(uuidString: "00000000-0000-4000-8200-000000000002")!
        _ = try? scenario.addEnvelopeObject(
            BuildingEnvelope(solids: [wall], openings: []), name: trial.id, id: owner)
        var brick = StructureMaterial.masonry
        brick.steel = nil
        brick.tensileStrength = MasonryUnits.brick.bondStrength
        cases.append(
            EnvelopeWallCase(
                id: "keys-\(trial.id)", scenario: scenario, owner: owner, cellSize: cellSize,
                construction: EnvelopeConstruction(
                    objectID: owner, walls: .unreinforcedMasonry, wallThicknessM: 0.1025, source: .user,
                    detail: "single-leaf brick, 102.5 mm"),
                asBuilt: EnvelopePanel.unreinforcedMasonryCantilever(
                    thickness: 0.1025, material: brick, height: 2),
                masonry: true,
                measured: "broke and fell (three pieces by 100 ms in WR1A; debris mean 0.23–0.64 m out)",
                detailed: "cracks at the measured heights, then falls as one column at about 1.15 s"))
    }
    return cases
}

func runEnvelopeWalls(device: MTLDevice) throws {
    if flag("hayman") { return try runHayman() }
    let names = option("cases")?.split(separator: ",").map(String.init)
    let duration = option("time").flatMap { Double($0) } ?? 0.25
    let out = option("out").map { URL(filePath: $0) }
    // `--from <dir>`: the histories a run with `--out` kept, judged again without the air.
    let from = option("from").map { URL(filePath: $0) }
    if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
    for wallCase in envelopeWallCases(names: names) {
        let started = ContinuousClock.now
        var histories: [EnvelopeComponentHistory]
        if let from {
            histories = try JSONDecoder().decode(
                [EnvelopeComponentHistory].self,
                from: Data(contentsOf: from.appending(path: "\(wallCase.id).json")))
        } else {
            var configuration = SolverConfiguration.recommended
            configuration.airSleepThreshold = 0
            configuration.airSleepCrossings = 0
            let solver = try BlastSolver(
                device: device, scenario: wallCase.scenario, cellSize: wallCase.cellSize,
                configuration: configuration)
            try solver.configureEnvelopeComponents(
                objects: wallCase.scenario.envelopeObjects, options: EnvelopeHistoryOptions(windowS: duration)
            )
            while solver.time < duration {
                let batch = solver.advance(steps: 16, timeLimit: duration)
                if batch.steps == 0 { break }
            }
            histories = solver.envelopeComponentHistories() ?? []
        }
        let loads = histories.map(EnvelopeComponentLoad.init)
        let wholes = Dictionary(
            histories.map { ($0.component.id, EnvelopeComponentLoad($0, whole: true)) },
            uniquingKeysWith: { a, _ in a })
        let seconds = Double((ContinuousClock.now - started).components.seconds)
        print("\(wallCase.id): \(String(format: "%.0f", seconds)) s")
        for load in loads where load.kind == .wall {
            let net = EnvelopeDamageAssessment.cantileverLoad(load.netPa)
            let peak = net.max() ?? 0
            let impulse = net.reduce(0) { $0 + max($1, 0) } * load.binS
            print(
                String(
                    format:
                        "  %@: %.1f × %.1f m, freestanding %@, peak net %.0f kPa, positive impulse %.0f Pa s",
                    load.id.split(separator: "/").dropFirst().joined(separator: "/"), load.spans.long,
                    load.height, load.isFreestanding ? "yes" : "no", peak / 1000, impulse))
            if let app = EnvelopeDamageAssessment.assess(load, construction: wallCase.construction) {
                print(
                    String(
                        format: "    the app's assessment (%@): %.2f°, %@%@", wallCase.construction.detail,
                        app.rotationDeg.upperBound, app.levels.upperBound.label,
                        app.failedAtS.map { String(format: ", fallen at %.2f s", $0) } ?? ""))
                // What it throws, landed, mass-weighted by distance from its face towards the
                // charge, in Keys's 0.5 m bins from 2 m in front.
                if let debris = EnvelopeDebris.make(
                    loads: [load], components: [app], centre: wallCase.scenario.charge.position,
                    ambient: Primitive(density: 1.225, pressure: 101_325)),
                    let source = debris.sources.first
                {
                    let face = load.region.min[load.axis]
                    var masses = [Float](repeating: 0, count: 400)
                    for impact in debris.impacts where impact.surface == "ground" {
                        let bin = Int(
                            ((impact.position[load.axis] - face + 2) / MasonryDebrisTests.binWidth).rounded(
                                .down))
                        if masses.indices.contains(bin) {
                            masses[bin] += impact.count * Float(source.pieceKg)
                        }
                    }
                    let spread = MasonryDebrisTests.Spread(firstBin: -2, masses: masses)
                    print(
                        String(
                            format:
                                "    thrown: %.0f kg in %.0f pieces of %.2f kg, fastest %.1f m/s, mean %.1f m/s; landed %@",
                            source.massKg, source.pieces, source.pieceKg, source.fastestMS, source.meanMS,
                            spread.description))
                    if let trial = MasonryDebrisTests.trials.first(where: { "keys-\($0.id)" == wallCase.id })
                    {
                        print(
                            "    measured debris: "
                                + MasonryDebrisTests.Spread(firstBin: trial.firstBin, masses: trial.masses)
                                .description)
                    }
                    print("    " + debris.summary)
                }
            }
            let tail =
                wallCase.masonry
                ? max(3, EnvelopeDamageAssessment.rockingFollowS / wallCase.asBuilt.period) : 3
            let response = wallCase.asBuilt.response(pressures: net, step: load.binS, tail: tail)
            let height = load.height
            let rotation =
                atan(max(response.peakDeflection, -response.reboundDeflection) / height) * 180 / .pi
            let level =
                wallCase.masonry
                ? (response.lostResistanceAt != nil
                    ? "fallen" : response.ductility > 1 ? "cracked" : "uncracked")
                : EnvelopeDamageLevel.concrete(ductility: response.ductility, rotationDeg: rotation).label
            print(
                String(
                    format:
                        "    as built: top %.1f mm at %.1f ms, left %.1f mm, %.2f°, ductility %.2f, %@%@ "
                        + "(resistance %.1f kPa, period %.1f ms)",
                    response.peakDeflection * 1000, response.peakTime * 1000,
                    response.residualDeflection * 1000,
                    rotation, response.ductility, level,
                    response.lostResistanceAt.map { String(format: ", fallen at %.2f s", $0) } ?? "",
                    wallCase.asBuilt.ultimateResistance / 1000, wallCase.asBuilt.period * 1000))
            if let whole = wholes[load.id] {
                let mean = EnvelopeDamageAssessment.cantileverLoad(whole.netPa)
                let other = wallCase.asBuilt.response(pressures: mean, step: load.binS, tail: tail)
                let turned = atan(max(other.peakDeflection, -other.reboundDeflection) / height) * 180 / .pi
                print(
                    String(
                        format:
                            "    on the whole component: top %.1f mm, %.2f°%@ (positive impulse %.0f Pa s)",
                        other.peakDeflection * 1000, turned,
                        other.lostResistanceAt.map { String(format: ", fallen at %.2f s", $0) } ?? "",
                        mean.reduce(0) { $0 + max($1, 0) } * load.binS))
            }
        }
        print("  measured: \(wallCase.measured)")
        print("  detailed model: \(wallCase.detailed)")
        if let out, from == nil {
            let encoder = JSONEncoder()
            encoder.nonConformingFloatEncodingStrategy = .convertToString(
                positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            try encoder.encode(histories).write(to: out.appending(path: "\(wallCase.id).json"))
        }
    }
}

// `blastbench envelope-walls --hayman`: Hayman's one-way reinforced masonry walls (Fixtures/Hayman2014),
// each driven by its own measured reflected load, a triangle of its peak and impulse, as the
// envelope's one-way strip (`EnvelopePanel.reinforcedOneWay`), simply supported top and bottom.
func runHayman() throws {
    struct Shot: Decodable {
        var wall: String
        var chargeKg: Double
        var peakKPa: Double
        var impulseKPaMs: Double
        enum CodingKeys: String, CodingKey {
            case wall
            case chargeKg = "charge_TNT_kg"
            case peakKPa = "Pr_kPa"
            case impulseKPaMs = "ir_kPa_ms"
        }
    }
    struct Measured: Decodable {
        var wall: String
        var peakMm: Double?
        var rotationDeg: Double?
        var state: String?
        enum CodingKeys: String, CodingKey {
            case wall
            case peakMm = "peak_mid_mm"
            case rotationDeg = "support_rotation_deg"
            case state = "damage_state"
        }
    }
    struct Fixture: Decodable {
        var shots: [Shot]
        var measured: [Measured]
    }
    let fixture = try JSONDecoder().decode(
        Fixture.self,
        from: Data(contentsOf: URL(filePath: option("inputs") ?? "Fixtures/Hayman2014/hayman2014.json")))
    // Fully grouted third-scale block, its density not given: taken as 2,100 kg/m³.
    let density = option("density").flatMap { Float($0) } ?? 2100
    let span = 1.0
    let thickness = 0.0633
    print(
        "Hayman's walls, one-way, simply supported over \(span) m, \(thickness * 1000) mm, density \(density) kg/m³"
    )
    for shot in fixture.shots {
        let heavy = shot.wall.hasPrefix("WMH")
        var material = StructureMaterial.concrete(
            name: "Grouted masonry", compressiveStrength: 20.8e6, density: density,
            steel: SteelProperties(
                yieldStress: heavy ? 484e6 : 478e6, ultimateStress: heavy ? 484e6 : 478e6,
                ultimateStrain: 0.05,
                ruptureStrain: 0.15))
        material.youngsModulus = 11.8e9
        // 15 bars in the metre's width, at mid-thickness.
        let area = 15 * (heavy ? 45e-6 : 26e-6)
        let wall = EnvelopePanel.reinforcedOneWay(
            thickness: thickness, depth: thickness / 2, steelArea: area, material: material, span: span)
        // The measured load as a triangle: its peak, falling to nothing at twice the impulse over it.
        let peak = shot.peakKPa * 1000
        let duration = 2 * shot.impulseKPaMs / shot.peakKPa / 1000
        let step = 1e-5
        let count = Int((duration / step).rounded(.up))
        let pressures = (0..<count).map { index -> Double in
            let start = Double(index) * step
            let end = min(start + step, duration)
            return peak * (1 - (start + end) / 2 / duration) * (end - start) / step
        }
        let response = wall.response(pressures: pressures, step: step)
        let rotation = response.supportRotationDegrees(span: span)
        let level = EnvelopeDamageLevel.concrete(ductility: response.ductility, rotationDeg: rotation).label
        let measured = fixture.measured.first { $0.wall == shot.wall }
        print(
            String(
                format:
                    "  %@ (%.0f kg): %.0f kPa, %.0f kPa ms (%.2f ms) -> %.1f mm, %.2f°, %@ (r_u %.0f kPa, T %.1f ms)"
                    + "; measured %@",
                shot.wall, shot.chargeKg, shot.peakKPa, shot.impulseKPaMs, duration * 1000,
                response.peakDeflection * 1000, rotation, level, wall.ultimateResistance / 1000,
                wall.period * 1000,
                measured.map { m in
                    (m.peakMm.map { String(format: "%.1f mm", $0) } ?? "–")
                        + (m.rotationDeg.map { String(format: ", %.2f°", $0) } ?? "")
                        + ", \(m.state ?? "")"
                } ?? "–"))
    }
}
