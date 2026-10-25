import Foundation
import Synchronization
import simd

extension ChargeInference {
    /// The glass damage seen on a scene's own buildings, as evidence of the charge
    /// (docs/charge-inference.md, "Damage on the scene's own buildings"): each building side whose
    /// glass was seen broken or whole, scored by the façade load surrogate's load on it from a
    /// charge of the mass and at the place being weighed, with the shielding and facing that place
    /// gives it (`FacadeLoadSurrogate`), and its mix's chance that some pane breaks under it.
    ///
    /// A side's features (its distance, facing and what stands between it and the charge) cost a
    /// sight line each, so they are worked out once, for charges on a square grid of places
    /// `spacing` metres apart; at a place between them, each side's log peak and log impulse are
    /// blended from the four nodes round it. The chance that some pane breaks is tabulated for
    /// each mix by the pulse's log peak, log duration and rise, per square metre of façade (its
    /// log chance that no pane breaks grows with its panes), and taken over a log-normal factor on
    /// the load, the surrogate's scatter and the glass's strength together. Like the glass term it
    /// joins (`glassLogLikelihood`), the sides are counted by bands of distance from the charge, a
    /// beta-binomial holding each band's share broken to the model's mean chance there.
    public struct SurrogateDamage: Sendable {
        /// A building side whose glass was seen: its owner's index among the scene's envelope
        /// objects, its façade strips' outer faces taken together, the mix, the façade's area and
        /// whether some pane broke.
        public struct Side: Sendable {
            public var owner: Int
            public var axis: Int
            public var outward: Int
            public var region: Box
            public var mix: GlazingMix
            public var areaM2: Double
            public var damaged: Bool
            /// The side's middle, in the inference's metres (east, north of the reference point).
            public var east: Double
            public var north: Double
        }

        public let sides: [Side]
        /// The grid of charge places, in the inference's metres: its first node and spacing, and
        /// its nodes along each way.
        let origin: SIMD2<Double>
        let spacing: Double
        let columns: Int
        let rows: Int
        /// Each node's sides' features, node after node.
        let features: [CompactFeatures]
        /// The cells the surrogate's loads are for (its cell term), m.
        let cellSize: Double
        let coefficients: FacadeLoadSurrogate.Coefficients
        /// The glass strength's scatter, as the standard deviation of its log.
        let strengthLogSD: Double
        /// Each mix's breakage, by `sides`' mix names.
        let tables: [String: BreakTable]
        /// Seconds the features and tables took.
        public let seconds: Double

        /// A side's features in single precision: those `FacadeLoadSurrogate.terms` reads.
        struct CompactFeatures: Sendable {
            var distance: Float
            var cosine: Float
            var crossed: Float
            var blocked: Float
            var ridge: Float
            var groundRise: Float
            var height: Float
            var edge: Float
            var edgeFrom: Float
            var edgeTo: Float
            var edgeTop: Float
            var edgeSide: Float
            var lastTop: Float
            var shadow: Float
            var canyon: Float
            var canyonHeight: Float
            var chargeOpen: Float

            init(_ f: FacadeLoadSurrogate.Features) {
                distance = Float(f.distanceM)
                cosine = Float(f.cosIncidence)
                crossed = Float(f.buildingsCrossed)
                blocked = Float(f.blockedM)
                ridge = Float(f.ridgeM)
                groundRise = Float(f.groundRiseM)
                height = Float(f.heightM)
                edge = Float(f.edgeM)
                edgeFrom = Float(f.edgeFromChargeM)
                edgeTo = Float(f.edgeToTargetM)
                edgeTop = Float(f.edgeTopM)
                edgeSide = Float(f.edgeSideM)
                lastTop = Float(f.lastTopM)
                shadow = Float(f.shadowM)
                canyon = Float(f.canyonM)
                canyonHeight = Float(f.canyonHeightM)
                chargeOpen = Float(f.chargeOpenM)
            }

            var full: FacadeLoadSurrogate.Features {
                FacadeLoadSurrogate.Features(
                    distanceM: Double(distance), cosIncidence: Double(cosine), buildingsCrossed: Int(crossed),
                    blockedM: Double(blocked), ridgeM: Double(ridge), groundRiseM: Double(groundRise),
                    heightM: Double(height), shadowM: Double(shadow), frontM: 0, edgeM: Double(edge),
                    edgeFromChargeM: Double(edgeFrom), edgeToTargetM: Double(edgeTo),
                    edgeTopM: Double(edgeTop),
                    edgeSideM: Double(edgeSide), lastTopM: Double(lastTop), canyonM: Double(canyon),
                    canyonHeightM: Double(canyonHeight), chargeOpenM: Double(chargeOpen))
            }
        }

