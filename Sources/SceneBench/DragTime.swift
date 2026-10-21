import BlastCore
import Foundation
import simd

/// `scenebench drag-time <district-scene's inputs> --loads folder --mass kg [--radius 2500]
/// [--moves 0,20,50] [--draws 100,20] [--check] [--drag 0,5,… [--weights field.bcfw]]`: what the quick estimate costs a frame as the
/// charge is dragged over a laid-out district (emmettl/bombcad-work#34): the district prepared once
/// (`FacadeLoadSurrogate.Prepared`), then for each move east of the charge, the estimate (the sight
/// lines), the damage, the glass chances and the walls' and roofs' chances, each timed. With
/// `--check`, the prepared estimate and glass sides against `estimate(scene:)`'s and
/// `glassSides(scene:)`'s, to the bit. With `--weights`, the drag's frames and the full look take the
/// learned field model's peak at the ground-floor façade strips (emmettl/bombcad-work#67), each
/// frame running the network again, as the app does with the option on.
enum DragTime {
    static func run(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        let reference = try SurrogateBench.Reference(args)
        let scene = reference.scene
        let dx = reference.cellSize
        let moves = (value("moves") ?? "0,20,50").split(separator: ",").compactMap { Float($0) }
        let drawList = (value("draws") ?? "100,20").split(separator: ",").compactMap { Int($0) }
        let mass = Double(scene.charge.mass)
        func seconds(_ start: ContinuousClock.Instant) -> Double { DistrictBenchmark.seconds(start) }

        let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: dx)
        print(
            String(
                format: "Prepared %d buildings, %d components on the air, in %.2f s",
                scene.envelopeObjects.count, prepared.componentCount, prepared.seconds))
        let constructions = { (id: UUID) in scene.envelopeConstruction(for: id) }
        for move in moves {
            var charge = scene.charge.position
            charge.x += move
            var clock = ContinuousClock.now
            let estimate = prepared.estimate(charge: charge, mass: mass)
            let estimateS = seconds(clock)
            clock = .now
            let (_, damageS, _) = FacadeLoadSurrogate.damage(estimate, constructions: constructions)
            clock = .now
            let sides = prepared.glassSides(estimate)
            let sidesS = seconds(clock)
            var line = String(
                format: "Moved %4.0f m: estimate %.2f s, damage %.2f s, %d glass sides %.2f s", move,
                estimateS,
                damageS, sides.count, sidesS)
            for draws in drawList {
                let uncertainty = FacadeLoadSurrogate.Uncertainty(
                    yieldLogSD: log(1.5) / 1.645, samples: draws)
                clock = .now
                _ = FacadeLoadSurrogate.glassProbabilities(
                    sides: sides, mass: mass, cellSize: dx, uncertainty: uncertainty)
                let glassS = seconds(clock)
                let (_, structureS) = FacadeLoadSurrogate.structureProbabilities(
                    estimate, mass: mass, cellSize: dx, constructions: constructions, uncertainty: uncertainty
                )
                line += String(format: "; %d draws: glass %.2f s, walls %.2f s", draws, glassS, structureS)
            }
            print(line)
        }

