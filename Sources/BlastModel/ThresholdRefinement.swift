import Foundation
import simd

/// The quick estimate's close calls refined by the solver (emmettl/bombcad-work#34): the buildings
/// whose chances lie near even, where a threshold falls within what the estimate does not know, run
/// in the air on a scene cut down round the charge and them (the hybrid near run's square, its open
/// faces a clearance beyond them), refined along corridors to them (`refinementCorridors`), and
/// their damage and chances judged from the loads the run recorded, in place of the estimate's.
/// Hooked in after the estimate: nothing here changes how the estimate is made.
public enum ThresholdRefinement {
    /// How unsettled a chance is: 1 at an even chance, 0 at none or at certainty.
    public static func doubt(_ chance: Double) -> Double { 1 - abs(2 * chance - 1) }

    /// The doubt from which a building is a close call: a chance between 0.2 and 0.8, where the
    /// estimate's own spread (the yield, the surrogate's scatter, the strengths) straddles the
    /// threshold.
    public static let closeCall = 0.4

    /// What a building's doubt is judged on: one of the view's chances, or all of them.
    public enum Quantity: Sendable, Hashable, CaseIterable {
        case someBroken, blownOut, thrownPast3b, openingsBlownOut, wallsModerate, wallsHeavy, roofModerate

        /// What the damage colouring shows: the walls' and roof's levels, and windows blown out.
        public static let damage: Set<Quantity> = [.blownOut, .wallsModerate, .wallsHeavy, .roofModerate]
    }

    /// Each building's doubt, its most unsettled chance among `quantities` (each side's glass, its
    /// walls' and roof's).
    public static func doubts(
        glass: [FacadeLoadSurrogate.SideGlass], structure: [FacadeLoadSurrogate.StructureChance],
        quantities: Set<Quantity> = Quantity.damage
    ) -> [UUID: Double] {
        var doubts: [UUID: Double] = [:]
        func note(_ owner: UUID, _ chance: Double, _ quantity: Quantity) {
            guard quantities.contains(quantity) else { return }
            doubts[owner] = max(doubts[owner] ?? 0, doubt(chance))
        }
        for side in glass {
            note(side.owner, side.someBroken, .someBroken)
            note(side.owner, side.blownOut, .blownOut)
            note(side.owner, side.thrownPast3b, .thrownPast3b)
            note(side.owner, side.openingsBlownOut, .openingsBlownOut)
        }
        for building in structure {
            note(building.owner, building.wallsModerate, .wallsModerate)
            note(building.owner, building.wallsHeavy, .wallsHeavy)
            note(building.owner, building.roofModerate, .roofModerate)
        }
        return doubts
    }

    /// What a refinement runs: the buildings, nearest the charge first; the near scene, cut from the
    /// whole one and moved so that its corner is the origin (`shift` added to every point), on the
    /// same cells; the corridors toward the buildings in it; and when each building's load is in,
    /// in the run's time.
    public struct Plan: Sendable {
        public var buildings: [UUID]
        public var scene: Scenario
        public var shift: SIMD3<Float>
        public var corridors: [RefinementRegion]
        /// When the blast has passed each building and its load is recorded, s.
        public var readyAtS: [UUID: Double]
        /// Each building's draws' key in the whole scene (`SceneObject.drawKey`), which its moved
        /// copy in the near scene does not share.
        public var drawKeys: [UUID: UInt64]
        public var untilS: Double { readyAtS.values.max() ?? 0 }
        public var cells: Int
        /// Close calls left out: beyond `maxBuildings`, or too far for the cells allowed.
        public var leftOut: Int
    }

    /// Why a scene has no plan.
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case noCloseCalls
        case unsupported(String)
        case tooLarge(cells: Int)

