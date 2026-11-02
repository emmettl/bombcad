import BlastCore
import Foundation
import simd

/// `scenebench response-data <district-scene's inputs> [--loads folder] --out folder --district name
/// [--radius 2500] [--frames 200] [--first 0] [--draws 64] [--within 1500] [--keep 0.1] [--seed 1]
/// [--as-built]`: training data for the live drag's learned response (emmettl/bombcad-work#112,
/// #113): the district laid out once (`FacadeLoadSurrogate.Prepared`; with `--loads` Beirut's, as a
/// run saved it, else from its map alone, as `make_district.py`'s made-up districts), then for each
/// frame each building built as drawn (`LiveResponse.drawn`: its walls, roof, glazing and glass, a
/// fifth of them as built; all as built with `--as-built`), and a charge placed at random on the open
/// ground within `--within` m of the scene's, of 100 kg to 5 kt evenly in the log, with a yield
/// spread of one of the app's choices (exactly, ×1.25, ×1.5, ×2, ×3). Each frame's drag preview
/// (`Prepared.preview`) gives the networks' inputs (`LiveResponse.batch`), and the CPU code they
/// stand in for gives their answers:
/// - each component's damage level and whether its glass breaks (`EnvelopeDamageAssessment.assess`);
/// - each glazed side's glass chances (`glassProbabilities`, `--draws` draws spread evenly);
/// - each building's walls' and roof's chances (`structureProbabilities`, as many).
///
/// Rows whose answers are all none (or certain) are kept one in 1/`--keep`, with that weight. Each
/// frame's rows go to `component`, `side` and `building` files of float32 (`*-x.f32` inputs,
/// `*-y.f32` answers, `*-w.f32` weights, `*-frame.i32` the frame), with `meta.json` naming the
/// widths and the district. Charges within 100 m of the scene's own place or 60 m east of it, where
/// `drag-time --agreement` judges the preview, are not drawn.
enum ResponseData {
    struct Meta: Codable {
        var district: String
        var componentWidth: Int
        var sideWidth: Int
        var buildingWidth: Int
        var componentOutputs: [String]
        var sideOutputs: [String]
        var buildingOutputs: [String]
        var frames: [[Double]] = []
        var draws: Int
        var cellSize: Float
    }

    /// A district with a run's saved loads (`--loads`, Beirut's), or one laid out from its map alone
    /// (a made-up district, `Scripts/ml/make_district.py`), on a square of half side `--radius`.
    static func district(_ args: [String]) throws -> (Scenario, Float) {
        if SurrogateBench.value(args, "loads") != nil {
            let reference = try SurrogateBench.Reference(args)
            return (reference.scene, reference.cellSize)
        }
        let inputs = try DistrictInputs.read(args)
        let (scene, _) = try inputs.scene(
            radius: Float(SurrogateBench.value(args, "radius").flatMap(Double.init) ?? 1000))
        return (scene, inputs.cellSize)
    }

    /// `--what-if glass=toughened,walls=masonry,roof=sheeting`: every building built so
    /// (`LiveResponse.WhatIf`; glass annealed, toughened, film-daylight, film-wet, film-mechanical or
    /// laminated; walls concrete, blockwork, masonry, sheeting or timber; roofs concrete, sheeting or
    /// timber).
    static func whatIf(_ args: [String]) throws -> LiveResponse.WhatIf {
        try SurrogateBench.value(args, "what-if").map(whatIf(text:)) ?? LiveResponse.WhatIf()
    }

    /// A what-if from its text, as `--what-if` takes it.
    static func whatIf(text: String) throws -> LiveResponse.WhatIf {
        var whatIf = LiveResponse.WhatIf()
        let kinds: [String: EnvelopeConstruction.Kind] = [
            "concrete": .reinforcedConcrete, "blockwork": .reinforcedBlockwork,
            "masonry": .unreinforcedMasonry,
            "sheeting": .profiledSteelSheeting, "timber": .crossLaminatedTimber,
        ]
        let glasses: [String: LiveResponse.Glass] = Dictionary(
            uniqueKeysWithValues: zip(
                ["annealed", "toughened", "film-daylight", "film-wet", "film-mechanical", "laminated"],
                LiveResponse.Glass.offered.map(\.glass)))
        for part in text.split(separator: ",") {
            let pair = part.split(separator: "=").map(String.init)
            guard pair.count == 2 else { throw BlastError.allocationFailed("--what-if \(part)") }
            switch pair[0] {
            case "glass": whatIf.glass = glasses[pair[1]]
            case "walls": whatIf.walls = kinds[pair[1]]
            case "roof": whatIf.roof = kinds[pair[1]]
            default: throw BlastError.allocationFailed("--what-if \(part)")
            }
        }
        return whatIf
    }

