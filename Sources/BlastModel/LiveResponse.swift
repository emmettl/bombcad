import Foundation
import simd

/// The live drag's learned component response (emmettl/bombcad-work#112, track item 1;
/// docs/learned-models.md, "The live drag's learned response"): small networks that stand in for
/// the drag preview's per-component SDOF and its chances' draws. From a component's predicted load
/// (peak, impulse, rise, and how they move with the yield) and its construction they give what the
/// preview shows: each component's damage level, each glazed side's glass chances, and each
/// building's walls' and roof's chances. They were trained on the CPU code they stand in for
/// (`scenebench response-data`, `Scripts/ml/train_response.py`), run over Beirut's district and
/// made-up ones at sampled charges, yields and yield spreads, each building built as drawn over the
/// envelope model's walls, roofs and glass (`LiveResponse.recipe`; emmettl/bombcad-work#113); the
/// full estimate, once the charge is let go, stays the referee.
///
/// The inputs are laid out here, by the same code the training data was made with, so that the
/// networks are always fed as they were trained.
public enum LiveResponse {
    /// The yield step its slopes are taken over: the loads at the yield times e^0.25, against the
    /// yield's own.
    public static let slopeStep = 0.25

    /// The most façade strips (a side's facings) a side's glass is given, and the most walls a
    /// building's walls' chances: beyond, the smallest strips' area goes to the last one kept, and
    /// the walls least loaded are left out.
    public static let sideStrips = 4
    public static let buildingWalls = 8

    /// A component's load as the networks read it: its predicted peak, impulse and rise at the
    /// charge's yield, and how its log peak and log impulse move with the log of the yield.
    public struct Load: Sendable, Equatable {
        public var log10Peak: Double
        public var log10Impulse: Double
        public var rise: Double
        public var peakSlope: Double
        public var impulseSlope: Double
        public var frontShare: Double

        public init(
            log10Peak: Double, log10Impulse: Double, rise: Double, peakSlope: Double, impulseSlope: Double,
            frontShare: Double = 0
        ) {
            self.log10Peak = log10Peak
            self.log10Impulse = log10Impulse
            self.rise = rise
            self.peakSlope = peakSlope
            self.impulseSlope = impulseSlope
            self.frontShare = frontShare
        }

        /// From the predictions at the yield and at the yield times e^`slopeStep`.
        public init(
            _ p: FacadeLoadSurrogate.Prediction, step q: FacadeLoadSurrogate.Prediction
        ) {
            func lg(_ x: Double) -> Double { log10(max(x, 1e-6)) }
            log10Peak = lg(p.peakPa)
            log10Impulse = lg(p.impulsePaS)
            rise = p.riseShare
            peakSlope = (log(max(q.peakPa, 1e-6)) - log(max(p.peakPa, 1e-6))) / LiveResponse.slopeStep
            impulseSlope =
                (log(max(q.impulsePaS, 1e-6)) - log(max(p.impulsePaS, 1e-6))) / LiveResponse.slopeStep
            frontShare = p.frontShare
        }

        var values: [Float] {
            [
                Float(log10Peak), Float(log10Impulse), Float(rise), Float(peakSlope), Float(impulseSlope),
                Float(frontShare),
            ]
        }
    }

    /// The load scatter the draws take at scaled distance `z`: the log-SDs of the peak and the
    /// impulse and their correlation (none beyond the bands).
    static func scatter(_ uncertainty: FacadeLoadSurrogate.Uncertainty, atZ z: Double) -> [Float] {
        guard let s = uncertainty.scatter(atZ: z) else { return [0, 0, 0] }
        return [Float(s.peak), Float(s.impulse), Float(s.correlation)]
    }

    /// One-hot of `index` over `count` (all zero for an index outside).
    static func oneHot(_ index: Int?, _ count: Int) -> [Float] {
        (0..<count).map { $0 == index ? 1 : 0 }
    }

    static func kindCode(_ kind: EnvelopeComponent.Kind) -> Int {
        switch kind {
        case .facade: 0
        case .wall: 1
        case .slab: 2
        case .roof: 3
        case .pane: 4
        }
    }