        public var description: String {
            switch self {
            case .noCloseCalls: "no building's chances lie between 0.2 and 0.8"
            case .unsupported(let what): "not offered for scenes with \(what)"
            case .tooLarge(let cells):
                "the nearest close call needs \(cells / 1_000_000) million cells, more than allowed"
            }
        }
    }

    /// How long after the blast first reaches a building its load is kept, s: about twice the
    /// positive phase in the open (Kingery–Bulmash's 2–4 ms/kg^(1/3) over the district's scaled
    /// distances) and the panels' response to it, never less than 30 ms.
    public static func holdS(mass: Double) -> Double { max(0.006 * cbrt(mass), 0.03) }

    /// The clearance between the buildings refined and the near scene's open faces, m: 4 m/kg^(1/3),
    /// as the hybrid near run took (docs/hybrid-far-field.md, and "Open faces near structures"), and
    /// at least eight cells.
    public static func clearance(mass: Double, cellSize: Float) -> Float {
        max(4 * Float(cbrt(mass)), 8 * cellSize)
    }

    /// The plan for refining `scene`'s close calls by `doubts` (`doubts(glass:structure:)`): up to
    /// `maxBuildings` of them, nearest the charge first, so long as the near scene round them takes
    /// no more than `maxCells` cells of `cellSize`.
    public static func plan(
        scene: Scenario, cellSize: Float, doubts: [UUID: Double], maxBuildings: Int = 8, maxCells: Int
    ) throws -> Plan {
        if let what = unsupported(scene) { throw Refusal.unsupported(what) }
        let charge = scene.charge.position
        let centre = SIMD2(charge.x, charge.y)
        let mass = Double(scene.charge.mass)
        // Each close call's extent and its farthest corner's reach along x or y (the square's half
        // side it needs) and over the ground (when the blast has passed it).
        var calls: [(id: UUID, box: Box, square: Float, reach: Float)] = []
        for object in scene.envelopeObjects {
            guard (doubts[object.id] ?? 0) >= closeCall, let box = object.bounds else { continue }
            let low = SIMD2(box.min.x, box.min.y) - centre
            let high = SIMD2(box.max.x, box.max.y) - centre
            let far = simd_max(simd_abs(low), simd_abs(high))
            calls.append((object.id, box, max(far.x, far.y), simd_length(far)))
        }
        guard !calls.isEmpty else { throw Refusal.noCloseCalls }
        calls.sort { ($0.square, $0.id.uuidString) < ($1.square, $1.id.uuidString) }
        let clearance = clearance(mass: mass, cellSize: cellSize)
        func square(_ half: Float) -> (low: SIMD3<Float>, high: SIMD3<Float>, cells: Int) {
            let size = scene.domainSize
            // On the whole scene's cells, so that every building voxelises as it does there.
            let low = simd_max((SIMD2(centre - half) / cellSize).rounded(.down) * cellSize, .zero)
            let high = simd_min(
                (SIMD2(centre + half) / cellSize).rounded(.up) * cellSize, SIMD2(size.x, size.y))
            let n = (high - low) / cellSize
            let nz = (size.z / cellSize).rounded(.up)
            return (SIMD3(low, 0), SIMD3(high, size.z), Int(n.x.rounded() * n.y.rounded() * nz))
        }
        var count = min(calls.count, maxBuildings)
        while count > 0, square(calls[count - 1].square + clearance).cells > maxCells { count -= 1 }
        guard count > 0 else { throw Refusal.tooLarge(cells: square(calls[0].square + clearance).cells) }
        let chosen = Array(calls.prefix(count))
        let crop = square(chosen[count - 1].square + clearance)
        let near = try cut(scene, low: crop.low, high: crop.high)
        let shift = -crop.low
        // The blast's arrival in the open at the far corner, a tenth later for the streets it
        // threads, and the hold after it.
        let hold = holdS(mass: mass)
        var ready: [UUID: Double] = [:]
        for call in chosen {
            let z = Double(call.reach) / cbrt(mass)
            let arrival = KingeryBulmash.point(at: z)?.arrival(mass: mass) ?? Double(call.reach) / 340
            ready[call.id] = 1.1 * arrival + hold
        }
        let ids = chosen.map(\.id)
        let keys = Dictionary(
            uniqueKeysWithValues: scene.envelopeObjects.filter { ready[$0.id] != nil }.map {
                ($0.id, $0.drawKey)
            })
        return Plan(
            buildings: ids, scene: near, shift: shift, corridors: near.refinementCorridors(toward: ids) ?? [],
            readyAtS: ready, drawKeys: keys, cells: crop.cells, leftOut: calls.count - count)
    }

    /// What in `scene` the near scene cannot carry: nil if nothing.
    static func unsupported(_ scene: Scenario) -> String? {
        if !scene.structuralObjects.isEmpty { return "structures" }
        if scene.deflagration != nil { return "a gas cloud" }
        if !(scene.ventPanels ?? []).isEmpty { return "vent panels" }
        if !(scene.congestion ?? []).isEmpty { return "congestion" }
        if !(scene.rigidObjects ?? []).isEmpty || !(scene.rigidCars ?? []).isEmpty { return "free objects" }
        if !(scene.additionalCharges ?? []).isEmpty { return "more than one charge" }
        return nil
    }

    /// `scene` cut to the box from `low` to `high` (whole cells of the scene's own) and moved so
    /// that `low` is the origin: the envelopes wholly inside it, the blocks clipped to it, the
    /// terrain under it, the charge; no gauges and no stand-off lines.
    static func cut(_ scene: Scenario, low: SIMD3<Float>, high: SIMD3<Float>) throws -> Scenario {
        var near = scene
        let shift = -low
        let size = high - low
        near.domainSize = size
        near.charge.position += shift
        near.gauges = []
        near.standOffLines = nil
        var objects: [SceneObject] = []
        for object in scene.objects {
            if let box = object.fixedBox {
                let lo = simd_max(box.min + shift, .zero)
                let hi = simd_min(box.max + shift, size)
                guard all(lo .< hi) else { continue }
                objects.append(
                    SceneObject(
                        id: object.id, name: object.name, representation: .fixed(Box(min: lo, max: hi))))
            } else if let envelope = object.envelope, let box = object.bounds {
                guard all(box.min .>= low), all(box.max .<= high) else { continue }
                objects.append(
                    SceneObject(
                        id: object.id, name: object.name,
                        representation: .envelope(try envelope.translated(by: shift))))
            }
        }
        near.objects = objects
        near.terrain = scene.terrain.map { whole in
            var piece = whole.cropped(low: SIMD2(low.x, low.y), high: SIMD2(high.x, high.y))
            piece.origin += SIMD2(shift.x, shift.y)
            return piece
        }
        return near
    }

    /// A refinement's results, for the buildings whose loads are in: their damage, their sides'
    /// glass chances and their walls' and roofs', as the estimate gives them, from the run's loads.
    public struct Refined: Sendable {
        public var buildings: [UUID] = []
        public var damage: [EnvelopeBuildingDamage] = []
        public var glass: [FacadeLoadSurrogate.SideGlass] = []
        public var structure: [FacadeLoadSurrogate.StructureChance] = []
        public init() {}
    }

    /// The results for `buildings` from the near run's `histories` (`plan.scene`'s components):
    /// their damage as a run judges it; and their chances drawn as the estimate's are, over each
    /// building's glass and wall strength, by the same draws (`plan.drawKeys`), but on the run's
    /// loads, at the scene's charge, so with neither the estimate's yield nor its load scatter.
    public static func judge(
        histories: [EnvelopeComponentHistory], buildings: [UUID], plan: Plan,
        uncertainty: FacadeLoadSurrogate.Uncertainty = FacadeLoadSurrogate.Uncertainty()
    ) -> Refined {
        let scene = plan.scene
        let wanted = Set(buildings)
        let loads = histories.filter { !$0.invalid && wanted.contains($0.component.owner) }
            .map(EnvelopeComponentLoad.init)
        var refined = Refined()
        refined.buildings = buildings
        let rooms = Dictionary(
            uniqueKeysWithValues: scene.envelopeObjects.filter { wanted.contains($0.id) }.map {
                ($0.id, EnvelopeDamageAssessment.roomVolume(of: $0.envelope!))
            })
        refined.damage = EnvelopeDamageAssessment.assess(
            loads: loads, constructions: { scene.envelopeConstruction(for: $0) }, rooms: rooms)
        let byOwner = Dictionary(grouping: loads, by: \.owner)
        let charge = scene.charge.position
        let draws = max(1, uncertainty.samples)
        // Every side of every building, each draw on a thread of its own, and every wall and roof:
        // a building's few sides and many strips would otherwise keep most of the cores idle.
        var sides: [GlassSide] = []
        var parts: [(building: Int, load: EnvelopeComponentLoad, roof: Bool)] = []
        let built = buildings.map { scene.envelopeConstruction(for: $0) }
        var tops = [Double](repeating: 0, count: buildings.count)
        var bases = [Double](repeating: 0, count: buildings.count)
        for (b, owner) in buildings.enumerated() {
            let mine = byOwner[owner] ?? []
            tops[b] = mine.map { Double($0.region.max.z) }.max() ?? 0
            bases[b] = mine.map { Double($0.region.min.z) }.min() ?? 0
            if let mix = built[b].glazing {
                let strips = mine.filter { $0.kind == .facade }
                for (key, members) in Dictionary(
                    grouping: strips, by: { $0.axis * 2 + ($0.outward > 0 ? 1 : 0) }
                )
                .sorted(by: { $0.key < $1.key }) {
                    sides.append(GlassSide(building: b, key: key, mix: mix, members: members, charge: charge))
                }
            }
            parts += mine.filter { [.facade, .wall, .roof].contains($0.kind) }.map {
                (b, $0, $0.kind == .roof)
            }
        }
        var outcomes = [FacadeLoadSurrogate.GlassOutcome](repeating: .init(), count: sides.count * draws)
        outcomes.withUnsafeMutableBufferPointer { out in
            concurrently(iterations: sides.count * draws) { n in
                let side = sides[n / draws]
                let k = n % draws
                let key = plan.drawKeys[buildings[side.building]] ?? 0
                let strength =
                    uncertainty.strengthMedian
                    * exp(uncertainty.strengthLogSD * uncertainty.normal(2, k, key, draws: draws))
                var outcome = FacadeLoadSurrogate.GlassOutcome()
                for (net, area) in zip(side.nets, side.areas) {
                    outcome =
                        outcome
                        + FacadeLoadSurrogate.glassOutcome(
                            side.mix, netPa: net, binS: side.binS, areaM2: area, strength: strength)
                }
                out[n] = outcome
            }
        }
        refined.glass = sides.enumerated().map { s, side in
            let mine = outcomes[(s * draws)..<((s + 1) * draws)]
            let n = Double(draws)
            return FacadeLoadSurrogate.SideGlass(
                owner: buildings[side.building], axis: side.key / 2, outward: side.key % 2 == 1 ? 1 : -1,
                distanceM: side.distanceM, someBroken: mine.reduce(0) { $0 + $1.glass.anyBroken } / n,
                blownOut: Double(mine.filter { $0.glass.fraction >= 0.9 }.count) / n,
                fractionBroken: mine.reduce(0) { $0 + $1.glass.fraction } / n,
                thrownPast3b: mine.reduce(0) { $0 + $1.worse } / n,
                openingsBlownOut: FacadeLoadSurrogate.OpeningsFragility.chance(peakPa: side.peakPa))
        }
        // Each wall's and roof's load factor at which it first reaches moderate, and heavy.
        var onsets = [SIMD2<Double>](repeating: .zero, count: parts.count)
        onsets.withUnsafeMutableBufferPointer { out in
            concurrently(iterations: parts.count) { n in
                let part = parts[n]
                let construction = built[part.building]
                let sd = FacadeLoadSurrogate.strengthLogSD(part.roof ? construction.roof : construction.walls)
                func level(_ factor: Double) -> Int {
                    var scaled = part.load
                    scaled.outerPa = part.load.outerPa.map { $0 * factor }
                    scaled.innerPa = part.load.innerPa.map { $0 * factor }
                    scaled.stripPa = part.load.stripPa.map {
                        ($0.outer.map { $0 * factor }, $0.inner.map { $0 * factor })
                    }
                    return EnvelopeDamageAssessment.assess(
                        scaled, construction: construction, buildingTop: tops[part.building],
                        buildingBase: bases[part.building]
                    )?.levels.upperBound.rawValue ?? 0
                }
                out[n] = SIMD2(
                    onset(sd: sd, target: EnvelopeDamageLevel.moderate.rawValue, level: level),
                    part.roof
                        ? .infinity : onset(sd: sd, target: EnvelopeDamageLevel.heavy.rawValue, level: level))
            }
        }
        refined.structure = buildings.enumerated().map { b, owner in
            let key = plan.drawKeys[owner] ?? 0
            let construction = built[b]
            let wallSD = FacadeLoadSurrogate.strengthLogSD(construction.walls)
            let roofSD = FacadeLoadSurrogate.strengthLogSD(construction.roof)
            var walls = SIMD2<Double>(repeating: .infinity)
            var roof = Double.infinity
            for (n, part) in parts.enumerated() where part.building == b {
                if part.roof { roof = min(roof, onsets[n].x) } else { walls = simd_min(walls, onsets[n]) }
            }
            var counts = SIMD3<Double>.zero
            for k in 0..<draws {
                // The building's weakness as the estimate draws it: its loads over its strength.
                let wallWeak = exp(-wallSD * uncertainty.normal(5, k, key, draws: draws))
                let roofWeak = exp(-roofSD * uncertainty.normal(6, k, key, draws: draws))
                counts.x += wallWeak >= walls.x ? 1 : 0
                counts.y += wallWeak >= walls.y ? 1 : 0
                counts.z += roofWeak >= roof ? 1 : 0
            }
            let n = Double(draws)
            return FacadeLoadSurrogate.StructureChance(
                owner: owner, wallsModerate: counts.x / n, wallsHeavy: counts.y / n,
                roofModerate: counts.z / n)
        }
        return refined
    }

    /// A building side's façade strips as the run loaded them: each one's net pressures and area,
    /// the side's highest pressure and its middle distance from the charge.
    struct GlassSide {
        var building: Int
        var key: Int
        var mix: GlazingMix
        var nets: [[Double]]
        var areas: [Double]
        var binS: Double
        var peakPa: Double
        var distanceM: Double

        init(building: Int, key: Int, mix: GlazingMix, members: [EnvelopeComponentLoad], charge: SIMD3<Float>)
        {
            self.building = building
            self.key = key
            self.mix = mix
            nets = members.map { load in zip(load.outerPa, load.innerPa).map { $0 - $1 } }
            areas = members.map { load in
                let spans = (0..<3).filter { $0 != load.axis }.map { Double(load.region.size[$0]) }
                return spans[0] * spans[1]
            }
            binS = members.first?.binS ?? 1e-4
            peakPa = members.map { $0.outerPa.max() ?? 0 }.max() ?? 0
            let distances = members.map { load -> Double in
                let middle = 0.5 * (load.region.min + load.region.max)
                return Double(simd_distance(SIMD2(middle.x, middle.y), SIMD2(charge.x, charge.y)))
            }.sorted()
            distanceM = distances.isEmpty ? 0 : distances[distances.count / 2]
        }
    }

    /// The load factor at which a component first reaches `target` by `level` (its level under its
    /// load times a factor), by halving between the weakest and the strongest draw it could take
    /// (2.5 standard deviations either way): the level rises with the load, so a draw reaches
    /// `target` where its weakness is at least that; infinity if not even the weakest does.
    static func onset(sd: Double, target: Int, level: (Double) -> Int) -> Double {
        var low = exp(-2.5 * sd)
        var high = exp(2.5 * sd)
        if level(high) < target { return .infinity }
        if level(low) >= target { return 0 }
        for _ in 0..<12 {
            let middle = (low * high).squareRoot()
            if level(middle) >= target { high = middle } else { low = middle }
        }
        return high
    }
}