        /// The sides of `scene`'s envelope buildings named in `observed` (owner, axis, outward and
        /// whether its glass broke), with a façade on the air and a glazing mix; at most
        /// `maximumSides` of them, taken evenly. `reference` is the inference's origin in the
        /// scene's metres; the charge is weighed within `placeRadius` metres of it, at the scene's
        /// charge's height above the ground. `cellSize` is the cells the surrogate's loads are for;
        /// the façade terms are those of 23 October 2026 (`fitted`), not judged again on the clear-top
        /// terms the quick estimate took on 25 October (emmettl/bombcad-work#99).
        public init(
            scene: Scenario, observed: [(owner: UUID, axis: Int, outward: Int, damaged: Bool)],
            reference: SIMD2<Float>, placeRadius: Double, spacing: Double = 20, cellSize: Float,
            maximumSides: Int = 1500, strengthLogSD: Double = 0.25,
            coefficients: FacadeLoadSurrogate.Coefficients = .fitted
        ) {
            self.init(
                scene: scene, observed: observed, reference: reference, placeRadius: placeRadius,
                spacing: spacing,
                cellSize: cellSize, maximumSides: maximumSides, strengthLogSD: strengthLogSD,
                coefficients: coefficients, tableCoarsening: 1)
        }

        /// With `tableCoarsening`, the breakage tables that many times coarser each way (for tests,
        /// whose debug builds take long over the full ones).
        init(
            scene: Scenario, observed: [(owner: UUID, axis: Int, outward: Int, damaged: Bool)],
            reference: SIMD2<Float>, placeRadius: Double, spacing: Double, cellSize: Float, maximumSides: Int,
            strengthLogSD: Double, coefficients: FacadeLoadSurrogate.Coefficients, tableCoarsening: Int
        ) {
            let start = ContinuousClock.now
            let objects = scene.envelopeObjects
            let raster = FacadeLoadSurrogate.Raster(
                objects: objects, blocks: scene.boxes, terrain: scene.terrain, cell: cellSize)
            let seen = Dictionary(
                observed.map { ("\($0.owner)/\($0.axis)/\($0.outward)", $0.damaged) },
                uniquingKeysWith: { a, _ in a })
            let all = Self.judgedSides(scene: scene, cellSize: cellSize, raster: raster).compactMap {
                side -> Side? in
                guard let damaged = seen["\(objects[side.owner].id)/\(side.axis)/\(side.outward)"] else {
                    return nil
                }
                var side = side
                side.damaged = damaged
                side.east -= Double(reference.x)
                side.north -= Double(reference.y)
                return side
            }
            // Evenly through them, where there are more than the likelihood can weigh in time.
            let every = max(1, Int((Double(all.count) / Double(max(maximumSides, 1))).rounded(.up)))
            let sides = stride(from: 0, to: all.count, by: every).map { all[$0] }
            self.sides = sides
            // A square grid over the disc, a node beyond it each way.
            let count = Int((2 * placeRadius / spacing).rounded(.up)) + 3
            let origin = SIMD2(-placeRadius - spacing, -placeRadius - spacing)
            self.origin = origin
            self.spacing = spacing
            columns = count
            rows = count
            let chargeAbove =
                scene.charge.position.z - (scene.terrain?.height(at: scene.charge.position) ?? 0)
            var features = [CompactFeatures](
                repeating: CompactFeatures(
                    FacadeLoadSurrogate.Features(
                        distanceM: 0, cosIncidence: 0, buildingsCrossed: 0, blockedM: 0, ridgeM: 0,
                        groundRiseM: 0,
                        heightM: 0, shadowM: 0, frontM: 0)), count: count * count * sides.count)
            features.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: count * count) { node in
                    let place = SIMD2<Float>(
                        reference.x + Float(origin.x + Double(node % count) * spacing),
                        reference.y + Float(origin.y + Double(node / count) * spacing))
                    let charge = SIMD3(
                        place.x, place.y, (scene.terrain?.height(at: place) ?? 0) + chargeAbove)
                    let open = raster.openReach(around: charge)
                    for (s, side) in sides.enumerated() {
                        var f = FacadeLoadSurrogate.features(
                            region: side.region, axis: side.axis, outward: side.outward,
                            owner: side.owner,
                            charge: charge, raster: raster)
                        f.chargeOpenM = open
                        out[node * sides.count + s] = CompactFeatures(f)
                    }
                }
            }
            self.features = features
            self.cellSize = Double(cellSize)
            self.coefficients = coefficients
            self.strengthLogSD = strengthLogSD
            var tables: [String: BreakTable] = [:]
            for side in sides where tables[side.mix.name] == nil {
                tables[side.mix.name] = BreakTable.cached(side.mix, coarsening: tableCoarsening)
            }
            self.tables = tables
            let took = start.duration(to: .now)
            seconds = Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
        }

        /// The building sides of `scene` whose glass the app judges (`EnvelopeDamageAssessment`'s
        /// façade glass): each envelope building with a glazing mix, its façade strips on the air
        /// taken side by side. Their `east` and `north` are the side's middle in the scene's metres;
        /// `damaged` is false.
        public static func judgedSides(scene: Scenario, cellSize: Float) -> [Side] {
            judgedSides(
                scene: scene, cellSize: cellSize,
                raster: FacadeLoadSurrogate.Raster(
                    objects: scene.envelopeObjects, blocks: scene.boxes, terrain: scene.terrain,
                    cell: cellSize))
        }

        static func judgedSides(scene: Scenario, cellSize: Float, raster: FacadeLoadSurrogate.Raster)
            -> [Side]
        {
            var all: [Side] = []
            for (n, object) in scene.envelopeObjects.enumerated() {
                guard let envelope = object.envelope,
                    let mix = scene.envelopeConstruction(for: object.id).glazing
                else { continue }
                let strips = envelope.components(owner: object.id, cellSize: cellSize)
                    .filter { $0.kind == .facade && FacadeLoadSurrogate.facesAir($0, raster: raster) }
                let bySide = Dictionary(grouping: strips) { $0.axis * 2 + ($0.outward > 0 ? 1 : 0) }
                for (key, members) in bySide.sorted(by: { $0.key < $1.key }) {
                    guard let first = members.first else { continue }
                    let axis = key / 2
                    let outward = key % 2 == 1 ? 1 : -1
                    let region = members.dropFirst().reduce(first.region) {
                        Box(min: simd_min($0.min, $1.region.min), max: simd_max($0.max, $1.region.max))
                    }
                    let area = members.reduce(0.0) { $0 + Double($1.spans.x * $1.spans.y) }
                    let (centre, _) = FacadeLoadSurrogate.outerFace(
                        region: region, axis: axis, outward: outward)
                    all.append(
                        Side(
                            owner: n, axis: axis, outward: outward, region: region, mix: mix, areaM2: area,
                            damaged: false, east: Double(centre.x), north: Double(centre.y)))
                }
            }
            return all
        }

        /// The judged sides (`judgedSides`) that surveyed façades lie on: each façade, at its place
        /// in the scene's metres (`east`, `north`) and facing its `normalAzimuth` where known, taken to
        /// the nearest side whose face, in plan, lies within `withinM` metres of it and which faces
        /// within 60° of the same way. A side is broken where any façade on it is.
        public static func observed(
            facades: [ChargeInference.Facade], sides: [Side], scene: Scenario, withinM: Double = 6
        ) -> [(owner: UUID, axis: Int, outward: Int, damaged: Bool)] {
            var damaged: [Int: Bool] = [:]
            for facade in facades {
                var best: (index: Int, distance: Double)?
                for (k, side) in sides.enumerated() {
                    let normal =
                        side.axis == 0 ? SIMD2(Double(side.outward), 0) : SIMD2(0, Double(side.outward))
                    if let azimuth = facade.normalAzimuth,
                        normal.x * sin(azimuth) + normal.y * cos(azimuth) < 0.5
                    {
                        continue
                    }
                    // The face's line in plan: across the side's thin axis at its outer face.
                    let along = 1 - side.axis
                    let low = Double(side.region.min[along])
                    let high = Double(side.region.max[along])
                    let face = Double(
                        side.outward > 0 ? side.region.max[side.axis] : side.region.min[side.axis])
                    let p = SIMD2(facade.east, facade.north)
                    let off = abs(p[side.axis] - face)
                    let beyond = max(low - p[along], p[along] - high, 0)
                    let distance = (off * off + beyond * beyond).squareRoot()
                    if distance <= withinM, distance < best?.distance ?? .infinity { best = (k, distance) }
                }
                if let best { damaged[best.index] = (damaged[best.index] ?? false) || facade.damaged }
            }
            let objects = scene.envelopeObjects
            return damaged.keys.sorted().map { k in
                (
                    owner: objects[sides[k].owner].id, axis: sides[k].axis, outward: sides[k].outward,
                    damaged: damaged[k]!
                )
            }
        }

        /// Each side's correction to the surrogate's log peak and log impulse, from a run near the
        /// charge (`correct(toward:massKg:east:north:)`), applied wherever the charge is weighed, as
        /// the arrivals' ratios are; nil for none.
        public var corrections: [SIMD2<Double>]?
        /// How many sides' own glass set their corrections (`correct(towardGlass:)`).
        public var informativeSides = 0

        /// Each side's predicted log peak (Pa), log impulse (Pa s) and rise share from `massKg` at
        /// (`east`, `north`), blended from the grid's four nodes round it, and its distance; nil
        /// where no node gives it a load. Without the corrections.
        public func predictions(massKg: Double, east: Double, north: Double) -> [(
            logPeak: Double, logImpulse: Double, rise: Double, distance: Double
        )?] {
            let x = (east - origin.x) / spacing
            let y = (north - origin.y) / spacing
            let i = min(max(Int(floor(x)), 0), columns - 2)
            let j = min(max(Int(floor(y)), 0), rows - 2)
            let s = min(max(x - Double(i), 0), 1)
            let t = min(max(y - Double(j), 0), 1)
            let corners = [
                (j * columns + i, (1 - s) * (1 - t)), (j * columns + i + 1, s * (1 - t)),
                ((j + 1) * columns + i, (1 - s) * t), ((j + 1) * columns + i + 1, s * t),
            ]
            return sides.indices.map { k in
                var logPeak = 0.0
                var logImpulse = 0.0
                var rise = 0.0
                var weight = 0.0
                for (node, w) in corners where w > 0 {
                    let f = features[node * sides.count + k].full
                    let p = FacadeLoadSurrogate.predict(
                        f, mass: massKg, cellSize: cellSize, coefficients: coefficients)
                    guard p.peakPa > 0, p.impulsePaS > 0 else { continue }
                    logPeak += w * log(p.peakPa)
                    logImpulse += w * log(p.impulsePaS)
                    rise += w * p.riseShare
                    weight += w
                }
                guard weight > 0 else { return nil }
                return (
                    logPeak / weight, logImpulse / weight, rise / weight,
                    Double(features[corners[0].0 * sides.count + k].distance)
                )
            }
        }

        /// The corrections that bring the surrogate's loads from `massKg` at (`east`, `north`) to a
        /// run's there: `run` gives each side's peak net load (Pa) and positive impulse (Pa s) by its
        /// index in `sides`. A side the run did not load takes the median of the rest; each is held
        /// within a factor e^1.5 either way.
        public mutating func correct(
            toward run: [Int: (peak: Double, impulse: Double)], massKg: Double, east: Double, north: Double
        ) {
            let predicted = predictions(massKg: massKg, east: east, north: north)
            var known: [Int: SIMD2<Double>] = [:]
            for (k, load) in run {
                guard k < sides.count, let p = predicted[k], load.peak > 0, load.impulse > 0 else { continue }
                let change = SIMD2(log(load.peak) - p.logPeak, log(load.impulse) - p.logImpulse)
                known[k] = simd_clamp(change, SIMD2(repeating: -1.5), SIMD2(repeating: 1.5))
            }
            func median(_ values: [Double]) -> Double {
                let sorted = values.sorted()
                return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            }
            let fallback = SIMD2(median(known.values.map(\.x)), median(known.values.map(\.y)))
            corrections = sides.indices.map { known[$0] ?? fallback }
        }

        /// The corrections that bring the surrogate's glass from `massKg` at (`east`, `north`) to a
        /// run's there: `run` gives each side's log chance that no pane breaks, as the run judges it,
        /// by its index in `sides`. Each side's load (peak and impulse alike) takes the factor whose
        /// chance from its mix, without the scatter, is the run's. Only a side whose chance in the run
        /// lies between `informative` and its complement tells its load (any load past the one that
        /// breaks a pane for certain gives the same); the rest, and those the run did not judge, take
        /// the median of those that do, as all do with `common`. Each is held within a factor e^1.5
        /// either way.
        public mutating func correct(
            towardGlass run: [Int: Double], massKg: Double, east: Double, north: Double,
            informative: Double = 0.02, common: Bool = false
        ) {
            let predicted = predictions(massKg: massKg, east: east, north: north)
            var known: [Int: Double] = [:]
            for (k, target) in run {
                let chance = -expm1(target)
                guard k < sides.count, chance > informative, chance < 1 - informative, let p = predicted[k],
                    let table = tables[sides[k].mix.name]
                else {
                    continue
                }
                let logDuration = log(2.0) + p.logImpulse - p.logPeak
                func logNone(_ change: Double) -> Double {
                    sides[k].areaM2
                        * table.logNoneBrokenPerM2(
                            logPeak: p.logPeak + change, logDuration: logDuration, rise: p.rise)
                }
                // Its chance that none breaks falls as the load grows.
                var low = -1.5
                var high = 1.5
                if logNone(low) <= target {
                    known[k] = low
                } else if logNone(high) >= target {
                    known[k] = high
                } else {
                    for _ in 0..<30 {
                        let middle = (low + high) / 2
                        if logNone(middle) > target { low = middle } else { high = middle }
                    }
                    known[k] = (low + high) / 2
                }
            }
            let sorted = known.values.sorted()
            let fallback = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            corrections = sides.indices.map { SIMD2(repeating: common ? fallback : known[$0] ?? fallback) }
            informativeSides = known.count
        }

        /// Each side's chance that some pane breaks, from `massKg` at (`east`, `north`), every load
        /// times `factor` (a bias common to the district's sides) and corrected (`corrections`).
        public func chances(massKg: Double, east: Double, north: Double, factor: Double = 1) -> [Double] {
            // Gauss–Hermite over the log of the load's factor.
            let nodes = [
                -2.651961356835233, -1.673551628767471, -0.8162878828589647, 0, 0.8162878828589647,
                1.673551628767471, 2.651961356835233,
            ]
            let weights = [
                9.717812450995192e-4, 0.05451558281912703, 0.4256072526101278, 0.8102646175568073,
                0.4256072526101278, 0.05451558281912703, 9.717812450995192e-4,
            ]
            let root = cbrt(massKg)
            let predicted = predictions(massKg: massKg, east: east, north: north)
            return sides.indices.map { k in
                guard let p = predicted[k], let table = tables[sides[k].mix.name] else { return 0 }
                let correction = corrections?[k] ?? .zero
                let logPeak = p.logPeak + correction.x + log(factor)
                let logImpulse = p.logImpulse + correction.y + log(factor)
                let rise = p.rise
                let logDuration = log(2.0) + logImpulse - logPeak
                let scaled = p.distance / root
                let scatter =
                    FacadeLoadSurrogate.Uncertainty.leaveOneOut.first { scaled <= $0.upToZ }?.peak ?? 0.3
                let sigma = (scatter * scatter + strengthLogSD * strengthLogSD).squareRoot()
                var none = 0.0
                for (u, w) in zip(nodes, weights) {
                    let perArea = table.logNoneBrokenPerM2(
                        logPeak: logPeak + sigma * 1.4142135623730951 * u, logDuration: logDuration,
                        rise: rise)
                    none += w * exp(sides[k].areaM2 * perArea)
                }
                return min(max(1 - none / 1.7724538509055159, 0), 1)
            }
        }

        /// The sides' log likelihood from `massKg` at (`east`, `north`): by bands `bandM` metres wide
        /// of distance from the charge, how many broke against the model's mean chance there, held
        /// with concentration `kappa`.
        /// With `perSide`, each side is weighed on its own, its glass broken or whole against its
        /// chance (a Bernoulli), with each chance kept within `floor` of 0 and 1: which sides broke
        /// says where the charge was, as the bands cannot. Every load is taken times `factor`: the
        /// surrogate's bias shared by a district's sides, which `infer` samples as a parameter.
        public func logLikelihood(
            massKg: Double, east: Double, north: Double, bandM: Double = 250, kappa: Double = 30,
            perSide: Bool = false, floor: Double = 0.02, factor: Double = 1
        ) -> Double {
            if perSide {
                let p = chances(massKg: massKg, east: east, north: north, factor: factor)
                return zip(sides, p).reduce(0.0) { sum, pair in
                    let chance = min(max(pair.1, floor), 1 - floor)
                    return sum + log(pair.0.damaged ? chance : 1 - chance)
                }
            }
            let p = chances(massKg: massKg, east: east, north: north, factor: factor)
            let bands = 40
            var count = [Int](repeating: 0, count: bands)
            var broke = [Int](repeating: 0, count: bands)
            var expected = [Double](repeating: 0, count: bands)
            for (k, side) in sides.enumerated() {
                let band = min(Int(hypot(side.east - east, side.north - north) / bandM), bands - 1)
                count[band] += 1
                if side.damaged { broke[band] += 1 }
                expected[band] += p[k]
            }
            var sum = 0.0
            for band in 0..<bands where count[band] > 0 {
                sum += ChargeInference.logBetaBinomial(
                    k: broke[band], n: count[band], p: expected[band] / Double(count[band]), kappa: kappa)
            }
            return sum
        }
    }

    /// A mix's façade glass under triangular pulses: the log of the chance that no pane breaks per
    /// square metre of façade, by the pulse's log peak (Pa), log duration (s) and the share of it
    /// spent rising, as `GlazingMix.breakage` judges it.
    struct BreakTable: Sendable {
        let logPeaks: (low: Double, high: Double, count: Int)
        let logDurations: (low: Double, high: Double, count: Int)
        static let rises: [Double] = [0, 0.2, 0.45, 0.7, 0.9]
        let values: [Double]

        /// Tables made, by mix name and coarsening: a mix's glass answers the same each time.
        private static let made = Mutex<[String: BreakTable]>([:])

        static func cached(_ mix: GlazingMix, coarsening: Int) -> BreakTable {
            let key = "\(mix.name)/\(coarsening)"
            if let known = made.withLock({ $0[key] }) { return known }
            let table = BreakTable(mix, coarsening: coarsening)
            made.withLock { $0[key] = table }
            return table
        }

        init(_ mix: GlazingMix, coarsening: Int = 1) {
            let p = (low: log(50.0), high: log(5e6), count: max(48 / max(coarsening, 1), 4))
            let d = (low: log(1e-4), high: log(2.0), count: max(30 / max(coarsening, 1), 4))
            logPeaks = p
            logDurations = d
            let r = Self.rises
            var values = [Double](repeating: 0, count: p.count * d.count * r.count)
            values.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: d.count * r.count) { job in
                    let duration = exp(d.low + Double(job % d.count) * (d.high - d.low) / Double(d.count - 1))
                    let rise = r[job / d.count]
                    let step = min(max(duration / 40, 2e-5), 1e-3)
                    for k in 0..<p.count {
                        let peak = exp(p.low + Double(k) * (p.high - p.low) / Double(p.count - 1))
                        let pulse = Self.pulse(peak: peak, duration: duration, rise: rise, step: step)
                        let breakage = mix.breakage(netPa: pulse, binS: step, areaM2: 1)
                        out[(job / d.count * d.count + job % d.count) * p.count + k] = breakage.logNoneBroken
                    }
                }
            }
            self.values = values
        }

        /// A triangle of `peak` lasting `duration`, rising over `rise` of it, in bins `step` long,
        /// followed by stillness for the pane to swing back (80 ms).
        static func pulse(peak: Double, duration: Double, rise: Double, step: Double) -> [Double] {
            let up = rise * duration
            let count = Int(((duration + 0.08) / step).rounded(.up))
            return (0..<count).map { n in
                let t = (Double(n) + 0.5) * step
                if t < up { return peak * t / up }
                if t < duration { return peak * (duration - t) / max(duration - up, 1e-12) }
                return 0
            }
        }

        func logNoneBrokenPerM2(logPeak: Double, logDuration: Double, rise: Double) -> Double {
            let p = logPeaks
            let d = logDurations
            guard logPeak > p.low else { return 0 }
            let x = min((logPeak - p.low) / (p.high - p.low) * Double(p.count - 1), Double(p.count - 1))
            let y = min(
                max((logDuration - d.low) / (d.high - d.low) * Double(d.count - 1), 0), Double(d.count - 1))
            let r = Self.rises
            let clamped = min(max(rise, r.first!), r.last!)
            let zi = min(r.lastIndex { $0 <= clamped } ?? 0, r.count - 2)
            let zt = (clamped - r[zi]) / (r[zi + 1] - r[zi])
            let i = min(Int(x), p.count - 2)
            let j = min(Int(y), d.count - 2)
            let s = x - Double(i)
            let t = y - Double(j)
            func at(_ i: Int, _ j: Int, _ z: Int) -> Double { values[(z * d.count + j) * p.count + i] }
            func plane(_ z: Int) -> Double {
                (1 - t) * ((1 - s) * at(i, j, z) + s * at(i + 1, j, z)) + t
                    * ((1 - s) * at(i, j + 1, z) + s * at(i + 1, j + 1, z))
            }
            return (1 - zt) * plane(zi) + zt * plane(zi + 1)
        }
    }
}