        // The preview: each move's cost, and at each move its agreement with the full estimate's
        // chances (`--reference-draws`, 40 unless given) and damage.
        let previewDraws = value("preview-draws").flatMap(Int.init) ?? 20
        // `--preview-quantum 0.03 --preview-strength-steps 20`: the previews' pane table as a full
        // look's, not the app's preview's (`Prepared.previewQuantum`, `previewStrengthSteps`).
        let previewQuantum = value("preview-quantum").flatMap(Double.init)
        let previewStrengthSteps = value("preview-strength-steps").flatMap(Double.init)
        let previewResponses = FacadeLoadSurrogate.GlassResponses(
            quantum: previewQuantum ?? FacadeLoadSurrogate.Prepared.previewQuantum,
            strengthSteps: previewStrengthSteps ?? FacadeLoadSurrogate.Prepared.previewStrengthSteps)
        let referenceDraws = value("reference-draws").flatMap(Int.init) ?? 40
        func stats(_ pairs: [(Double, Double)]) -> String {
            guard !pairs.isEmpty else { return "none" }
            let n = Double(pairs.count)
            let mean = pairs.reduce(0) { $0 + abs($1.0 - $1.1) } / n
            let bias = pairs.reduce(0) { $0 + ($1.0 - $1.1) } / n
            let within = Double(pairs.filter { abs($0.0 - $0.1) <= 0.1 }.count) / n
            let informative = pairs.filter { max($0.0, $0.1) > 0.02 }.count
            return String(
                format: "%d (%d above 0.02): mean |preview − full| %.3f, bias %+.3f, within 0.1 %.3f",
                pairs.count,
                informative, mean, bias, within)
        }
        for move in moves {
            var charge = scene.charge.position
            charge.x += move
            var uncertainty = FacadeLoadSurrogate.Uncertainty(
                yieldLogSD: log(1.5) / 1.645, samples: previewDraws)
            uncertainty.stratified = true
            var clock = ContinuousClock.now
            let (preview, sides) = prepared.preview(charge: charge, mass: mass)
            let previewS = seconds(clock)
            let (damage, damageS, _) = FacadeLoadSurrogate.damage(preview, constructions: constructions)
            clock = .now
            let (glass, _) = FacadeLoadSurrogate.glassProbabilities(
                sides: sides, mass: mass, cellSize: dx, uncertainty: uncertainty, responses: previewResponses)
            let glassS = seconds(clock)
            let (structure, structureS) = FacadeLoadSurrogate.structureProbabilities(
                preview, mass: mass, cellSize: dx, constructions: constructions, uncertainty: uncertainty)
            print(
                String(
                    format:
                        "Preview, moved %4.0f m: %d components, %d sides; estimate %.2f s, damage %.2f s, %d draws: glass %.2f s, walls %.2f s; %.2f s in all",
                    move, preview.components.count, sides.count, previewS, damageS, previewDraws, glassS,
                    structureS, previewS + damageS + glassS + structureS))
            guard args.contains("--agreement") else { continue }
            let full = prepared.estimate(charge: charge, mass: mass)
            let (fullDamage, _, _) = FacadeLoadSurrogate.damage(full, constructions: constructions)
            let reference = FacadeLoadSurrogate.Uncertainty(
                yieldLogSD: log(1.5) / 1.645, samples: referenceDraws)
            let (fullGlass, _) = FacadeLoadSurrogate.glassProbabilities(
                sides: prepared.glassSides(full), mass: mass, cellSize: dx, uncertainty: reference)
            let (fullStructure, _) = FacadeLoadSurrogate.structureProbabilities(
                full, mass: mass, cellSize: dx, constructions: constructions, uncertainty: reference)
            struct SideKey: Hashable {
                var owner: UUID
                var axis: Int
                var outward: Int
            }
            let fullSides = Dictionary(
                fullGlass.map { (SideKey(owner: $0.owner, axis: $0.axis, outward: $0.outward), $0) },
                uniquingKeysWith: { a, _ in a })
            let matched = glass.compactMap {
                g -> (FacadeLoadSurrogate.SideGlass, FacadeLoadSurrogate.SideGlass)? in
                fullSides[SideKey(owner: g.owner, axis: g.axis, outward: g.outward)].map { (g, $0) }
            }
            print("  glass, some broken, sides " + stats(matched.map { ($0.0.someBroken, $0.1.someBroken) }))
            print("  glass, blown out, sides " + stats(matched.map { ($0.0.blownOut, $0.1.blownOut) }))
            print(
                "  openings blown out, sides "
                    + stats(matched.map { ($0.0.openingsBlownOut, $0.1.openingsBlownOut) }))
            let fullChances = Dictionary(uniqueKeysWithValues: fullStructure.map { ($0.owner, $0) })
            let pairs = structure.compactMap { c in fullChances[c.owner].map { (c, $0) } }
            print(
                "  walls moderate+, buildings "
                    + stats(pairs.map { ($0.0.wallsModerate, $0.1.wallsModerate) }))
            print("  walls heavy+, buildings " + stats(pairs.map { ($0.0.wallsHeavy, $0.1.wallsHeavy) }))
            print(
                "  roof moderate+, buildings " + stats(pairs.map { ($0.0.roofModerate, $0.1.roofModerate) }))
            let fullCodes = Dictionary(
                uniqueKeysWithValues: fullDamage.map { ($0.id, EnvelopeDamageColour.code($0)) })
            var same = 0
            var withinOne = 0
            var counted = 0
            var codeCounts = [Int: (preview: Int, full: Int)]()
            for building in damage {
                guard let f = fullCodes[building.id] else { continue }
                let p = EnvelopeDamageColour.code(building)
                counted += 1
                same += p == f ? 1 : 0
                withinOne += abs(p - f) <= 1 ? 1 : 0
                codeCounts[p, default: (0, 0)].preview += 1
                codeCounts[f, default: (0, 0)].full += 1
            }
            print(
                String(
                    format:
                        "  damage colour, buildings %d: same %.3f, within one %.3f; by colour (preview/full) %@",
                    counted, Double(same) / Double(max(counted, 1)),
                    Double(withinOne) / Double(max(counted, 1)),
                    codeCounts.sorted { $0.key < $1.key }.map {
                        "\($0.key): \($0.value.preview)/\($0.value.full)"
                    }
                    .joined(separator: ", ") as NSString))
        }