    /// A component's shape and holding, as its SDOF takes them: kind, spans (each at most
    /// `EnvelopeDamageAssessment.largestSpan`), one-way span, standing free, its edges held, whether it
    /// lies flat, its panel's height, and the building above and below it, m.
    static func shape(_ component: EnvelopeComponent, buildingTop: Double, buildingBase: Double) -> [Float] {
        let load = EnvelopeComponentLoad(
            id: component.id, owner: component.owner,
            kind: EnvelopeComponentLoad.Kind(rawValue: component.kind.rawValue)!, region: component.region,
            axis: component.axis, binS: 1e-3, outerPa: [], innerPa: [], supportEdges: component.supportEdges,
            startS: 0, outward: component.outward)
        let spans = load.panelSpans
        let largest = EnvelopeDamageAssessment.largestSpan
        let edges = (0..<4).map { component.supportEdges.indices.contains($0) && component.supportEdges[$0] }
        return oneHot(kindCode(component.kind), 5) + [
            Float(min(spans.short, largest)), Float(min(spans.long, largest)),
            Float(load.oneWaySpan.map { min($0, largest) } ?? 0), load.oneWaySpan == nil ? 0 : 1,
            load.isFreestanding ? 1 : 0,
        ] + edges.map { $0 ? 1 : 0 } + [
            component.axis == 2 ? 1 : 0, Float(load.panelHeight),
            Float(max(buildingTop - Double(component.region.max.z), 0)),
            Float(max(Double(component.region.min.z) - buildingBase, 0)),
        ]
    }

    /// The width of `shape`.
    static let shapeWidth = 5 + 5 + 4 + 4

    /// A side's strips, largest first, at most `sideStrips`: the rest's area added to the last kept.
    static func foldedStrips(_ strips: [(load: Load, areaM2: Double, distanceM: Double)]) -> [(
        load: Load, areaM2: Double, distanceM: Double
    )] {
        var ordered = strips.sorted { $0.areaM2 > $1.areaM2 }
        if ordered.count > sideStrips {
            let rest = ordered[sideStrips...].reduce(0) { $0 + $1.areaM2 }
            ordered = Array(ordered.prefix(sideStrips))
            ordered[sideStrips - 1].areaM2 += rest
        }
        return ordered
    }

    /// One slot of a building row's width (`writeBuilding`).
    static let slotWidth = 6 + 2 + 3 + 6 + shapeWidth

    /// A building's walls, most loaded first (by log peak plus log impulse), at most `buildingWalls`.
    static func orderedWalls(_ walls: [(load: Load, component: EnvelopeComponent, distanceM: Double)]) -> [(
        load: Load, component: EnvelopeComponent, distanceM: Double
    )] {
        Array(
            walls.sorted {
                ($0.load.log10Peak + $0.load.log10Impulse, $0.component.id)
                    > ($1.load.log10Peak + $1.load.log10Impulse, $1.component.id)
            }.prefix(buildingWalls))
    }
}

extension LiveResponse {
    /// The networks' inputs for one look at a district (`batch`): a row of each network's inputs for
    /// each component, glazed side and building the look judges, and what each row is.
    public struct Batch: Sendable {
        /// The component network's rows, one for each component of the estimate, in its order.
        public var components: [Float] = []
        public var componentWidth = 0
        /// The glass network's rows, one for each side, in the sides' order.
        public var sides: [Float] = []
        public var sideWidth = 0
        /// The walls network's rows, and each row's building.
        public var buildings: [Float] = []
        public var buildingWidth = 0
        public var buildingOwners: [UUID] = []
        /// Whether each building has a roof in the look, and walls: without them its chances are none.
        public var buildingHasRoof: [Bool] = []
        public var buildingHasWalls: [Bool] = []
        /// The buildings whose construction, and the sides whose mix, the networks do not know.
        public var unknown = 0

        public var componentCount: Int { componentWidth == 0 ? 0 : components.count / componentWidth }
        public var sideCount: Int { sideWidth == 0 ? 0 : sides.count / sideWidth }
        public var buildingCount: Int { buildingWidth == 0 ? 0 : buildings.count / buildingWidth }
    }