    static func run(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        guard let out = value("out") else { throw BlastError.allocationFailed("--out folder") }
        let (scene, dx) = try district(args)
        let district = value("district") ?? "district"
        let frames = value("frames").flatMap(Int.init) ?? 200
        let first = value("first").flatMap(Int.init) ?? 0
        let draws = value("draws").flatMap(Int.init) ?? 64
        let within = value("within").flatMap(Float.init) ?? 1500
        let keep = value("keep").flatMap(Double.init) ?? 0.1
        let seed = value("seed").flatMap(UInt64.init) ?? 1
        // `--as-built`: every building as its map makes it, not drawn (the first networks' data).
        let asBuilt = args.contains("--as-built")
        let terms = try SurrogateBench.termSet(args)
        let coefficients = terms.coefficients
        let roofCoefficients = FacadeLoadSurrogate.Coefficients.roofs
        let laidOut = FacadeLoadSurrogate.Prepared(
            scene: scene, cellSize: dx, incidence: SurrogateBench.incidence(args))
        let objects = scene.envelopeObjects
        let mapped = Dictionary(
            uniqueKeysWithValues: objects.map { ($0.id, scene.envelopeConstruction(for: $0.id)) })
        print(
            "Prepared \(objects.count) buildings of \(district), \(laidOut.componentCount) components, "
                + "\(Set(mapped.values.map { LiveResponse.constructionFeatures($0) ?? [] }).count) constructions as built"
        )
        let folder = URL(filePath: out)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func handle(_ name: String) throws -> FileHandle {
            let url = folder.appending(path: name)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let h = try FileHandle(forWritingTo: url)
            h.seekToEndOfFile()
            return h
        }
        var files: [String: FileHandle] = [:]
        for unit in ["component", "side", "building"] {
            for part in ["x", "y", "w"] { files["\(unit)-\(part)"] = try handle("\(unit)-\(part).f32") }
            files["\(unit)-frame"] = try handle("\(unit)-frame.i32")
        }
        func write(_ unit: String, _ x: [Float], _ y: [Float], _ w: [Float], frame: Int) {
            files["\(unit)-x"]!.write(x.withUnsafeBufferPointer { Data(buffer: $0) })
            files["\(unit)-y"]!.write(y.withUnsafeBufferPointer { Data(buffer: $0) })
            files["\(unit)-w"]!.write(w.withUnsafeBufferPointer { Data(buffer: $0) })
            let frames = [Int32](repeating: Int32(frame), count: w.count)
            files["\(unit)-frame"]!.write(frames.withUnsafeBufferPointer { Data(buffer: $0) })
        }
        let metaURL = folder.appending(path: "meta.json")
        var meta =
            (try? JSONDecoder().decode(Meta.self, from: Data(contentsOf: metaURL)))
            ?? Meta(
                district: district, componentWidth: 0, sideWidth: 0, buildingWidth: 0,
                componentOutputs: ["level", "glassBroken"],
                sideOutputs: [
                    "someBroken", "blownOut", "fractionBroken", "thrownPast3b", "openingsBlownOut",
                ],
                buildingOutputs: ["wallsModerate", "wallsHeavy", "roofModerate"], draws: draws, cellSize: dx)
        guard meta.district == district else {
            throw BlastError.allocationFailed("a folder of another district's data: \(out)")
        }

        let home = scene.charge.position
        let judged = [SIMD2(home.x, home.y), SIMD2(home.x + 60, home.y)]
        let withins = [1.0, 1.25, 1.5, 2.0, 3.0]
        func uniform(_ frame: Int, _ stream: UInt64, _ k: UInt64 = 0) -> Double {
            // SplitMix64 of the seed, stream, frame and item.
            var z =
                seed &* 0x9E37_79B9_7F4A_7C15 ^ stream &* 0xBF58_476D_1CE4_E5B9 ^ UInt64(frame)
                &* 0x94D0_49BB_1331_11EB ^ k &* 0xD6E8_FEB8_6659_FD93
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) * 0x1p-53
        }
        // The SDOF responses and the panes' (a full look's table), kept for some frames.
        var memo = SDOFResponseMemo()
        var responses = FacadeLoadSurrogate.GlassResponses()
        for frame in first..<(first + frames) {
            if (frame - first) % 1 == 0 {
                memo = SDOFResponseMemo()
                responses = FacadeLoadSurrogate.GlassResponses()
            }
            let clock = ContinuousClock.now
            // Each building built as drawn for this frame (`LiveResponse.drawn`), unless as built.
            // `--recipes`: the ways of building each frame draws, every building one of them (a fifth
            // as built).
            var built = scene
            var constructions = mapped
            if !asBuilt {
                let count = value("recipes").flatMap(Int.init) ?? 4
                let recipes = (0..<count).map { r in
                    LiveResponse.recipe { uniform(frame, 1000 + 20 * UInt64(r) + $0) }
                }
                for object in objects {
                    let pick = uniform(frame, 900, object.drawKey)
                    guard pick >= 0.2 else { continue }
                    let recipe = recipes[min(Int((pick - 0.2) / 0.8 * Double(count)), count - 1)]
                    var c = recipe.applied(to: mapped[object.id]!)
                    c.objectID = object.id
                    constructions[object.id] = c
                }
                built.envelopeConstructions = objects.map { constructions[$0.id]! }
            }
            let prepared = laidOut.withConstructions(of: built)
            // A charge on the open ground, away from the places the preview is judged at.
            var charge = home
            var tries: UInt64 = 0
            repeat {
                let r = within * Float(uniform(frame, 1, tries)).squareRoot()
                let angle = 2 * Float.pi * Float(uniform(frame, 2, tries))
                charge = home
                charge.x += r * cos(angle)
                charge.y += r * sin(angle)
                tries += 1
            } while tries < 1000
                && (prepared.raster.isSolid(charge)
                    || judged.contains { simd_distance($0, SIMD2(charge.x, charge.y)) < 100 })
            let mass = exp(log(100.0) + uniform(frame, 3) * (log(5e6) - log(100.0)))
            let factor = withins[min(Int(uniform(frame, 4) * 5), 4)]
            var uncertainty = FacadeLoadSurrogate.Uncertainty(
                yieldLogSD: log(factor) / 1.645, loadScatter: terms.loadScatter, samples: draws,
                seed: seed &+ UInt64(frame))
            uncertainty.stratified = true

            var (estimate, sides) = prepared.preview(charge: charge, mass: mass, coefficients: coefficients)
            // In half the frames, each building's peaks raised or lowered by a factor of its own (up to
            // ×2 either way), so that its peaks and impulses are seen apart from how a charge's go
            // together.
            let boosted = uniform(frame, 5) < 0.5
            if boosted {
                func boost(_ owner: Int) -> Double {
                    exp(log(2.0) * (2 * uniform(frame, 6, estimate.ownerKeys[owner]) - 1))
                }
                var ownerOf: [UUID: Int] = [:]
                for (k, n) in estimate.owners.enumerated() {
                    ownerOf[estimate.components[k].owner] = n
                    estimate.features[k].learnedPeakFactor *= boost(n)
                    let terms = estimate.components[k].kind == .roof ? roofCoefficients : coefficients
                    let p = FacadeLoadSurrogate.predict(
                        estimate.features[k], mass: mass, cellSize: Double(dx), coefficients: terms)
                    estimate.predictions[k] = p
                    estimate.loads[k] = FacadeLoadSurrogate.load(estimate.components[k], p, binS: 0.7e-3)
                }
                for s in sides.indices {
                    guard let n = ownerOf[sides[s].owner] else { continue }
                    for t in sides[s].strips.indices {
                        sides[s].strips[t].features.learnedPeakFactor *= boost(n)
                    }
                }
            }
            meta.frames.append([
                Double(frame), Double(charge.x), Double(charge.y), mass, factor, boosted ? 1 : 0,
            ])
            let batch = LiveResponse.batch(
                estimate: estimate, sides: sides, mass: mass, cellSize: dx, coefficients: coefficients,
                roofCoefficients: roofCoefficients, uncertainty: uncertainty,
                construction: { constructions[$0].flatMap(LiveResponse.constructionFeatures) },
                glazing: { LiveResponse.glazingFeatures($0.mix) })
            guard batch.unknown == 0 else {
                print("Frame \(frame): \(batch.unknown) buildings or sides the networks cannot read; skipped")
                continue
            }
            meta.componentWidth = batch.componentWidth
            meta.sideWidth = batch.sideWidth
            meta.buildingWidth = batch.buildingWidth
            let inputsS = DistrictBenchmark.seconds(clock)

            // The components' answers: each one's level and whether its glass breaks, at the yield.
            var levels = [Float](repeating: 0, count: estimate.loads.count)
            var broken = [Float](repeating: 0, count: estimate.loads.count)
            let tops = Dictionary(grouping: estimate.loads.indices, by: { estimate.loads[$0].owner })
                .mapValues {
                    (
                        $0.map { Double(estimate.loads[$0].region.max.z) }.max()!,
                        $0.map { Double(estimate.loads[$0].region.min.z) }.min()!
                    )
                }
            levels.withUnsafeMutableBufferPointer { levelOut in
                broken.withUnsafeMutableBufferPointer { brokenOut in
                    _ = SDOFResponseMemo.remembering(in: memo) {
                        concurrently(iterations: estimate.loads.count) { k in
                            let load = estimate.loads[k]
                            let construction = constructions[load.owner]!
                            let (top, base) = tops[load.owner]!
                            let damage = EnvelopeDamageAssessment.assess(
                                load, construction: construction, buildingTop: top, buildingBase: base)
                            if let damage {
                                if damage.material.isGlass {
                                    brokenOut[k] = (damage.crackedAtS ?? damage.failedAtS) != nil ? 1 : 0
                                } else {
                                    levelOut[k] = Float(damage.levels.upperBound.rawValue)
                                }
                            }
                            if let pane = EnvelopeDamageAssessment.facadePane(
                                load,
                                construction: construction.facade(axis: load.axis, outward: load.outward)),
                                (pane.crackedAtS ?? pane.failedAtS) != nil
                            {
                                brokenOut[k] = 1
                            }
                        }
                    }
                }
            }
            let damageS = DistrictBenchmark.seconds(clock) - inputsS

            // `--no-glass`: the components' and the walls' answers alone, the glass's draws (most of a frame's
            // time) left out.
            let withGlass = !args.contains("--no-glass")
            let glass =
                withGlass
                ? FacadeLoadSurrogate.glassProbabilities(
                    sides: sides, mass: mass, cellSize: dx, uncertainty: uncertainty,
                    coefficients: coefficients,
                    responses: responses
                ).sides : []
            let glassS = DistrictBenchmark.seconds(clock) - inputsS - damageS
            let ((structure, _), _) = SDOFResponseMemo.remembering(in: memo) {
                FacadeLoadSurrogate.structureProbabilities(
                    estimate, mass: mass, cellSize: dx, constructions: { constructions[$0]! },
                    uncertainty: uncertainty,
                    coefficients: coefficients)
            }
            let structureS = DistrictBenchmark.seconds(clock) - inputsS - damageS - glassS

            // Rows, the dull ones thinned.
            func kept(_ dull: Bool, _ k: Int, _ stream: UInt64) -> Float? {
                guard dull else { return 1 }
                return uniform(frame, stream, UInt64(k)) < keep ? Float(1 / keep) : nil
            }
            var x: [Float] = []
            var y: [Float] = []
            var w: [Float] = []
            let cw = batch.componentWidth
            for k in 0..<batch.componentCount {
                // Dull: no damage and no glass broken.
                let dull = levels[k] == 0 && broken[k] == 0
                // A third of the rest kept, all those damaged.
                guard let thinned = kept(dull, k, 10),
                    levels[k] > 0 || uniform(frame, 16, UInt64(k)) < 1.0 / 3
                else { continue }
                let weight = levels[k] > 0 ? thinned : 3 * thinned
                x += batch.components[(k * cw)..<((k + 1) * cw)]
                y += [levels[k], broken[k]]
                w.append(weight)
            }
            // Each component again under a load of its own (its peak and impulse each moved up to 0.8
            // of a decade), its level and glass judged as above: the space round each one's own.
            var extra = [
                (row: Int, prediction: FacadeLoadSurrogate.Prediction, load: EnvelopeComponentLoad)
            ]()
            for k in 0..<batch.componentCount where uniform(frame, 13, UInt64(k)) < 0.5 {
                var p = estimate.predictions[k]
                p.peakPa *= pow(10, 1.6 * uniform(frame, 14, UInt64(k)) - 0.8)
                p.impulsePaS *= pow(10, 1.6 * uniform(frame, 15, UInt64(k)) - 0.8)
                extra.append((k, p, FacadeLoadSurrogate.load(estimate.components[k], p, binS: 0.7e-3)))
            }
            var extraLevels = [Float](repeating: 0, count: extra.count)
            var extraBroken = [Float](repeating: 0, count: extra.count)
            extraLevels.withUnsafeMutableBufferPointer { levelOut in
                extraBroken.withUnsafeMutableBufferPointer { brokenOut in
                    _ = SDOFResponseMemo.remembering(in: memo) {
                        concurrently(iterations: extra.count) { e in
                            let load = extra[e].load
                            let construction = constructions[load.owner]!
                            let (top, base) = tops[load.owner]!
                            if let damage = EnvelopeDamageAssessment.assess(
                                load, construction: construction, buildingTop: top, buildingBase: base)
                            {
                                if damage.material.isGlass {
                                    brokenOut[e] = (damage.crackedAtS ?? damage.failedAtS) != nil ? 1 : 0
                                } else {
                                    levelOut[e] = Float(damage.levels.upperBound.rawValue)
                                }
                            }
                            if let pane = EnvelopeDamageAssessment.facadePane(
                                load,
                                construction: construction.facade(axis: load.axis, outward: load.outward)),
                                (pane.crackedAtS ?? pane.failedAtS) != nil
                            {
                                brokenOut[e] = 1
                            }
                        }
                    }
                }
            }
            for (e, item) in extra.enumerated() {
                var row = Array(batch.components[(item.row * cw)..<((item.row + 1) * cw)])
                row[0] = Float(log10(max(item.prediction.peakPa, 1e-6)))
                row[1] = Float(log10(max(item.prediction.impulsePaS, 1e-6)))
                x += row
                y += [extraLevels[e], extraBroken[e]]
                w.append(1)
            }
            write("component", x, y, w, frame: frame)
            let componentRows = w.count
            (x, y, w) = ([], [], [])
            let sw = batch.sideWidth
            for (s, side) in glass.enumerated() {
                let answers = [
                    side.someBroken, side.blownOut, side.fractionBroken, side.thrownPast3b,
                    side.openingsBlownOut,
                ]
                let dull = answers.allSatisfy { $0 < 0.01 } || answers.allSatisfy { $0 > 0.99 }
                // A quarter of the rest kept.
                guard let thinned = kept(dull, s, 11), uniform(frame, 17, UInt64(s)) < 0.25 else { continue }
                let weight = 4 * thinned
                x += batch.sides[(s * sw)..<((s + 1) * sw)]
                y += answers.map(Float.init)
                w.append(weight)
            }
            if withGlass { write("side", x, y, w, frame: frame) }
            let sideRows = w.count
            (x, y, w) = ([], [], [])
            let chances = Dictionary(uniqueKeysWithValues: structure.map { ($0.owner, $0) })
            let bw = batch.buildingWidth
            for (b, owner) in batch.buildingOwners.enumerated() {
                let c = chances[owner] ?? FacadeLoadSurrogate.StructureChance(owner: owner)
                let answers = [c.wallsModerate, c.wallsHeavy, c.roofModerate]
                let dull = answers.allSatisfy { $0 < 1e-6 } || answers.allSatisfy { $0 > 1 - 1e-6 }
                guard let weight = kept(dull, b, 12) else { continue }
                x += batch.buildings[(b * bw)..<((b + 1) * bw)]
                y += answers.map(Float.init)
                w.append(weight)
            }
            write("building", x, y, w, frame: frame)
            try JSONEncoder().encode(meta).write(to: metaURL)
            print(
                String(
                    format:
                        "Frame %d: charge (%.0f, %.0f), %.1f t, yield within ×%.2f; rows %d components, %d sides, %d buildings; inputs %.2f s, damage %.2f s, glass %.2f s, walls %.2f s",
                    frame, charge.x, charge.y, mass / 1000, factor, componentRows, sideRows, w.count, inputsS,
                    damageS, glassS, structureS))
        }
        for h in files.values { try h.close() }
    }
}
