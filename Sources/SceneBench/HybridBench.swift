import BlastCore
import Foundation
import simd

/// A district's near field run in the air and its far field carried by the façade load surrogate
/// (Horizons 3, "City scale in minutes"), against the full run.
///
/// `scenebench hybrid-judge <district-scene's inputs> --radius 2500 --loads full-loads
/// --near-loads near-loads --near-radius 1320 [--handover 1000] [--seed-from 800] [--trend-from 500] [--inside 0.85]
/// [--full-report full/comparison.json] [--near-report near/comparison.json] [--out judged.json]`.
///
/// The near run is the same district on a box reaching the hand-over and its open faces' clearance
/// beyond (`--near-radius`, a multiple of the cells, so that its cells are the full run's), run
/// until the blast has passed the hand-over. Inside the hand-over its strips' histories are the
/// hybrid's. Beyond it each strip takes the surrogate's pulse, its peak and impulse scaled so that
/// the surrogate meets the near run where they overlap: by the median, over the near run's strips
/// between `--seed-from` and the hand-over, of the near run's peak (and first impulse) over the
/// surrogate's. Arrivals beyond take Kingery–Bulmash's, scaled by the median of the near run's
/// simulated over Kingery–Bulmash's at its observers from 500 m to the hand-over.
enum HybridBench {
    struct Band: Codable {
        var from: Double
        var to: Double
        var sides: Int
        var strips: Int
        /// The hybrid's peak and impulse over the full run's, median and log standard deviation.
        var peakRatio: Double
        var peakLogSD: Double
        var impulseRatio: Double
        var impulseLogSD: Double
        /// Sides with some glass broken, and blown out: the full run, the hybrid, the surrogate
        /// unseeded, GEER.
        var runAny: Double
        var hybridAny: Double
        var surrogateAny: Double
        var geerAny: Double?
        var runBlown: Double
        var hybridBlown: Double
        var surrogateBlown: Double
        var geerBlown: Double?
        /// Sides whose glass state the hybrid gives as the run does, and within one.
        var glassExact: Double
        var glassWithinOne: Double
    }

    struct ArrivalRow: Codable {
        var name: String
        var distanceM: Double
        var observedS: Double
        var fullS: Double?
        var hybridS: Double
    }

    struct Judged: Codable {
        var massKg: Double
        var handoverM: Double
        var farField: HybridFarField
        var bands: [Band]
        var arrivals: [ArrivalRow]
        var nearWallS: Double?
        var fullWallS: Double?
        var farFieldS: Double
    }