    /// The networks' inputs for `estimate` (a preview's: `Prepared.preview`) and its glazed `sides`,
    /// for a charge of `mass` kg, their loads predicted here on the CPU: its components' loads under
    /// `coefficients` (a roof's under `roofCoefficients`), the walls' as their chances take them
    /// (`Coefficients.forStructures`), the glass's as the glass's (`Coefficients.forGlass`), each with
    /// its slope over the yield; the draws over `uncertainty`'s yield spread and load scatter. `construction` gives a
    /// building's construction as the networks read it (`constructionFeatures`), `glazing` a side's
    /// mix (`glazingFeatures`): nil for one they do not know.
    public static func batch(
        estimate: FacadeLoadSurrogate.Estimate, sides: [FacadeLoadSurrogate.GlassSideStrips], mass: Double,
        cellSize: Float, coefficients: FacadeLoadSurrogate.Coefficients,
        roofCoefficients: FacadeLoadSurrogate.Coefficients?, uncertainty: FacadeLoadSurrogate.Uncertainty,
        construction: (UUID) -> [Float]?, glazing: (FacadeLoadSurrogate.GlassSideStrips) -> [Float]?
    ) -> Batch {
        let dx = Double(cellSize)
        let stepped = mass * exp(slopeStep)
        return batch(
            estimate: estimate, sides: sides, mass: mass, uncertainty: uncertainty,
            construction: construction,
            glazing: glazing,
            componentLoads: { k in
                let component = estimate.components[k]
                let f = estimate.features[k]
                let roof = component.kind == .roof
                let terms = roof ? roofCoefficients ?? coefficients : coefficients
                let p = FacadeLoadSurrogate.predict(f, mass: mass, cellSize: dx, coefficients: terms)
                let damage = Load(
                    log10Peak: log10(max(p.peakPa, 1e-6)), log10Impulse: log10(max(p.impulsePaS, 1e-6)),
                    rise: p.riseShare, peakSlope: 0, impulseSlope: 0)
                guard [.facade, .wall, .roof].contains(component.kind) else { return (damage, nil) }
                let structureTerms = roof ? roofCoefficients ?? coefficients : coefficients.forStructures
                return (
                    damage,
                    Load(
                        FacadeLoadSurrogate.predict(
                            f, mass: mass, cellSize: dx, coefficients: structureTerms),
                        step: FacadeLoadSurrogate.predict(
                            f, mass: stepped, cellSize: dx, coefficients: structureTerms))
                )
            },
            stripLoad: { s, t in
                let strip = sides[s].strips[t]
                let d = strip.features.distanceM
                let p = coefficients.forGlass(
                    FacadeLoadSurrogate.predict(
                        strip.features, mass: mass, cellSize: dx, coefficients: coefficients),
                    distanceM: d, mass: mass)
                let q = coefficients.forGlass(
                    FacadeLoadSurrogate.predict(
                        strip.features, mass: stepped, cellSize: dx, coefficients: coefficients),
                    distanceM: d, mass: stepped)
                return Load(p, step: q)
            })
    }

