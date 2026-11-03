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
/// frame running the network again, as the app does with the option on. With `--terms`, the façade
/// terms and load scatter of that set throughout (the adopted ones without it); with `--agreement
/// --trace-sides file.tsv`, each glazed side's chances, preview and full, beside its strips' facing
/// (emmettl/bombcad-work#110).
enum DragTime {
    static func run(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        // Beirut with its run's loads, or a made-up district from its map; with `--what-if`, every
        // building built so (emmettl/bombcad-work#113).
        let (district, dx) = try ResponseData.district(args)
        let whatIf = try ResponseData.whatIf(args)
        let scene = whatIf.applied(to: district)
        if !whatIf.isEmpty { print("What if: \(whatIf.label)") }
        let moves = (value("moves") ?? "0,20,50").split(separator: ",").compactMap { Float($0) }
        let drawList = (value("draws") ?? "100,20").split(separator: ",").compactMap { Int($0) }
        let mass = Double(scene.charge.mass)
        // `--terms`: the façade terms and load scatter judged (the adopted ones without it).
        let terms = try SurrogateBench.termSet(args)
        let coefficients = terms.coefficients
        func uncertainty(_ samples: Int) -> FacadeLoadSurrogate.Uncertainty {
            FacadeLoadSurrogate.Uncertainty(
                yieldLogSD: log(value("yield-within").flatMap(Double.init) ?? 1.5) / 1.645,
                loadScatter: terms.loadScatter,
                samples: samples)
        }
        func seconds(_ start: ContinuousClock.Instant) -> Double { DistrictBenchmark.seconds(start) }

        let prepared = FacadeLoadSurrogate.Prepared(
            scene: scene, cellSize: dx, incidence: SurrogateBench.incidence(args))
        // `--live [--response file.bclr] [--engine cpu]`: the previews judged by the learned response
        // (emmettl/bombcad-work#112), its weights built in unless given, on the GPU unless asked.
        var live: LiveResponse.Model?
        if args.contains("--live") || value("response") != nil {
            let weights =
                try value("response").map { try LiveResponse.Weights(contentsOf: URL(filePath: $0)) }
                ?? LiveResponse.Weights.builtIn
            guard let weights else { throw BlastError.allocationFailed("no live response weights built in") }
            let engine: LiveResponse.Engine =
                value("engine") == "cpu"
                ? LiveResponse.CPUEngine(weights: weights) : try LiveDragGPU(weights: weights)
            // The built-in weights leave what lies outside their training to the CPU, as the app does
            // (emmettl/bombcad-work#118), unless `--no-range-fallback`.
            let ranges =
                value("response") == nil && !args.contains("--no-range-fallback")
                ? LiveResponse.TrainingRanges.forBuiltInWeights : nil
            live = LiveResponse.Model(weights: weights, engine: engine, ranges: ranges)
            print(
                "Live response: \(weights.header.trainedOn ?? "?"), on the \(engine.label)"
                    + (ranges == nil ? "" : "; what lies outside its training on the CPU's preview"))
        }
        print(
            String(
                format: "Prepared %d buildings, %d components on the air, in %.2f s",
                scene.envelopeObjects.count, prepared.componentCount, prepared.seconds))
        let constructions = { (id: UUID) in scene.envelopeConstruction(for: id) }
        // `--no-full`: not the full estimate's own times at each move.
        for move in args.contains("--no-full") ? [] : moves {
            var charge = scene.charge.position
            charge.x += move
            var clock = ContinuousClock.now
            let estimate = prepared.estimate(charge: charge, mass: mass, coefficients: coefficients)
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
                let drawn = uncertainty(draws)
                clock = .now
                _ = FacadeLoadSurrogate.glassProbabilities(
                    sides: sides, mass: mass, cellSize: dx, uncertainty: drawn, coefficients: coefficients)
                let glassS = seconds(clock)
                let (_, structureS) = FacadeLoadSurrogate.structureProbabilities(
                    estimate, mass: mass, cellSize: dx, constructions: constructions, uncertainty: drawn,
                    coefficients: coefficients)
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
            var previewUncertainty = uncertainty(previewDraws)
            previewUncertainty.stratified = true
            var clock = ContinuousClock.now
            let (preview, sides) = prepared.preview(charge: charge, mass: mass, coefficients: coefficients)
            let previewS = seconds(clock)
            var (damage, damageS, _) = FacadeLoadSurrogate.damage(preview, constructions: constructions)
            clock = .now
            var (glass, _) = FacadeLoadSurrogate.glassProbabilities(
                sides: sides, mass: mass, cellSize: dx, uncertainty: previewUncertainty,
                coefficients: coefficients,
                responses: previewResponses)
            let glassS = seconds(clock)
            var (structure, structureS) = FacadeLoadSurrogate.structureProbabilities(
                preview, mass: mass, cellSize: dx, constructions: constructions,
                uncertainty: previewUncertainty,
                coefficients: coefficients)
            if let live {
                // The learned response's in place of the CPU's, judged below as they are.
                guard
                    let (look, stages) = try prepared.livePreview(
                        charge: charge, mass: mass, uncertainty: previewUncertainty,
                        terms: terms, model: live)
                else { throw BlastError.allocationFailed("the live response does not know this district") }
                // The live colours against the CPU preview's own, building by building.
                let cpuCodes = Dictionary(
                    uniqueKeysWithValues: damage.map { ($0.id, EnvelopeDamageColour.code($0)) })
                var differ: [String: Int] = [:]
                for building in look.damage {
                    let mine = EnvelopeDamageColour.code(building)
                    if let theirs = cpuCodes[building.id], theirs != mine {
                        differ["\(theirs)→\(mine)", default: 0] += 1
                    }
                }
                print(
                    "  live damage colour against the CPU preview's: \(differ.values.reduce(0, +)) of \(look.damage.count) differ "
                        + differ.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(
                            separator: ", "))
                // `--against-preview`: the live chances against the CPU preview's own (what the
                // networks were trained to give, at `--preview-draws`), apart from the preview's own
                // approximation.
                if args.contains("--against-preview") {
                    let cpuSides = Dictionary(
                        glass.map { ("\($0.owner) \($0.axis) \($0.outward)", $0) },
                        uniquingKeysWith: { a, _ in a })
                    let sidePairs = look.glass.compactMap { g in
                        cpuSides["\(g.owner) \(g.axis) \(g.outward)"].map { (g, $0) }
                    }
                    let cpuChances = Dictionary(uniqueKeysWithValues: structure.map { ($0.owner, $0) })
                    let buildingPairs = look.structure.compactMap { c in cpuChances[c.owner].map { (c, $0) } }
                    print(
                        "  live against the CPU preview: glass blown out "
                            + stats(sidePairs.map { ($0.0.blownOut, $0.1.blownOut) }))
                    print(
                        "  live against the CPU preview: walls moderate+ "
                            + stats(buildingPairs.map { ($0.0.wallsModerate, $0.1.wallsModerate) }))
                    print(
                        "  live against the CPU preview: walls heavy+ "
                            + stats(buildingPairs.map { ($0.0.wallsHeavy, $0.1.wallsHeavy) }))
                    print(
                        "  live against the CPU preview: roof moderate+ "
                            + stats(buildingPairs.map { ($0.0.roofModerate, $0.1.roofModerate) }))
                }
                damage = look.damage
                glass = look.glass
                structure = look.structure
                print(
                    String(
                        format:
                            "Live, moved %4.0f m: %d components, %d sides, %d buildings, %d of them on the CPU; choice %.3f, loads %.3f, inputs %.3f, range %.3f, networks %.3f, answers %.3f, CPU %.3f s; %.3f s in all",
                        move, look.estimate.components.count, look.glass.count, look.structure.count,
                        look.leftToCPU, stages.choice, stages.loads, stages.inputs, stages.range,
                        stages.networks,
                        stages.answers, stages.cpu, look.totalSeconds))
                if let note = look.untrainedNote { print("  \(note)") }
            }
            print(
                String(
                    format:
                        "Preview, moved %4.0f m: %d components, %d sides; estimate %.2f s, damage %.2f s, %d draws: glass %.2f s, walls %.2f s; %.2f s in all",
                    move, preview.components.count, sides.count, previewS, damageS, previewDraws, glassS,
                    structureS, previewS + damageS + glassS + structureS))
            guard args.contains("--agreement") else { continue }
            let full = prepared.estimate(charge: charge, mass: mass, coefficients: coefficients)
            let (fullDamage, _, _) = FacadeLoadSurrogate.damage(full, constructions: constructions)
            let reference = uncertainty(referenceDraws)
            let (fullGlass, _) = FacadeLoadSurrogate.glassProbabilities(
                sides: prepared.glassSides(full), mass: mass, cellSize: dx, uncertainty: reference,
                coefficients: coefficients)
            let (fullStructure, _) = FacadeLoadSurrogate.structureProbabilities(
                full, mass: mass, cellSize: dx, constructions: constructions, uncertainty: reference,
                coefficients: coefficients)
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
            // `--trace-sides file.tsv`: each glazed side's chances, preview and full, with the
            // preview's strip's facing and distance and the full side's strips' (area-weighted
            // mean, nearest, and how many outline facings they take), for each move.
            if let path = value("trace-sides") {
                var text =
                    move == moves.first
                    ? "move\tside\tpreviewBlown\tfullBlown\tpreviewSome\tfullSome"
                        + "\tpreviewCos\tpreviewDistance\tpreviewArea\tstrips\tmeanCos\tminCos\tmaxCos"
                        + "\tnearestCos\tnearestDistance\tfacings\tshares\tpreviewStrips\n" : ""
                let fullStrips = Dictionary(
                    prepared.glassSides(full).map {
                        (SideKey(owner: $0.owner, axis: $0.axis, outward: $0.outward), $0)
                    }, uniquingKeysWith: { a, _ in a })
                // Each full side's strips' facings: the distinct plan normals they take.
                var facings = [SideKey: [SIMD2<Int>: Double]]()
                for (k, n) in full.owners.enumerated() where full.components[k].kind == .facade {
                    let c = full.components[k]
                    let key = SideKey(owner: c.owner, axis: c.axis, outward: c.outward)
                    var normal = SIMD3<Float>.zero
                    normal[c.axis] = Float(c.outward)
                    let facing =
                        prepared.raster.outlineNormal(
                            region: c.region, axis: c.axis, outward: c.outward, owner: n)
                        ?? normal
                    let rounded = SIMD2(Int((facing.x * 1000).rounded()), Int((facing.y * 1000).rounded()))
                    facings[key, default: [:]][rounded, default: 0] += Double(c.spans.x * c.spans.y)
                }
                for (n, side) in sides.enumerated() {
                    let key = SideKey(owner: side.owner, axis: side.axis, outward: side.outward)
                    guard let f = fullSides[key], let strips = fullStrips[key], let mine = side.strips.first
                    else { continue }
                    let area = strips.strips.reduce(0) { $0 + $1.areaM2 }
                    let meanCos =
                        strips.strips.reduce(0) { $0 + $1.features.cosIncidence * $1.areaM2 }
                        / max(area, 1e-9)
                    let nearest = strips.strips.min { $0.features.distanceM < $1.features.distanceM }!
                    text += String(
                        format:
                            "%.0f\t%d\t%.3f\t%.3f\t%.3f\t%.3f\t%.4f\t%.1f\t%.1f\t%d\t%.4f\t%.4f\t%.4f\t%.4f\t%.1f\t%d\t%@\t%d\n",
                        move, n, glass[n].blownOut, f.blownOut, glass[n].someBroken, f.someBroken,
                        mine.features.cosIncidence, mine.features.distanceM, mine.areaM2, strips.strips.count,
                        meanCos, strips.strips.map(\.features.cosIncidence).min()!,
                        strips.strips.map(\.features.cosIncidence).max()!, nearest.features.cosIncidence,
                        nearest.features.distanceM, facings[key]?.count ?? 0,
                        (facings[key] ?? [:]).values.sorted(by: >).map { String(format: "%.3f", $0 / area) }
                            .joined(separator: ",") as NSString, side.strips.count)
                }
                if let handle = FileHandle(forWritingAtPath: path), move != moves.first {
                    handle.seekToEndOfFile()
                    handle.write(Data(text.utf8))
                    try handle.close()
                } else {
                    try text.write(toFile: path, atomically: true, encoding: .utf8)
                }
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

        // The fire after the blast as the app's preview draws it (40 draws, 20 fires at random within
        // 1.5 km, 12 h) on a look's glass and walls: with `--fire-cache`, its district kept between
        // frames as the app keeps it, and with `--fire-check` drawn without it too, to show the two
        // the same (emmettl/bombcad-work#113).
        let fireCache = args.contains("--fire-cache") ? FireSpread.LayerCache() : nil
        func fire(
            on look: FacadeLoadSurrogate.Prepared.Look, charge: SIMD3<Float>, wind: FireSpread.Wind
        ) -> String {
            var settings = FireSpread.LayerSettings()
            settings.randomCount = 20
            settings.wind = wind
            var moved = scene
            moved.charge.position = charge
            let source = FireSpread.LayerSource.estimate(glass: look.glass, structure: look.structure)
            let clock = ContinuousClock.now
            let layer = FireSpread.layer(
                scene: moved, source: source, settings: settings, members: 40, preview: true, cache: fireCache
            )
            var line = String(
                format: "fire, 40 draws: %.4f s, %d buildings", seconds(clock), layer?.ids.count ?? 0)
            if let fireCache {
                let r = fireCache.rebuilt
                line +=
                    " (laid out again:\(r.buildings ? " buildings" : "")\(r.neighbours ? " neighbours" : "")"
                    + "\(r.stages ? " stages" : "")\(r.buildings || r.neighbours || r.stages ? "" : " nothing"))"
                if args.contains("--fire-check") {
                    let plain = FireSpread.layer(
                        scene: moved, source: source, settings: settings, members: 40, preview: true)
                    let same =
                        plain?.ids == layer?.ids && plain?.ignitions == layer?.ignitions
                        && plain?.fromNeighbour == layer?.fromNeighbour
                    line += same ? "; the same as without the cache" : "; NOT THE SAME as without the cache"
                }
            }
            return line
        }

        // `--wind-slide "5.7@240,5.7@245,…"` (m/s @ degrees from): the fire's wind sliders moved, the
        // charge and the estimate where they are, frame by frame: the fire drawn again on each.
        if let live, let windText = value("wind-slide") {
            var windUncertainty = uncertainty(previewDraws)
            windUncertainty.stratified = true
            guard
                let (look, _) = try prepared.livePreview(
                    charge: scene.charge.position, mass: mass, uncertainty: windUncertainty, parts: .all,
                    terms: terms, model: live)
            else { throw BlastError.allocationFailed("the live response does not know this district") }
            for item in windText.split(separator: ",") {
                let pair = item.split(separator: "@").compactMap { Double($0) }
                guard pair.count == 2 else { continue }
                let wind = FireSpread.Wind(speedMS: pair[0], fromDegrees: pair[1])
                print(
                    String(format: "Wind frame, %.1f m/s from %.0f°: ", pair[0], pair[1])
                        + fire(on: look, charge: scene.charge.position, wind: wind))
            }
        }

        // `--slide 300000,350000,…` (kg) and `--slide-what-ifs "glass=toughened;glass=laminated;…"`
        // (`--what-if`'s, as built for an empty one): a slider moved, the charge where it is, frame by
        // frame through the learned response, each what-if laid on the district first, as the app
        // lays it on (emmettl/bombcad-work#113).
        if let live, value("slide") != nil || value("slide-what-ifs") != nil {
            var frames: [(label: String, mass: Double, whatIf: LiveResponse.WhatIf)] = []
            for kg in (value("slide") ?? "").split(separator: ",").compactMap({ Double($0) }) {
                frames.append(("\(Int(kg)) kg", kg, whatIf))
            }
            for text in (value("slide-what-ifs") ?? "").split(
                separator: ";", omittingEmptySubsequences: false)
            where value("slide-what-ifs") != nil {
                let each = text.isEmpty ? LiveResponse.WhatIf() : try ResponseData.whatIf(text: String(text))
                frames.append((each.label, mass, each))
            }
            var slideUncertainty = uncertainty(previewDraws)
            slideUncertainty.stratified = true
            let parts: FacadeLoadSurrogate.Prepared.Parts =
                switch value("parts") {
                case "damage": .damage
                case "glass": .glass
                case "structure": .structure
                default: .all
                }
            var sliding = prepared
            var shown = whatIf
            for frame in frames {
                let clock = ContinuousClock.now
                if frame.whatIf != shown {
                    sliding = sliding.withConstructions(of: frame.whatIf.applied(to: district))
                    shown = frame.whatIf
                }
                let laidS = seconds(clock)
                guard
                    let (look, stages) = try sliding.livePreview(
                        charge: scene.charge.position, mass: frame.mass, uncertainty: slideUncertainty,
                        parts: parts,
                        terms: terms, model: live)
                else { throw BlastError.allocationFailed("the live response cannot read \(frame.label)") }
                print(
                    String(
                        format:
                            "Slide frame, %@: what-if laid on %.4f, district %.4f, choice %.4f, loads %.4f, inputs %.4f, networks %.4f, answers %.4f s (GPU %.4f); %.4f s in all; %d damaged, %d sides blown out ≥ 0.5",
                        frame.label as NSString, laidS, stages.district, stages.choice, stages.loads,
                        stages.inputs,
                        stages.networks, stages.answers, stages.gpu, seconds(clock),
                        look.damage.filter { $0.structuralLevels.upperBound != .none }.count,
                        look.glass.filter { $0.blownOut >= 0.5 }.count))
            }
        }

        // `--drag 0,10,20,…`: a drag, frame by frame, each a preview with the responses kept
        // from the frames before (the app's case), then the full look where it stops.
        if let dragText = value("drag") {
            let steps = dragText.split(separator: ",").compactMap { Float($0) }
            var dragUncertainty = uncertainty(previewDraws)
            dragUncertainty.stratified = true
            var dragged = FacadeLoadSurrogate.Prepared(
                scene: scene, cellSize: dx, incidence: SurrogateBench.incidence(args))
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
            var behind: FireBehind?
            for step in steps {
                var charge = scene.charge.position
                charge.x += step
                if let live {
                    let clock = ContinuousClock.now
                    guard
                        let (look, stages) = try dragged.livePreview(
                            charge: charge, mass: mass, uncertainty: dragUncertainty,
                            parts: parts, terms: terms, model: live)
                    else {
                        throw BlastError.allocationFailed("the live response does not know this district")
                    }
                    print(
                        String(
                            format:
                                "Drag frame at %4.0f m: estimate %.2f s, damage %.2f s, glass %.2f s, walls %.2f s; %.2f s; live: district %.4f, choice %.4f, loads %.4f, inputs %.4f, range %.4f, networks %.4f, answers %.4f s (GPU %.4f), %d of %d buildings on the CPU %.4f s; %.4f s in all",
                            step, look.seconds.estimate, look.seconds.damage, look.seconds.glass,
                            look.seconds.structure, look.totalSeconds, stages.district, stages.choice,
                            stages.loads,
                            stages.inputs, stages.range, stages.networks, stages.answers, stages.gpu,
                            look.leftToCPU,
                            look.liveBuildings, stages.cpu, seconds(clock)))
                    if look.leftToCPU > 0, step == steps.first {
                        print(
                            "  outside the training: "
                                + look.outsideTraining.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map
                            {
                                "\($0.key) \($0.value)"
                            }.joined(separator: ", "))
                    }
                    // `--fire`: the fire drawn on the frame's glass (`fire(on:)`), with `--wind` degrees to
                    // turn the wind frame by frame, and the frame and its fire timed together. With
                    // `--fire-overlap`, as the app draws it: the frame's fire behind the next frame's
                    // estimate, each frame timed to when its estimate and the last frame's fire are both done.
                    if args.contains("--fire") {
                        let turn = value("wind").flatMap(Double.init) ?? 0
                        let wind = FireSpread.Wind(
                            speedMS: 5.7,
                            fromDegrees: (240 + turn * Double(step)).truncatingRemainder(dividingBy: 360))
                        if args.contains("--fire-overlap") {
                            if let behind {
                                behind.group.wait()
                                print("  the last frame's \(behind.line)")
                            }
                            print(
                                String(
                                    format: "  the frame, the last frame's fire behind it, %.4f s",
                                    seconds(clock)))
                            let next = FireBehind()
                            next.work = { fire(on: look, charge: charge, wind: wind) }
                            next.start()
                            behind = next
                        } else {
                            let line = fire(on: look, charge: charge, wind: wind)
                            print(
                                String(
                                    format: "  %@; the frame with its fire %.4f s", line as NSString,
                                    seconds(clock)))
                        }
                    }
                    continue
                }
                let look = dragged.look(
                    charge: charge, mass: mass, constructions: constructions, uncertainty: dragUncertainty,
                    preview: true,
                    parts: parts, learned: learned, terms: terms)
                print(
                    String(
                        format:
                            "Drag frame at %4.0f m: estimate %.2f s, damage %.2f s, glass %.2f s, walls %.2f s; %.2f s",
                        step, look.seconds.estimate, look.seconds.damage, look.seconds.glass,
                        look.seconds.structure,
                        look.totalSeconds) + String(format: "; resident %.1f GB", residentGB())
                        + (look.estimate.previewStages.map {
                            String(
                                format:
                                    "; preview: open reach %.3f, choice %.3f, sight lines %.3f, loads %.3f, assembly %.3f s; %d components, %d sides",
                                $0.openReach, $0.choice, $0.sightLines, $0.loads, $0.assembly,
                                look.estimate.components.count, look.glass.count)
                        } ?? "")
                        + (learned == nil
                            ? ""
                            : String(
                                format: "; learned peaks %.2f s at %d strips%@", look.learnedSeconds,
                                look.learnedStrips,
                                (look.learnedError ?? "") as NSString)))
            }
            if let behind {
                behind.group.wait()
                print("  the last frame's \(behind.line)")
            }
            var charge = scene.charge.position
            charge.x += steps.last ?? 0
            // `--no-let-go`: the frames alone, not the full look where the drag stops.
            guard !args.contains("--no-let-go") else { return }
            let full = dragged.look(
                charge: charge, mass: mass, constructions: constructions,
                uncertainty: uncertainty(100), learned: learned, terms: terms)
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

        // `--check-choices`: the preview's choice by its groups laid out once against the choice by
        // dictionaries, at each move (emmettl/bombcad-work#112).
        if args.contains("--check-choices") {
            for move in moves {
                var charge = scene.charge.position
                charge.x += move
                var clock = ContinuousClock.now
                let fast = prepared.choices(charge: charge)
                let fastS = seconds(clock)
                clock = .now
                let reference = prepared.referenceChoices(charge: charge)
                let referenceS = seconds(clock)
                let same =
                    fast.map { $0.map(\.index) } == reference.map { $0.map(\.index) }
                    && fast.map { $0.map(\.area) } == reference.map { $0.map(\.area) }
                    && fast.map { $0.map(\.judged) } == reference.map { $0.map(\.judged) }
                print(
                    String(
                        format: "Choices at %.0f m: %@, %.4f s against %.4f s", move,
                        (same ? "the same" : "DIFFER") as NSString, fastS, referenceS))
            }
        }

        if args.contains("--check") {
            var clock = ContinuousClock.now
            let whole = FacadeLoadSurrogate.estimate(scene: scene, cellSize: dx)
            let wholeS = seconds(clock)
            clock = .now
            let wholeSides = FacadeLoadSurrogate.glassSides(
                scene: scene, cellSize: dx, incidence: SurrogateBench.incidence(args))
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

/// A frame's fire drawn on another thread while the next frame's estimate is made, as the app draws it.
private final class FireBehind: @unchecked Sendable {
    let group = DispatchGroup()
    var work: (() -> String)?
    var line = ""

    func start() {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            line = work?() ?? ""
            group.leave()
        }
    }
}
