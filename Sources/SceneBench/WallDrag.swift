import BlastCore
import Foundation
import simd

/// `scenebench wall-drag <district-scene's inputs> --wall east,north,length,height[,x|y] [--steps
/// 0,5,…] [--agreement 0,20] [--terms set] [--what-if …] [--reference-draws 100] [--engine cpu]`: a
/// barrier wall dragged in front of the charge (emmettl/bombcad-work#117), as the app's what-if puts
/// one: the district laid out once without it, then at each step along the wall's normal its raster
/// laid out again (`Prepared.withBlocks`) and the learned response's preview of the glass and the
/// people (as the app's, 40 draws of the assumptions), each frame timed. With `--agreement`, at those
/// steps, the preview against the full estimate (`--reference-draws` draws) with the wall, and the
/// wall's own effect (with it against without it) the preview's against the full estimate's.
enum WallDrag {
    static func run(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        let (district, dx) = try ResponseData.district(args)
        let whatIf = try ResponseData.whatIf(args)
        let scene = whatIf.applied(to: district)
        let mass = Double(scene.charge.mass)
        let terms = try SurrogateBench.termSet(args)
        let charge = scene.charge.position
        guard let spec = value("wall")?.split(separator: ","), spec.count >= 4,
            let east = Float(spec[0]), let north = Float(spec[1]), let length = Float(spec[2]),
            let height = Float(spec[3])
        else { throw BlastError.allocationFailed("--wall east,north,length,height[,x|y]") }
        let alongX = spec.count > 4 ? spec[4] == "x" : abs(north) >= abs(east)
        let normal = alongX ? SIMD2<Float>(0, north >= 0 ? 1 : -1) : SIMD2<Float>(east >= 0 ? 1 : -1, 0)
        let steps = (value("steps") ?? "0,5,10,15,20").split(separator: ",").compactMap { Float($0) }
        let judged = (value("agreement") ?? "").split(separator: ",").compactMap { Float($0) }
        let referenceDraws = value("reference-draws").flatMap(Int.init) ?? 100
        func barrier(_ step: Float) -> LiveResponse.WhatIf.Barrier {
            LiveResponse.WhatIf.Barrier(
                centre: SIMD2(charge.x + east, charge.y + north) + step * normal, lengthM: length,
                heightM: height,
                alongX: alongX)
        }
        func walled(_ step: Float) -> Scenario {
            var w = whatIf
            w.barrier = barrier(step)
            return w.applied(to: district)
        }
        print(
            "Terms: \(terms.rawValue); wall \(length) m long, \(height) m tall, along \(alongX ? "x" : "y")")

        let clock = ContinuousClock.now
        let base = FacadeLoadSurrogate.Prepared(
            scene: scene, cellSize: dx, incidence: SurrogateBench.incidence(args)
        ).withFacadeBands(try SurrogateBench.facadeBands(args))
        print(
            String(
                format: "Prepared %d buildings, %d components, in %.2f s", scene.envelopeObjects.count,
                base.componentCount, DistrictBenchmark.seconds(clock)))
        guard let weights = LiveResponse.Weights.builtIn else {
            throw BlastError.allocationFailed("no weights")
        }
        let engine: LiveResponse.Engine =
            value("engine") == "cpu"
            ? LiveResponse.CPUEngine(weights: weights) : try LiveDragGPU(weights: weights)
        let live = LiveResponse.Model(weights: weights, engine: engine)
        print(
            "Live response on the \(engine.label); thrown network: \(weights.header.networks["thrown"] != nil)"
        )
        var preview = FacadeLoadSurrogate.Uncertainty(
            yieldLogSD: log(value("yield-within").flatMap(Double.init) ?? 1.5) / 1.645,
            loadScatter: terms.loadScatter,
            samples: 10)
        preview.stratified = true
        var thrown = OccupantInjury.Assumptions()
        thrown.glass = .thrownGlass

        // The drag: each step a frame, as the app's.
        var frames: [Double] = []
        for step in steps {
            let start = ContinuousClock.now
            let w = walled(step)
            let prepared = base.withBlocks(w.boxes)
            let rasterS = DistrictBenchmark.seconds(start)
            guard
                let (look, stages) = try prepared.livePreview(
                    charge: charge, mass: mass, uncertainty: preview, parts: .glass, terms: terms, model: live
                )
            else { throw BlastError.allocationFailed("the live response does not know this district") }
            let people = OccupantInjury.estimate(
                scene: w, glass: look.glass, structure: [], charge: charge, mass: mass, assumptions: thrown,
                preview: true, draws: 40)
            let total = DistrictBenchmark.seconds(start)
            frames.append(total)
            print(
                String(
                    format:
                        "Wall at %5.1f m: frame %.1f ms (raster %.1f, loads %.1f, inputs %.1f, networks %.1f, answers %.1f, people %.1f ms)",
                    step, total * 1000, rasterS * 1000, stages.loads * 1000, stages.inputs * 1000,
                    stages.networks * 1000, stages.answers * 1000, people.seconds * 1000))
        }
        let later = frames.dropFirst().sorted()
        if !later.isEmpty {
            print(
                String(
                    format: "Frames after the first: median %.1f ms (%.1f–%.1f)",
                    later[later.count / 2] * 1000,
                    later.first! * 1000, later.last! * 1000))
        }

        // Against the full estimate, and the wall's effect.
        guard !judged.isEmpty else { return }
        var full = FacadeLoadSurrogate.Uncertainty(
            yieldLogSD: preview.yieldLogSD, loadScatter: terms.loadScatter, samples: referenceDraws)
        full.stratified = false
        func fullLook(_ s: Scenario, _ prepared: FacadeLoadSurrogate.Prepared)
            -> FacadeLoadSurrogate.Prepared.Look
        {
            prepared.look(
                charge: charge, mass: mass, constructions: { s.envelopeConstruction(for: $0) },
                uncertainty: full,
                terms: terms)
        }
        func liveLook(_ prepared: FacadeLoadSurrogate.Prepared) throws -> FacadeLoadSurrogate.Prepared.Look {
            let made = try prepared.livePreview(
                charge: charge, mass: mass, uncertainty: preview, terms: terms, model: live)
            guard let made else {
                throw BlastError.allocationFailed("the live response does not know this district")
            }
            return made.look
        }
        struct Key: Hashable {
            var owner: UUID
            var axis: Int
            var outward: Int
        }
        func sides(_ look: FacadeLoadSurrogate.Prepared.Look) -> [Key: FacadeLoadSurrogate.SideGlass] {
            Dictionary(
                look.glass.map { (Key(owner: $0.owner, axis: $0.axis, outward: $0.outward), $0) },
                uniquingKeysWith: { a, _ in a })
        }
        func within(_ pairs: [(Double, Double)]) -> String {
            guard !pairs.isEmpty else { return "none" }
            let n = Double(pairs.count)
            let share = Double(pairs.filter { abs($0.0 - $0.1) <= 0.1 }.count) / n
            let bias = pairs.reduce(0) { $0 + $1.0 - $1.1 } / n
            return String(format: "%d, within 0.1 %.1f%%, bias %+.3f", pairs.count, 100 * share, bias)
        }
        func people(_ s: Scenario, _ look: FacadeLoadSurrogate.Prepared.Look, preview: Bool)
            -> OccupantInjury.Estimate
        {
            OccupantInjury.estimate(
                scene: s, glass: look.glass, structure: look.structure, charge: charge, mass: mass,
                assumptions: thrown, preview: preview, draws: preview ? 40 : 200)
        }
        let openFull = fullLook(scene, base)
        let openLive = try liveLook(base)
        let openFullPeople = people(scene, openFull, preview: false)
        let openLivePeople = people(scene, openLive, preview: true)
        for step in judged {
            let w = walled(step)
            let prepared = base.withBlocks(w.boxes)
            let f = fullLook(w, prepared)
            let p = try liveLook(prepared)
            let (fs, ps, ofs, ops) = (sides(f), sides(p), sides(openFull), sides(openLive))
            let matched = ps.compactMap { key, side in fs[key].map { (side, $0) } }
            print(
                String(
                    format: "Wall at %.1f m, the preview against the full estimate (%d draws):", step,
                    referenceDraws))
            print("  glass some broken, sides " + within(matched.map { ($0.0.someBroken, $0.1.someBroken) }))
            print("  glass blown out, sides " + within(matched.map { ($0.0.blownOut, $0.1.blownOut) }))
            print(
                "  glass thrown, hurt zone, sides "
                    + within(
                        matched.compactMap { a, b in
                            a.thrownHurt.flatMap { x in b.thrownHurt.map { (x, $0) } }
                        }))
            let fp = people(w, f, preview: false)
            let pp = people(w, p, preview: true)
            let shares = Dictionary(uniqueKeysWithValues: fp.buildings.map { ($0.owner, $0.share) })
            print(
                "  people's share hurt (glass thrown), buildings "
                    + within(pp.buildings.compactMap { b in shares[b.owner].map { (b.share, $0) } }))
            // The wall's own effect: with it against without it, side by side.
            var effects: [(Double, Double)] = []
            var moved = 0
            for (key, side) in ps {
                guard let a = ofs[key], let b = fs[key], let c = ops[key] else { continue }
                let fullEffect = b.blownOut - a.blownOut
                let liveEffect = side.blownOut - c.blownOut
                if abs(fullEffect) > 0.02 || abs(liveEffect) > 0.02 {
                    effects.append((liveEffect, fullEffect))
                    moved += 1
                }
            }
            print("  the wall's effect on glass blown out, sides it moves by over 0.02 " + within(effects))
            // The buildings it helps most, by the full estimate: their glass blown out and people.
            let names = Dictionary(uniqueKeysWithValues: w.envelopeObjects.map { ($0.id, $0.name) })
            func mean(_ table: [Key: FacadeLoadSurrogate.SideGlass], _ owner: UUID) -> Double {
                let mine = table.filter { $0.key.owner == owner }.map(\.value.blownOut)
                return mine.isEmpty ? 0 : mine.reduce(0, +) / Double(mine.count)
            }
            let owners = Set(fs.keys.map(\.owner))
            let helped = owners.map { ($0, mean(fs, $0) - mean(ofs, $0)) }.sorted { $0.1 < $1.1 }.prefix(5)
            let openShares = Dictionary(
                uniqueKeysWithValues: openFullPeople.buildings.map { ($0.owner, $0.share) })
            let liveShares = Dictionary(uniqueKeysWithValues: pp.buildings.map { ($0.owner, $0.share) })
            let openLiveShares = Dictionary(
                uniqueKeysWithValues: openLivePeople.buildings.map { ($0.owner, $0.share) })
            for (owner, effect) in helped {
                print(
                    String(
                        format:
                            "  helped most: %@, blown out %+.2f full, %+.2f preview; share hurt %.2f → %.2f full, %.2f → %.2f preview",
                        (names[owner] ?? "?") as NSString, effect, mean(ps, owner) - mean(ops, owner),
                        openShares[owner] ?? 0, shares[owner] ?? 0, openLiveShares[owner] ?? 0,
                        liveShares[owner] ?? 0))
            }
            let fullChange = OccupantInjury.compare(fp, against: openFullPeople)?.hurt ?? 0
            let liveChange = OccupantInjury.compare(pp, against: openLivePeople)?.hurt ?? 0
            print(
                String(
                    format: "  people hurt with the wall against without: full %+.1f%%, preview %+.1f%%",
                    100 * fullChange, 100 * liveChange))
        }
    }
}