    /// The networks' inputs, as above, each component's loads given by `componentLoads` (by its
    /// index in the estimate: the damage's, and for a wall, façade strip or roof the walls' chances')
    /// and each side's strips' by `stripLoad` (by side and strip): the CPU's predictions, or the GPU's
    /// (`LiveResponse.Engine`).
    public static func batch(
        estimate: FacadeLoadSurrogate.Estimate, sides: [FacadeLoadSurrogate.GlassSideStrips], mass: Double,
        uncertainty: FacadeLoadSurrogate.Uncertainty, construction: (UUID) -> [Float]?,
        glazing: (FacadeLoadSurrogate.GlassSideStrips) -> [Float]?,
        componentLoads: (Int) -> (damage: Load, walls: Load?),
        stripLoad: (Int, Int) -> Load
    ) -> Batch {
        let root = cbrt(mass)
        // Each building's components, top, base and construction's signature.
        var byOwner: [UUID: [Int]] = [:]
        for (k, component) in estimate.components.enumerated() {
            byOwner[component.owner, default: []].append(k)
        }
        let owners = byOwner.keys.sorted { $0.uuidString < $1.uuidString }
        var top: [UUID: Double] = [:]
        var base: [UUID: Double] = [:]
        var signatureOf: [UUID: [Float]] = [:]
        var unknown = 0
        for owner in owners {
            let mine = byOwner[owner]!
            top[owner] = mine.map { Double(estimate.components[$0].region.max.z) }.max()
            base[owner] = mine.map { Double(estimate.components[$0].region.min.z) }.min()
            if let n = construction(owner) { signatureOf[owner] = n } else { unknown += 1 }
        }
        var batch = Batch()
        batch.unknown = unknown
        let cw = 3 + constructionWidth + shapeWidth
        batch.componentWidth = cw
        let count = estimate.components.count
        var rows = [Float](repeating: 0, count: count * cw)
        // The walls' and roofs' loads, for the buildings' rows.
        var wallLoads = [Load?](repeating: nil, count: count)
        rows.withUnsafeMutableBufferPointer { out in
            wallLoads.withUnsafeMutableBufferPointer { walls in
                concurrently(iterations: count) { k in
                    let component = estimate.components[k]
                    let (load, wall) = componentLoads(k)
                    let owner = component.owner
                    var at = k * cw
                    (out[at], out[at + 1], out[at + 2]) = quantized(load)
                    if let n = signatureOf[owner] { for (j, v) in n.enumerated() { out[at + 3 + j] = v } }
                    at += 3 + constructionWidth
                    writeShape(
                        component, buildingTop: top[owner] ?? 0, buildingBase: base[owner] ?? 0, into: out,
                        at: at)
                    walls[k] = wall
                }
            }
        }
        batch.components = rows

        // The buildings: their walls and roof.
        let bw = slotWidth * (buildingWalls + 1) + 1 + constructionWidth
        batch.buildingWidth = bw
        var buildingRows = [Float](repeating: 0, count: owners.count * bw)
        var hasRoof = [Bool](repeating: false, count: owners.count)
        var hasWalls = [Bool](repeating: false, count: owners.count)
        buildingRows.withUnsafeMutableBufferPointer { out in
            hasRoof.withUnsafeMutableBufferPointer { roofs in
                hasWalls.withUnsafeMutableBufferPointer { wallsOut in
                    concurrently(iterations: owners.count) { b in
                        let owner = owners[b]
                        var walls: [(load: Load, component: EnvelopeComponent, distanceM: Double)] = []
                        var roof: (load: Load, component: EnvelopeComponent, distanceM: Double)?
                        for k in byOwner[owner]! {
                            guard let load = wallLoads[k] else { continue }
                            let item = (load, estimate.components[k], estimate.features[k].distanceM)
                            if estimate.components[k].kind == .roof {
                                // The nearest roof, should a building have more than one.
                                if roof == nil || item.2 < roof!.distanceM { roof = item }
                            } else {
                                walls.append(item)
                            }
                        }
                        writeBuilding(
                            walls: walls, roof: roof, construction: signatureOf[owner],
                            buildingTop: top[owner] ?? 0, buildingBase: base[owner] ?? 0, root: root,
                            uncertainty: uncertainty, into: out, at: b * bw)
                        roofs[b] = roof != nil
                        wallsOut[b] = !walls.isEmpty
                    }
                }
            }
        }
        batch.buildings = buildingRows
        batch.buildingOwners = owners
        batch.buildingHasRoof = hasRoof
        batch.buildingHasWalls = hasWalls

        // The glazed sides.
        let sw = 9 * sideStrips + 2 + 3 + glazingWidth
        batch.sideWidth = sw
        let mixOf = sides.map(glazing)
        batch.unknown += mixOf.filter { $0 == nil }.count
        var sideRows = [Float](repeating: 0, count: sides.count * sw)
        sideRows.withUnsafeMutableBufferPointer { out in
            concurrently(iterations: sides.count) { s in
                let side = sides[s]
                guard !side.strips.isEmpty else { return }
                let strips = side.strips.indices.map { t -> (load: Load, areaM2: Double, distanceM: Double) in
                    (stripLoad(s, t), side.strips[t].areaM2, side.strips[t].features.distanceM)
                }
                writeSide(
                    strips, glazing: mixOf[s], root: root, uncertainty: uncertainty, into: out,
                    at: s * sw)
            }
        }
        batch.sides = sideRows
        return batch
    }

    /// `shape` written into `out` from `at`.
    /// A glazed side's row of the glass network's inputs (`sideInputs`), written in place.
    static func writeSide(
        _ strips: [(load: Load, areaM2: Double, distanceM: Double)], glazing: [Float]?, root: Double,
        uncertainty: FacadeLoadSurrogate.Uncertainty, into out: UnsafeMutableBufferPointer<Float>,
        at start: Int
    ) {
        guard !strips.isEmpty else { return }
        let ordered = foldedStrips(strips)
        let area = strips.reduce(0) { $0 + $1.areaM2 }
        var at = start
        for n in 0..<sideStrips {
            if n < ordered.count {
                let strip = ordered[n]
                for v in strip.load.values {
                    out[at] = v
                    at += 1
                }
                out[at] = Float(strip.areaM2 / max(area, 1e-9))
                out[at + 1] = Float(log(max(strip.distanceM / root, 1e-3)))
                out[at + 2] = 1
                at += 3
            } else {
                at += 9
            }
        }
        let middle = strips.map(\.distanceM).sorted()[strips.count / 2]
        out[at] = Float(log10(max(area, 1e-3)))
        out[at + 1] = Float(uncertainty.yieldLogSD)
        at += 2
        if let sc = uncertainty.scatter(atZ: middle / root) {
            out[at] = Float(sc.peak)
            out[at + 1] = Float(sc.impulse)
            out[at + 2] = Float(sc.correlation)
        }
        at += 3
        if let glazing { for (j, v) in glazing.enumerated() { out[at + j] = v } }
    }