        // `--drag 0,10,20,…`: a drag, frame by frame, each a preview with the responses kept
        // from the frames before (the app's case), then the full look where it stops.
        if let dragText = value("drag") {
            let steps = dragText.split(separator: ",").compactMap { Float($0) }
            var uncertainty = FacadeLoadSurrogate.Uncertainty(
                yieldLogSD: log(1.5) / 1.645, samples: previewDraws)
            uncertainty.stratified = true
            var dragged = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: dx)
            dragged.glassResponses = previewResponses
            var learned: LearnedField.Estimator?
            if let weights = value("weights") {
                let clock = ContinuousClock.now
                let network = try LearnedFieldNetwork(contentsOf: URL(filePath: weights))
                let loadS = seconds(clock)
                learned = LearnedField.Estimator(scene: scene, network: network)
                print(
                    String(
                        format:
                            "Learned field model: weights loaded %.2f s, its %d × %d plan laid out %.2f s",
                        loadS,
                        learned!.plan.columns, learned!.plan.rows, learned!.seconds))
            }
            // `--parts damage|glass|structure`: what the view shows while dragging; all without.
            let parts: FacadeLoadSurrogate.Prepared.Parts =
                switch value("parts") {
                case "damage": .damage
                case "glass": .glass
                case "structure": .structure
                default: .all
                }
            for step in steps {
                var charge = scene.charge.position
                charge.x += step
                let look = dragged.look(
                    charge: charge, mass: mass, constructions: constructions, uncertainty: uncertainty,
                    preview: true,
                    parts: parts, learned: learned)
                print(
                    String(
                        format:
                            "Drag frame at %4.0f m: estimate %.2f s, damage %.2f s, glass %.2f s, walls %.2f s; %.2f s",
                        step, look.seconds.estimate, look.seconds.damage, look.seconds.glass,
                        look.seconds.structure,
                        look.totalSeconds) + String(format: "; resident %.1f GB", residentGB())
                        + (learned == nil
                            ? ""
                            : String(
                                format: "; learned peaks %.2f s at %d strips%@", look.learnedSeconds,
                                look.learnedStrips,
                                (look.learnedError ?? "") as NSString)))
            }
            var charge = scene.charge.position
            charge.x += steps.last ?? 0
            let full = dragged.look(
                charge: charge, mass: mass, constructions: constructions,
                uncertainty: FacadeLoadSurrogate.Uncertainty(yieldLogSD: log(1.5) / 1.645), learned: learned)
            print(
                String(
                    format:
                        "Let go: full look, 100 draws: estimate %.2f s, damage %.2f s, glass %.2f s, walls %.2f s; %.2f s",
                    full.seconds.estimate, full.seconds.damage, full.seconds.glass, full.seconds.structure,
                    full.totalSeconds)
                    + (learned == nil
                        ? ""
                        : String(
                            format: "; learned peaks %.2f s at %d strips%@", full.learnedSeconds,
                            full.learnedStrips,
                            (full.learnedError ?? "") as NSString)))
            print(
                "  responses kept: SDOF \(dragged.memo.misses) integrated, \(dragged.memo.hits) reused; "
                    + String(format: "resident %.1f GB", residentGB()))
        }

        if args.contains("--check") {
            var clock = ContinuousClock.now
            let whole = FacadeLoadSurrogate.estimate(scene: scene, cellSize: dx)
            let wholeS = seconds(clock)
            clock = .now
            let wholeSides = FacadeLoadSurrogate.glassSides(scene: scene, cellSize: dx)
            let sidesS = seconds(clock)
            let mine = prepared.estimate(charge: scene.charge.position, mass: mass)
            let mySides = prepared.glassSides(mine)
            let sameLoads =
                whole.loads.count == mine.loads.count
                && zip(whole.loads, mine.loads).allSatisfy { $0.outerPa == $1.outerPa && $0.id == $1.id }
            let sameSides =
                wholeSides.count == mySides.count
                && zip(wholeSides, mySides).allSatisfy { a, b in
                    a.owner == b.owner && a.axis == b.axis && a.outward == b.outward
                        && a.strips.count == b.strips.count
                        && zip(a.strips, b.strips).allSatisfy {
                            $0.features == $1.features && $0.areaM2 == $1.areaM2
                        }
                }
            print(
                String(
                    format:
                        "Check: estimate(scene:) %.2f s, glassSides(scene:) %.2f s; loads %@, glass sides %@",
                    wholeS, sidesS, (sameLoads ? "the same" : "DIFFER") as NSString,
                    (sameSides ? "the same" : "DIFFER") as NSString))
        }
    }

    /// This process's resident memory, GB.
    static func residentGB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1e9 : .nan
    }
}