    static func judge(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        guard let fullLoads = value("loads"), let nearLoads = value("near-loads") else {
            throw BlastError.allocationFailed("--loads full-loads --near-loads near-loads")
        }
        let handover = value("handover").flatMap(Double.init) ?? 1000
        let seedFrom = value("seed-from").flatMap(Double.init) ?? 0.8 * handover
        let share = Float(value("inside").flatMap(Double.init) ?? 0.85)
        let full = try SurrogateBench.Reference(
            args, loads: fullLoads, radius: Float(value("radius").flatMap(Double.init) ?? 2500))
        let near = try SurrogateBench.Reference(
            args, loads: nearLoads, radius: Float(value("near-radius").flatMap(Double.init) ?? 1320))
        let scene = full.scene
        let objects = full.objects
        let mass = Double(scene.charge.mass)
        let charge = scene.charge.position
        let cell = Double(full.cellSize)

        // The near run's strips, by their box from the charge.
        func key(_ reference: SurrogateBench.Reference, _ component: EnvelopeComponent) -> [Int32] {
            let c = reference.scene.charge.position
            return SurrogateBench.key(
                Box(min: component.region.min - c, max: component.region.max - c), component.axis,
                component.outward)
        }
        var nearOf: [[Int32]: Int] = [:]
        for (m, strip) in near.strips.enumerated() { nearOf[key(near, strip.component)] = m }
        func distance(_ component: EnvelopeComponent) -> Double {
            let p = FacadeLoadSurrogate.outerFace(component).centre
            return Double(simd_length(SIMD2(p.x - charge.x, p.y - charge.y)))
        }

        // Each full strip inside the fair part of the full run: its surrogate prediction and, inside
        // the hand-over, the near run's history.
        let kept = full.strips.indices.filter {
            full.inside(FacadeLoadSurrogate.outerFace(full.strips[$0].component).centre, share: share)
        }
        let clock = ContinuousClock.now
        var computed = [FacadeLoadSurrogate.Prediction?](repeating: nil, count: kept.count)
        computed.withUnsafeMutableBufferPointer { out in
            SurrogateBench.concurrentlyEach(kept.count) { m in
                let (_, n, component) = full.strips[kept[m]]
                let f = FacadeLoadSurrogate.features(component, owner: n, charge: charge, raster: full.raster)
                out[m] = FacadeLoadSurrogate.predict(f, mass: mass, cellSize: cell)
            }
        }
        let predictions = computed.map { $0! }
        let farFieldS = DistrictBenchmark.seconds(clock)

        // The far field: the near run over the surrogate where both hold, inside the hand-over.
        let trendFrom = value("trend-from").flatMap(Double.init)
        var samples: [HybridFarField.Sample] = []
        for (m, i) in kept.enumerated() {
            let component = full.strips[i].component
            let d = distance(component)
            guard d >= min(seedFrom, trendFrom ?? seedFrom), d < handover,
                let j = nearOf[key(full, component)]
            else { continue }
            let strip = near.index.strips[near.strips[j].saved]
            let net = near.net(near.strips[j].saved)
            samples.append(
                HybridFarField.Sample(
                    distanceM: d, nearPeakPa: net.max() ?? 0,
                    nearImpulsePaS: SurrogateBench.firstImpulse(net, binS: strip.binS),
                    predicted: predictions[m]))
        }
        func report(_ path: String?) throws -> DistrictComparison.Report? {
            try path.map {
                try JSONDecoder().decode(
                    DistrictComparison.Report.self, from: Data(contentsOf: URL(filePath: $0)))
            }
        }
        let fullReport = try report(value("full-report"))
        let nearReport = try report(value("near-report"))
        let far = HybridFarField.fit(
            handoverM: handover, seedFromM: seedFrom, trendFromM: trendFrom, samples: samples,
            arrivals: (nearReport?.arrivals ?? []).compactMap { a in
                a.simulatedS.flatMap { s in a.kingeryBulmashS.map { (s, $0, a.distanceM) } }
            })
        print(
            String(
                format:
                    "Far field from %d strips at %.0f–%.0f m: peak ×%.3f, impulse ×%.3f; slopes %.3f, %.3f per log distance; arrivals ×%.3f",
                far.seedStrips, seedFrom, handover, far.peak, far.impulse, far.peakSlope, far.impulseSlope,
                far.arrival))

        // Every kept strip judged three ways: the full run, the hybrid, the surrogate unseeded.
        let mixes = Dictionary(
            uniqueKeysWithValues: [GlazingMix.olderLowRise, .apartments, .commercial, .industrial].map {
                ($0.name, $0)
            })
        struct Outcome {
            var run: (glass: GlazingBreakage, peak: Double, impulse: Double)
            var hybrid: (glass: GlazingBreakage, peak: Double, impulse: Double)
            var surrogate: GlazingBreakage
            var distance: Double
            var side: [Int]
        }
        var outcomes = [Outcome?](repeating: nil, count: kept.count)
        outcomes.withUnsafeMutableBufferPointer { out in
            SurrogateBench.concurrentlyEach(kept.count) { m in
                let (s, n, component) = full.strips[kept[m]]
                let strip = full.index.strips[s]
                let id = objects[n].id
                let construction = scene.envelopeConstruction(for: id)
                let mix =
                    mixes[full.index.buildings[strip.building].mix] ?? construction.glazing ?? .apartments
                func judged(_ net: [Double], binS: Double) -> (GlazingBreakage, Double, Double) {
                    (
                        mix.breakage(netPa: net, binS: binS, areaM2: strip.areaM2), net.max() ?? 0,
                        SurrogateBench.firstImpulse(net, binS: binS)
                    )
                }
                let d = distance(component)
                let run = judged(full.net(s), binS: strip.binS)
                var prediction = predictions[m]
                let surrogate = FacadeLoadSurrogate.load(component, prediction, binS: strip.binS)
                let hybrid: (GlazingBreakage, Double, Double)
                if d < handover {
                    guard let j = nearOf[key(full, component)] else { return }
                    let nearStrip = near.index.strips[near.strips[j].saved]
                    hybrid = judged(near.net(near.strips[j].saved), binS: nearStrip.binS)
                } else {
                    prediction = far.apply(prediction, distanceM: d)
                    hybrid = judged(
                        FacadeLoadSurrogate.load(component, prediction, binS: strip.binS).netPa,
                        binS: strip.binS)
                }
                out[m] = Outcome(
                    run: run, hybrid: hybrid,
                    surrogate: judged(surrogate.netPa, binS: strip.binS).0, distance: d,
                    side: [n, strip.axis, strip.outward])
            }
        }
        let all = outcomes.compactMap { $0 }
        print("Judged \(all.count) of \(kept.count) strips (inside the hand-over, those the near run holds)")

        // By distance band: loads by strip, glass by building side.
        let edges: [Double] = [0, 500, 750, 1000, 1250, 1500, 1750, 2000, 2500, 3000]
        let geer = Dictionary(uniqueKeysWithValues: DistrictGlass.geer.map { ($0.from, $0) })
        var bands: [Band] = []
        for (lo, hi) in zip(edges, edges.dropFirst()) {
            let members = all.filter { $0.distance >= lo && $0.distance < hi }
            guard !members.isEmpty else { continue }
            func stats(_ pairs: [(Double, Double)]) -> (Double, Double) {
                let logs = pairs.compactMap { $0.0 > 0 && $0.1 > 0 ? log($0.1 / $0.0) : nil }
                guard !logs.isEmpty else { return (0, 0) }
                let mean = logs.reduce(0, +) / Double(logs.count)
                let sd = (logs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(logs.count)).squareRoot()
                return (exp(logs.sorted()[logs.count / 2]), sd)
            }
            let (peak, peakSD) = stats(members.map { ($0.run.peak, $0.hybrid.peak) })
            let (impulse, impulseSD) = stats(members.map { ($0.run.impulse, $0.hybrid.impulse) })
            let sides = Dictionary(grouping: members, by: \.side)
            var counts = [Double](repeating: 0, count: 6)
            var agreement = SurrogateBench.Agreement(states: 3)
            for (_, list) in sides {
                let run = list.reduce(GlazingBreakage()) { $0 + $1.run.glass }
                let hybrid = list.reduce(GlazingBreakage()) { $0 + $1.hybrid.glass }
                let surrogate = list.reduce(GlazingBreakage()) { $0 + $1.surrogate }
                counts[0] += run.anyBroken
                counts[1] += hybrid.anyBroken
                counts[2] += surrogate.anyBroken
                counts[3] += run.fraction >= DistrictGlass.blownOutFraction ? 1 : 0
                counts[4] += hybrid.fraction >= DistrictGlass.blownOutFraction ? 1 : 0
                counts[5] += surrogate.fraction >= DistrictGlass.blownOutFraction ? 1 : 0
                agreement.add(SurrogateBench.glassState(run), SurrogateBench.glassState(hybrid))
            }
            agreement.finish()
            let k = Double(max(sides.count, 1))
            let g = geer[lo]
            bands.append(
                Band(
                    from: lo, to: hi, sides: sides.count, strips: members.count, peakRatio: peak,
                    peakLogSD: peakSD,
                    impulseRatio: impulse, impulseLogSD: impulseSD, runAny: counts[0] / k,
                    hybridAny: counts[1] / k,
                    surrogateAny: counts[2] / k, geerAny: g?.damaged, runBlown: counts[3] / k,
                    hybridBlown: counts[4] / k, surrogateBlown: counts[5] / k, geerBlown: g?.blownOut,
                    glassExact: agreement.exact, glassWithinOne: agreement.withinOne))
        }
        print(
            "Band: strips, hybrid over run peak / impulse (median, log sd); sides some broken run / hybrid / surrogate | GEER;"
                + " blown out run / hybrid / surrogate | GEER; glass state exact / within one")
        for b in bands {
            print(
                String(
                    format:
                        "  %4.0f–%4.0f m %6d  %.2f (%.2f) / %.2f (%.2f);  %.2f / %.2f / %.2f | %@;  %.2f / %.2f / %.2f | %@;  %.2f / %.2f",
                    b.from, b.to, b.strips, b.peakRatio, b.peakLogSD, b.impulseRatio, b.impulseLogSD,
                    b.runAny,
                    b.hybridAny, b.surrogateAny, b.geerAny.map { String(format: "%.2f", $0) } ?? "–",
                    b.runBlown,
                    b.hybridBlown, b.surrogateBlown, b.geerBlown.map { String(format: "%.2f", $0) } ?? "–",
                    b.glassExact, b.glassWithinOne))
        }

        // Arrivals beyond the hand-over: Kingery–Bulmash's, scaled to the near run's.
        var arrivals: [ArrivalRow] = []
        for a in fullReport?.arrivals ?? [] where a.distanceM >= handover {
            guard let k = a.kingeryBulmashS else { continue }
            arrivals.append(
                ArrivalRow(
                    name: a.name, distanceM: a.distanceM, observedS: a.observedS, fullS: a.simulatedS,
                    hybridS: k * far.arrival))
        }
        print(
            String(
                format: "Arrivals beyond %.0f m (Kingery–Bulmash ×%.3f):", handover, far.arrival))
        for a in arrivals {
            print(
                String(
                    format: "  %@ %5.0f m  observed %.3f s, full %@, hybrid %.3f s", a.name as NSString,
                    a.distanceM,
                    a.observedS, a.fullS.map { String(format: "%.3f s", $0) } ?? "–", a.hybridS))
        }
        print(
            String(
                format: "Time: near run %@, far field's loads %.1f s; the full run %@",
                nearReport.map { String(format: "%.0f s", $0.wallS) } ?? "–", farFieldS,
                fullReport.map { String(format: "%.0f s", $0.wallS) } ?? "–"))
        let result = Judged(
            massKg: mass, handoverM: handover, farField: far, bands: bands, arrivals: arrivals,
            nearWallS: nearReport?.wallS,
            fullWallS: fullReport?.wallS, farFieldS: farFieldS)
        if let out = value("out") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: URL(filePath: out))
        }
    }

    struct District: Codable {
        var method: String
        var standing: [String]
        var massKg: Double
        var radiusM: Float
        var farField: HybridFarField
        var nearComponents: Int
        var farComponents: Int
        var farFieldS: Double
        var damageS: Double
        var nearWallS: Double?
        var bands: [DistrictBand]
        var buildings: [EnvelopeBuildingDamage]
    }

    struct DistrictBand: Codable {
        var from: Double
        var to: Double
        var sides: Int
        var sidesAny: Double
        var sidesBlown: Double
        var geerAny: Double
        var geerBlown: Double
    }

    /// `scenebench district-hybrid <district-scene's inputs> --radius 2500 --near-loads near-loads
    /// --near-radius 1320 [--near-report near/comparison.json] [--handover 1000] [--seed-from 800]
    /// [--trend-from 500] [--out district.json]`: a district's envelope damage from its near run
    /// (`district-compare --save-loads` on a box reaching the hand-over and its faces' clearance)
    /// and the far field beyond (`HybridFarField`), with no full run: each façade strip inside the
    /// hand-over on the near run's history, each beyond it, and every other component, on the
    /// surrogate's pulse (beyond the hand-over, carried as the far field).
    static func district(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        guard let nearLoads = value("near-loads") else {
            throw BlastError.allocationFailed("--near-loads folder")
        }
        let handover = value("handover").flatMap(Double.init) ?? 1000
        let seedFrom = value("seed-from").flatMap(Double.init) ?? 0.8 * handover
        let trendFrom = value("trend-from").flatMap(Double.init) ?? 0.5 * handover
        let radius = Float(value("radius").flatMap(Double.init) ?? 2500)
        let inputs = try DistrictInputs.read(args)
        let (scene, _) = try inputs.scene(radius: radius)
        let near = try SurrogateBench.Reference(
            args, loads: nearLoads, radius: Float(value("near-radius").flatMap(Double.init) ?? 1320))
        let charge = scene.charge.position
        let mass = Double(scene.charge.mass)
        func key(_ origin: SIMD3<Float>, _ component: EnvelopeComponent) -> [Int32] {
            SurrogateBench.key(
                Box(min: component.region.min - origin, max: component.region.max - origin), component.axis,
                component.outward)
        }
        var nearOf: [[Int32]: Int] = [:]
        for (m, strip) in near.strips.enumerated() {
            nearOf[key(near.scene.charge.position, strip.component)] = m
        }

        let clock = ContinuousClock.now
        var estimate = FacadeLoadSurrogate.estimate(scene: scene, cellSize: inputs.cellSize)
        let distances = estimate.features.map(\.distanceM)
        // The near run's strips against the surrogate, inside the hand-over.
        var samples: [HybridFarField.Sample] = []
        var nearOfComponent = [Int?](repeating: nil, count: estimate.components.count)
        for (n, component) in estimate.components.enumerated() where component.kind == .facade {
            guard distances[n] < handover, let j = nearOf[key(charge, component)] else { continue }
            nearOfComponent[n] = j
            guard distances[n] >= min(seedFrom, trendFrom) else { continue }
            let strip = near.index.strips[near.strips[j].saved]
            let net = near.net(near.strips[j].saved)
            samples.append(
                HybridFarField.Sample(
                    distanceM: distances[n], nearPeakPa: net.max() ?? 0,
                    nearImpulsePaS: SurrogateBench.firstImpulse(net, binS: strip.binS),
                    predicted: estimate.predictions[n]))
        }
        let nearReport = try value("near-report").map {
            try JSONDecoder().decode(
                DistrictComparison.Report.self, from: Data(contentsOf: URL(filePath: $0)))
        }
        let far = HybridFarField.fit(
            handoverM: handover, seedFromM: seedFrom, trendFromM: trendFrom, samples: samples,
            arrivals: (nearReport?.arrivals ?? []).compactMap { a in
                a.simulatedS.flatMap { s in a.kingeryBulmashS.map { (s, $0, a.distanceM) } }
            })
        // Each component's load: the near run's history, or the far field's pulse.
        var nearCount = 0
        var farCount = 0
        for n in estimate.components.indices {
            let component = estimate.components[n]
            if let j = nearOfComponent[n] {
                let strip = near.index.strips[near.strips[j].saved]
                let net = near.net(near.strips[j].saved)
                estimate.loads[n] = EnvelopeComponentLoad(
                    id: component.id, owner: component.owner, kind: .facade, region: component.region,
                    axis: component.axis, binS: strip.binS, outerPa: net,
                    innerPa: [Double](repeating: 0, count: net.count), supportEdges: component.supportEdges,
                    outward: component.outward)
                nearCount += 1
            } else if distances[n] >= handover {
                estimate.loads[n] = FacadeLoadSurrogate.load(
                    component, far.apply(estimate.predictions[n], distanceM: distances[n]),
                    binS: estimate.loads[n].binS)
                farCount += 1
            }
        }
        let farFieldS = DistrictBenchmark.seconds(clock)
        let (buildings, damageS, _) = FacadeLoadSurrogate.damage(
            estimate, constructions: { scene.envelopeConstruction(for: $0) })

        // Glass by building side in GEER's bands.
        let distanceOf = Dictionary(
            uniqueKeysWithValues: scene.envelopeObjects.map { object -> (UUID, Double) in
                let (low, high) = SurrogateBench.bounds(object)
                let c = 0.5 * (low + high)
                return (object.id, Double(simd_length(SIMD2(c.x - charge.x, c.y - charge.y))))
            })
        var bands: [DistrictBand] = []
        for band in DistrictGlass.geer {
            let sides = buildings.filter {
                (distanceOf[$0.id] ?? 0) >= band.from && (distanceOf[$0.id] ?? 0) < band.to
            }
            .flatMap { $0.facadeGlass ?? [] }.filter { $0.axis < 2 }
            guard !sides.isEmpty else { continue }
            let k = Double(sides.count)
            bands.append(
                DistrictBand(
                    from: band.from, to: band.to, sides: sides.count,
                    sidesAny: sides.reduce(0) { $0 + $1.glass.anyBroken } / k,
                    sidesBlown: Double(
                        sides.filter { $0.glass.fraction >= DistrictGlass.blownOutFraction }.count) / k,
                    geerAny: band.damaged, geerBlown: band.blownOut))
        }
        print(
            String(
                format:
                    "Near field: %d façade strips from the near run (%@); far field: %d components beyond %.0f m (peak ×%.3f, impulse ×%.3f, slopes %.3f, %.3f); loads %.1f s, damage %.1f s",
                nearCount, nearReport.map { String(format: "%.0f s", $0.wallS) } ?? "–", farCount, handover,
                far.peak,
                far.impulse, far.peakSlope, far.impulseSlope, farFieldS, damageS))
        print("Sides with some glass broken | GEER W1+; blown out | GEER W3:")
        for b in bands {
            print(
                String(
                    format: "  %4.0f–%4.0f m  %.2f | %.2f   %.2f | %.2f", b.from, b.to, b.sidesAny, b.geerAny,
                    b.sidesBlown,
                    b.geerBlown))
        }
        if let out = value("out") {
            let result = District(
                method: HybridFarField.method, standing: HybridFarField.standing, massKg: mass,
                radiusM: radius,
                farField: far, nearComponents: nearCount, farComponents: farCount, farFieldS: farFieldS,
                damageS: damageS, nearWallS: nearReport?.wallS, bands: bands, buildings: buildings)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(result).write(to: URL(filePath: out))
        }
    }
}