    /// A building's row of the walls network's inputs (`buildingInputs`), written in place.
    static func writeBuilding(
        walls: [(load: Load, component: EnvelopeComponent, distanceM: Double)],
        roof: (load: Load, component: EnvelopeComponent, distanceM: Double)?, construction: [Float]?,
        buildingTop: Double, buildingBase: Double, root: Double, uncertainty: FacadeLoadSurrogate.Uncertainty,
        into out: UnsafeMutableBufferPointer<Float>, at start: Int
    ) {
        func slot(_ item: (load: Load, component: EnvelopeComponent, distanceM: Double), at slotStart: Int) {
            let z = item.distanceM / root
            var at = slotStart
            for v in item.load.values {
                out[at] = v
                at += 1
            }
            out[at] = Float(log(max(z, 1e-3)))
            out[at + 1] = 1
            at += 2
            if let s = uncertainty.scatter(atZ: z) {
                out[at] = Float(s.peak)
                out[at + 1] = Float(s.impulse)
                out[at + 2] = Float(s.correlation)
            }
            at += 3
            out[at + item.component.axis * 2 + (item.component.outward > 0 ? 1 : 0)] = 1
            at += 6
            writeShape(
                item.component, buildingTop: buildingTop, buildingBase: buildingBase, into: out, at: at)
        }
        for (n, item) in orderedWalls(walls).enumerated() { slot(item, at: start + n * slotWidth) }
        if let roof { slot(roof, at: start + buildingWalls * slotWidth) }
        let tail = start + (buildingWalls + 1) * slotWidth
        out[tail] = Float(uncertainty.yieldLogSD)
        if let construction { for (j, v) in construction.enumerated() { out[tail + 1 + j] = v } }
    }

    /// As `shape`, written in place without laying a load out (a live frame writes tens of thousands):
    /// `EnvelopeComponentLoad`'s spans, one-way span, standing free and panel height worked out here
    /// as it works them out (`LiveResponseTests` holds the two together).
    static func writeShape(
        _ component: EnvelopeComponent, buildingTop: Double, buildingBase: Double,
        into out: UnsafeMutableBufferPointer<Float>, at: Int
    ) {
        let region = component.region
        let axis = component.axis
        let edges = component.supportEdges
        let (u, v) = component.inPlaneAxes
        let sizes = (Double(region.size[u]), Double(region.size[v]))
        let spans = (min(sizes.0, sizes.1), max(sizes.0, sizes.1))
        let height = Double(region.size.z)
        let panelHeight = component.kind == .facade ? min(height, Double(BuildingEnvelope.storey)) : height
        var short = spans.0
        var long = spans.1
        if component.kind == .facade, axis != 2 {
            let width = Double(region.size[axis == 0 ? 1 : 0])
            short = min(width, panelHeight)
            long = max(width, panelHeight)
        }
        let freestanding = component.kind == .wall && axis != 2 && edges.count == 4 && edges[2] && !edges[3]
        var oneWay: Double?
        if edges.count == 4, component.kind != .pane, !freestanding {
            if edges[2] && edges[3] && !edges[0] && !edges[1] { oneWay = sizes.1 }
            if edges[0] && edges[1] && !edges[2] && !edges[3] { oneWay = sizes.0 }
        }
        let largest = EnvelopeDamageAssessment.largestSpan
        for k in 0..<5 { out[at + k] = 0 }
        out[at + kindCode(component.kind)] = 1
        out[at + 5] = Float(min(short, largest))
        out[at + 6] = Float(min(long, largest))
        out[at + 7] = Float(oneWay.map { min($0, largest) } ?? 0)
        out[at + 8] = oneWay == nil ? 0 : 1
        out[at + 9] = freestanding ? 1 : 0
        for k in 0..<4 { out[at + 10 + k] = edges.indices.contains(k) && edges[k] ? 1 : 0 }
        out[at + 14] = axis == 2 ? 1 : 0
        out[at + 15] = Float(panelHeight)
        out[at + 16] = Float(max(buildingTop - Double(region.max.z), 0))
        out[at + 17] = Float(max(Double(region.min.z) - buildingBase, 0))
    }

    /// The damage's load as the component network reads it: the pulse's peak and impulse rounded to
    /// `FacadeLoadSurrogate.quantum` and its rise to a twentieth, as `FacadeLoadSurrogate.load` rounds
    /// them before the SDOF meets them.
    static func quantized(_ load: Load) -> (Float, Float, Float) {
        let step = log(1 + FacadeLoadSurrogate.quantum) / log(10.0)
        return (
            Float((load.log10Peak / step).rounded() * step),
            Float((load.log10Impulse / step).rounded() * step),
            Float((load.rise * 20).rounded() / 20)
        )
    }
}
