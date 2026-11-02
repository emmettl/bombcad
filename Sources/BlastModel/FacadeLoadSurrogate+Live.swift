import Foundation
import simd

extension LiveResponse {
    /// What the live drag keeps of a district between frames: each building's construction and
    /// each glazed building's mix as the networks read them (`constructionFeatures`,
    /// `glazingFeatures`), worked out once for each set of constructions (the first frame's, and
    /// again after a what-if changes them).
    public final class District: @unchecked Sendable {
        public let identity: UUID
        public let constructionsKey: UUID
        let constructionOf: [UUID: [Float]]
        let glazingOf: [UUID: [Float]]
        let builtOf: [UUID: EnvelopeConstruction]
        /// The buildings the networks do not know, by construction or glazing.
        public let unknown: Int

        init(prepared: FacadeLoadSurrogate.Prepared) {
            identity = prepared.identity
            constructionsKey = prepared.constructionsKey
            // Each building read on its own core: a what-if reads the district again.
            let count = prepared.objects.count
            var features = [[Float]?](repeating: nil, count: count)
            var glazings = [[Float]?](repeating: nil, count: count)
            features.withUnsafeMutableBufferPointer { featureOut in
                glazings.withUnsafeMutableBufferPointer { glazingOut in
                    concurrently(iterations: (count + 63) / 64) { chunk in
                        for n in (chunk * 64)..<min(count, (chunk + 1) * 64) {
                            featureOut[n] = LiveResponse.constructionFeatures(prepared.constructions[n])
                            glazingOut[n] = prepared.mixes[n].flatMap(LiveResponse.glazingFeatures)
                        }
                    }
                }
            }
            var constructionOf: [UUID: [Float]] = [:]
            var glazingOf: [UUID: [Float]] = [:]
            var unknown = 0
            for (n, object) in prepared.objects.enumerated() {
                if let f = features[n] { constructionOf[object.id] = f } else { unknown += 1 }
                if prepared.mixes[n] != nil {
                    if let g = glazings[n] {
                        glazingOf[object.id] = g
                    } else if features[n] != nil {
                        unknown += 1
                    }
                }
            }
            builtOf = Dictionary(
                zip(prepared.objects, prepared.constructions).map { ($0.id, $1) },
                uniquingKeysWith: { a, _ in a })
            self.constructionOf = constructionOf
            self.glazingOf = glazingOf
            self.unknown = unknown
        }
    }

    /// The live drag's model: its weights, where it runs, and what it keeps of the district shown.
    public final class Model: @unchecked Sendable {
        public let weights: Weights
        public let engine: Engine
        private var district: District?
        private let lock = NSLock()

        public init(weights: Weights, engine: Engine) {
            self.weights = weights
            self.engine = engine
        }

        func district(for prepared: FacadeLoadSurrogate.Prepared) -> District {
            lock.withLock {
                if let district, district.identity == prepared.identity,
                    district.constructionsKey == prepared.constructionsKey
                {
                    return district
                }
                let made = District(prepared: prepared)
                district = made
                return made
            }
        }
    }
}

extension FacadeLoadSurrogate.Prepared {
    /// What a live look's stages took, s (`livePreview`).
    public struct LiveStages: Sendable, Equatable {
        public var choice = 0.0
        public var loads = 0.0
        public var inputs = 0.0
        public var networks = 0.0
        public var answers = 0.0
        public var district = 0.0
        /// Of `loads` and `networks`, the GPU's own time.
        public var gpu = 0.0
    }

    /// The drag preview judged by the learned response (emmettl/bombcad-work#112): the same components
    /// as `preview` takes (each group's nearest), their sight lines and loads worked out by `model`'s
    /// engine (on the GPU in the app), and in place of their SDOF and the chances' draws, the learned
    /// response's networks: each component's damage level and glass, each glazed side's glass chances,
    /// and each building's walls' and roof's chances. Only `parts` is worked out, as `look`'s preview.
    /// Nil where the networks do not know every building's construction and glazing (the CPU path is
    /// then the preview). The learned field model's peaks are not taken: its strips draw its own
    /// scatter, which the networks were not trained on, so with that option on the preview stays the
    /// CPU's.
    public func livePreview(
        charge: SIMD3<Float>, mass: Double, uncertainty: FacadeLoadSurrogate.Uncertainty, parts: Parts = .all,
        terms: FacadeLoadSurrogate.TermSet = .adopted,
        roofCoefficients: FacadeLoadSurrogate.Coefficients = .roofs,
        model: LiveResponse.Model, keepEstimate: Bool = false
    ) throws -> (look: Look, stages: LiveStages)? {
        var clock = ContinuousClock.now
        func lap() -> Double {
            let now = ContinuousClock.now
            let took = clock.duration(to: now)
            clock = now
            return Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
        }
        let start = clock
        var stages = LiveStages()
        let district = model.district(for: self)
        stages.district = lap()
        guard district.unknown == 0 else { return nil }
        let coefficients = terms.coefficients
        let weights = model.weights

        let (request, picked, itemOf) = liveRequest(
            charge: charge, mass: mass, coefficients: coefficients, roofCoefficients: roofCoefficients,
            parts: parts)
        let open = request.openReachM
        let count = request.count
        stages.choice = lap()
        let values = try model.engine.loads(request)
        guard values.count == count * LiveResponse.itemWidth else { return nil }
        stages.loads = lap()
        stages.gpu = model.engine.lastGPUSeconds

        // Each object's judged components and glazed sides (each side's strips, one for each way its
        // outline faces it), as `preview` lays them out, by the items' indices; and where its rows go.
        struct Layout {
            var judged: [Int] = []
            var sides: [(axis: Int, outward: Int, items: [Int], areas: [Double])] = []
            var top = 0.0
            var base = 0.0
        }
        var layouts = [Layout](repeating: Layout(), count: objects.count)
        layouts.withUnsafeMutableBufferPointer { out in
            concurrently(iterations: (objects.count + 63) / 64) { chunk in
                for n in (chunk * 64)..<min(objects.count, (chunk + 1) * 64) {
                    var layout = Layout()
                    var top = -Double.infinity
                    var base = Double.infinity
                    for (c, choice) in picked[n].enumerated() {
                        let item = itemOf[n][c]
                        guard item >= 0 else { continue }
                        let component = request.components[item]
                        if choice.judged {
                            layout.judged.append(item)
                            top = max(top, Double(component.region.max.z))
                            base = min(base, Double(component.region.min.z))
                        }
                        guard component.kind == .facade, mixes[n] != nil else { continue }
                        if let s = layout.sides.firstIndex(where: {
                            $0.axis == component.axis && $0.outward == component.outward
                        }) {
                            layout.sides[s].items.append(item)
                            layout.sides[s].areas.append(choice.area)
                        } else {
                            layout.sides.append((component.axis, component.outward, [item], [choice.area]))
                        }
                    }
                    layout.top = top
                    layout.base = base
                    out[n] = layout
                }
            }
        }
        var componentStart = [Int](repeating: 0, count: objects.count + 1)
        var sideStart = [Int](repeating: 0, count: objects.count + 1)
        for n in objects.indices {
            componentStart[n + 1] = componentStart[n] + layouts[n].judged.count
            sideStart[n + 1] = sideStart[n] + layouts[n].sides.count
        }
        let componentCount = componentStart[objects.count]
        let sideCount = sideStart[objects.count]
        // The buildings judged: those with a component in the estimate.
        let owners = objects.indices.filter { !layouts[$0].judged.isEmpty }

        // An item's load as the networks read it, from the engine's floats.
        func load(_ v: UnsafeBufferPointer<Float>, _ item: Int, rise: Int, front: Bool, slopes: Bool = true)
            -> LiveResponse.Load
        {
            let at = item * LiveResponse.itemWidth + LiveResponse.featureCount
            let p0 = max(Double(v[at]), 1e-6)
            let i0 = max(Double(v[at + 1]), 1e-6)
            let p1 = max(Double(v[at + 5]), 1e-6)
            let i1 = max(Double(v[at + 6]), 1e-6)
            return LiveResponse.Load(
                log10Peak: log10(p0), log10Impulse: log10(i0), rise: Double(v[at + rise]),
                peakSlope: slopes ? (log(p1) - log(p0)) / LiveResponse.slopeStep : 0,
                impulseSlope: slopes ? (log(i1) - log(i0)) / LiveResponse.slopeStep : 0,
                frontShare: front ? Double(v[at + 4]) : 0)
        }
        func distance(_ v: UnsafeBufferPointer<Float>, _ item: Int) -> Double {
            Double(v[item * LiveResponse.itemWidth + LiveResponse.Feature.distance.rawValue])
        }
        let root = cbrt(mass)

        // The networks' rows, as `LiveResponse.batch` lays them out.
        let cw = 3 + LiveResponse.constructionWidth + LiveResponse.shapeWidth
        let sw = 9 * LiveResponse.sideStrips + 5 + LiveResponse.glazingWidth
        let bw =
            LiveResponse.slotWidth * (LiveResponse.buildingWalls + 1) + 1 + LiveResponse.constructionWidth
        var componentRows = [Float](repeating: 0, count: parts.contains(.damage) ? componentCount * cw : 0)
        var sideRows = [Float](repeating: 0, count: parts.contains(.glass) ? sideCount * sw : 0)
        var buildingRows = [Float](repeating: 0, count: parts.contains(.structure) ? owners.count * bw : 0)
        var hasRoof = [Bool](repeating: false, count: owners.count)
        var hasWalls = [Bool](repeating: false, count: owners.count)
        values.withUnsafeBufferPointer { v in
            componentRows.withUnsafeMutableBufferPointer { cOut in
                sideRows.withUnsafeMutableBufferPointer { sOut in
                    buildingRows.withUnsafeMutableBufferPointer { bOut in
                        hasRoof.withUnsafeMutableBufferPointer { roofs in
                            hasWalls.withUnsafeMutableBufferPointer { wallsOut in
                                concurrently(iterations: (owners.count + 31) / 32) { chunk in
                                    for b in (chunk * 32)..<min(owners.count, (chunk + 1) * 32) {
                                        let n = owners[b]
                                        let layout = layouts[n]
                                        let construction = district.constructionOf[objects[n].id]
                                        if !cOut.isEmpty {
                                            for (j, item) in layout.judged.enumerated() {
                                                let at = (componentStart[n] + j) * cw
                                                (cOut[at], cOut[at + 1], cOut[at + 2]) =
                                                    LiveResponse.quantized(
                                                        load(v, item, rise: 2, front: false, slopes: false))
                                                if let construction {
                                                    for (k, value) in construction.enumerated() {
                                                        cOut[at + 3 + k] = value
                                                    }
                                                }
                                                LiveResponse.writeShape(
                                                    request.components[item], buildingTop: layout.top,
                                                    buildingBase: layout.base, into: cOut,
                                                    at: at + 3 + LiveResponse.constructionWidth)
                                            }
                                        }
                                        if !sOut.isEmpty, let mix = district.glazingOf[objects[n].id] {
                                            for (k, side) in layout.sides.enumerated() {
                                                let strips = side.items.indices.map { t in
                                                    (
                                                        load: load(v, side.items[t], rise: 2, front: true),
                                                        areaM2: side.areas[t],
                                                        distanceM: distance(v, side.items[t])
                                                    )
                                                }
                                                LiveResponse.writeSide(
                                                    strips, glazing: mix, root: root,
                                                    uncertainty: uncertainty, into: sOut,
                                                    at: (sideStart[n] + k) * sw)
                                            }
                                        }
                                        guard !bOut.isEmpty else { continue }
                                        var walls:
                                            [(
                                                load: LiveResponse.Load, component: EnvelopeComponent,
                                                distanceM: Double
                                            )] = []
                                        var roof:
                                            (
                                                load: LiveResponse.Load, component: EnvelopeComponent,
                                                distanceM: Double
                                            )?
                                        for item in layout.judged {
                                            let component = request.components[item]
                                            guard [.facade, .wall, .roof].contains(component.kind) else {
                                                continue
                                            }
                                            let d = distance(v, item)
                                            if component.kind == .roof {
                                                if roof == nil || d < roof!.distanceM {
                                                    roof = (
                                                        load(v, item, rise: 3, front: false), component, d
                                                    )
                                                }
                                            } else {
                                                walls.append(
                                                    (load(v, item, rise: 3, front: false), component, d))
                                            }
                                        }
                                        roofs[b] = roof != nil
                                        wallsOut[b] = !walls.isEmpty
                                        LiveResponse.writeBuilding(
                                            walls: walls, roof: roof, construction: construction,
                                            buildingTop: layout.top, buildingBase: layout.base, root: root,
                                            uncertainty: uncertainty, into: bOut, at: b * bw)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        stages.inputs = lap()

        // The networks, only for what is shown.
        func run(_ name: String, _ rows: [Float], _ count: Int) throws -> [Float] {
            let out = try model.engine.run(name, rows: rows, count: count)
            stages.gpu += model.engine.lastGPUSeconds
            return out
        }
        let componentOut = parts.contains(.damage) ? try run("component", componentRows, componentCount) : []
        let sideOut = parts.contains(.glass) ? try run("side", sideRows, sideCount) : []
        let buildingOut = parts.contains(.structure) ? try run("building", buildingRows, owners.count) : []
        stages.networks = lap()

        // Their answers, as the CPU path gives them; `BOMBCAD_LIVE_BROKEN_THRESHOLD` in place of the
        // weights' threshold, for choosing it.
        let brokenThreshold = Float(
            ProcessInfo.processInfo.environment["BOMBCAD_LIVE_BROKEN_THRESHOLD"].flatMap(Double.init)
                ?? weights.header.brokenThreshold ?? 0)
        func sigmoid(_ x: Float) -> Double { 1 / (1 + exp(-Double(x))) }
        var damage: [EnvelopeBuildingDamage] = []
        var glass: [FacadeLoadSurrogate.SideGlass] = []
        var structure: [FacadeLoadSurrogate.StructureChance] = []
        values.withUnsafeBufferPointer { v in
            if parts.contains(.damage) {
                var made = [EnvelopeBuildingDamage?](repeating: nil, count: owners.count)
                made.withUnsafeMutableBufferPointer { out in
                    concurrently(iterations: (owners.count + 63) / 64) { chunk in
                        for b in (chunk * 64)..<min(owners.count, (chunk + 1) * 64) {
                            let n = owners[b]
                            var level = 0
                            var panes = 0
                            var broken = 0
                            for (j, item) in layouts[n].judged.enumerated() {
                                let o = (componentStart[n] + j) * 6
                                let kind = request.components[item].kind
                                let isBroken = componentOut[o + 5] > brokenThreshold
                                if kind == .pane || kind == .facade {
                                    panes += 1
                                    broken += isBroken ? 1 : 0
                                }
                                guard kind != .pane else { continue }
                                var best = 0
                                for c in 1..<5 where componentOut[o + c] > componentOut[o + best] { best = c }
                                level = max(level, best)
                            }
                            let worst = EnvelopeDamageLevel(rawValue: level) ?? .none
                            out[b] = EnvelopeBuildingDamage(
                                id: objects[n].id, construction: constructions[n], components: [],
                                structuralLevels: worst...worst, beyondOneWay: false, panes: panes,
                                panesBroken: broken, firstPaneBrokenAtS: nil, insidePeakPa: 0,
                                insideImpulsePaS: 0)
                        }
                    }
                }
                damage = made.map { $0! }
            }
            if parts.contains(.glass) {
                var made = [FacadeLoadSurrogate.SideGlass?](repeating: nil, count: sideCount)
                made.withUnsafeMutableBufferPointer { out in
                    concurrently(iterations: (owners.count + 63) / 64) { chunk in
                        for b in (chunk * 64)..<min(owners.count, (chunk + 1) * 64) {
                            let n = owners[b]
                            for (k, side) in layouts[n].sides.enumerated() {
                                let s = sideStart[n] + k
                                let o = s * 5
                                let middle = side.items.map { distance(v, $0) }.sorted()[side.items.count / 2]
                                let some = sigmoid(sideOut[o])
                                out[s] = FacadeLoadSurrogate.SideGlass(
                                    owner: objects[n].id, axis: side.axis, outward: side.outward,
                                    distanceM: middle,
                                    someBroken: some, blownOut: min(sigmoid(sideOut[o + 1]), some),
                                    fractionBroken: sigmoid(sideOut[o + 2]),
                                    thrownPast3b: min(sigmoid(sideOut[o + 3]), some),
                                    openingsBlownOut: sigmoid(sideOut[o + 4]))
                            }
                        }
                    }
                }
                glass = made.compactMap { $0 }
            }
            if parts.contains(.structure) {
                structure = owners.enumerated().map { b, n in
                    let o = b * 3
                    let moderate = hasWalls[b] ? sigmoid(buildingOut[o]) : 0
                    return FacadeLoadSurrogate.StructureChance(
                        owner: objects[n].id, wallsModerate: moderate,
                        wallsHeavy: hasWalls[b] ? min(sigmoid(buildingOut[o + 1]), moderate) : 0,
                        roofModerate: hasRoof[b] ? sigmoid(buildingOut[o + 2]) : 0)
                }
            }
        }

        // The estimate the look was judged on, laid out only when asked (a frame has no need of it).
        var estimate = FacadeLoadSurrogate.Estimate(
            components: [], owners: [], features: [], predictions: [], loads: [], seconds: 0)
        estimate.ownerKeys = objects.map(\.drawKey)
        if keepEstimate {
            values.withUnsafeBufferPointer { v in
                for n in owners {
                    for item in layouts[n].judged {
                        estimate.components.append(request.components[item])
                        estimate.owners.append(n)
                        estimate.features.append(
                            LiveResponse.features(
                                v, at: item * LiveResponse.itemWidth, openReachM: open,
                                factor: Double(request.factors[item])))
                    }
                }
            }
        }
        stages.answers = lap()
        let took = start.duration(to: .now)
        estimate.seconds = Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
        // The networks' and their answers' time goes to the first part shown.
        let judged = stages.networks + stages.answers
        var look = Look(
            estimate: estimate, damage: damage, glass: glass, structure: structure, charge: charge,
            preview: true,
            seconds: (
                estimate: stages.district + stages.choice + stages.loads + stages.inputs,
                damage: parts.contains(.damage) ? judged : 0,
                glass: parts.contains(.glass) && !parts.contains(.damage) ? judged : 0,
                structure: parts == .structure ? judged : 0
            ))
        look.learnedResponse = model.engine.label
        return (look, stages)
    }

    /// The live drag's items with the charge at `charge` (`livePreview`): the components a preview
    /// takes, as `preview` chooses them, that `parts` needs (the judged ones for the damage and the
    /// walls, the glazed sides' strips for the glass), for the engine; each object's choices, and each
    /// choice's item (−1 for one not needed).
    package func liveRequest(
        charge: SIMD3<Float>, mass: Double, coefficients: FacadeLoadSurrogate.Coefficients = .adopted,
        roofCoefficients: FacadeLoadSurrogate.Coefficients = .roofs, parts: Parts = .all
    ) -> (LiveResponse.LoadRequest, [[(index: Int, area: Double, judged: Bool)]], [[Int]]) {
        // The components a preview takes, as `preview`.
        let open = raster.openReach(around: charge)
        let picked = choices(charge: charge)
        let judgedNeeded = parts.contains(.damage) || parts.contains(.structure)
        let glassNeeded = parts.contains(.glass)
        var itemOf = [[Int]](repeating: [], count: objects.count)
        var needed = [Int](repeating: 0, count: objects.count)
        itemOf.withUnsafeMutableBufferPointer { out in
            needed.withUnsafeMutableBufferPointer { counts in
                concurrently(iterations: (objects.count + 63) / 64) { chunk in
                    for n in (chunk * 64)..<min(objects.count, (chunk + 1) * 64) {
                        let facades = groupLayout[n].facades
                        out[n] = picked[n].map { choice -> Int in
                            (judgedNeeded && choice.judged)
                                || (glassNeeded && mixes[n] != nil && facades[choice.index])
                                ? 0 : -1
                        }
                        counts[n] = out[n].reduce(0) { $0 + ($1 == 0 ? 1 : 0) }
                    }
                }
            }
        }
        var first = [Int](repeating: 0, count: objects.count + 1)
        for n in objects.indices { first[n + 1] = first[n] + needed[n] }
        let count = first[objects.count]
        itemOf.withUnsafeMutableBufferPointer { out in
            concurrently(iterations: (objects.count + 63) / 64) { chunk in
                for n in (chunk * 64)..<min(objects.count, (chunk + 1) * 64) {
                    var next = first[n]
                    for c in out[n].indices where out[n][c] == 0 {
                        out[n][c] = next
                        next += 1
                    }
                }
            }
        }
        var items = [SIMD2<Int32>](repeating: .zero, count: count)
        var centres = [SIMD4<Float>](repeating: .zero, count: count)
        var facingsOut = [SIMD4<Float>](repeating: .zero, count: count)
        var owners = [SIMD2<Int32>](repeating: .zero, count: count)
        items.withUnsafeMutableBufferPointer { itemsOut in
            centres.withUnsafeMutableBufferPointer { centresOut in
                facingsOut.withUnsafeMutableBufferPointer { facingOut in
                    owners.withUnsafeMutableBufferPointer { ownersOut in
                        concurrently(iterations: (objects.count + 63) / 64) { chunk in
                            for n in (chunk * 64)..<min(objects.count, (chunk + 1) * 64) {
                                let layout = groupLayout[n]
                                for (c, choice) in picked[n].enumerated() {
                                    let item = itemOf[n][c]
                                    guard item >= 0 else { continue }
                                    let component = components[n][choice.index]
                                    itemsOut[item] = SIMD2(Int32(n), Int32(choice.index))
                                    centresOut[item] = SIMD4(
                                        layout.centres[choice.index], Float(component.axis))
                                    facingOut[item] = SIMD4(
                                        facings[n][choice.index], Float(component.outward))
                                    ownersOut[item] = SIMD2(Int32(n), component.kind == .roof ? 1 : 0)
                                }
                            }
                        }
                    }
                }
            }
        }
        let request = LiveResponse.LoadRequest(
            identity: identity, raster: raster,
            components: LiveResponse.LoadRequest.Components(district: components, items: items),
            centres: centres,
            facings: facingsOut, owners: owners, factors: [Float](repeating: 1, count: count), charge: charge,
            openReachM: open, mass: mass, cellSize: cellSize, coefficients: coefficients,
            roofCoefficients: roofCoefficients)
        return (request, picked, itemOf)
    }
}
