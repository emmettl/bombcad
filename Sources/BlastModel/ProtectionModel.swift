import Foundation
import simd

/// BombCAD's side of the protective-design search (docs/protective-design.md, "In BombCAD"): each
/// map building side's chance that its glass is thrown worse than its target condition, from the
/// façade load surrogate under each threat (moved by the stand-offs in place), drawn over the
/// surrogate's scatter and each building's glass strength, for each glazing the user allows; and
/// the problem `ProtectionSearch` searches. The glass only: the surrogate's walls and roofs are not
/// to be relied on.
public enum ProtectionModel {
    /// A charge the site may face, and how likely it is against the others.
    public struct Threat: Codable, Sendable, Hashable {
        public var mass: Double
        public var x: Double
        public var y: Double
        public var weight: Double

        public init(mass: Double, x: Double, y: Double, weight: Double = 1) {
            self.mass = mass
            self.x = x
            self.y = y
            self.weight = weight
        }
    }

    /// A glazing a side may be given instead of its own: its panes' sizes kept, their glass
    /// changed (`GlazingMix.Glass`), or the windows filled in.
    public struct Glazing: Codable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// Fully toughened (E1300's factor of 4 on its strength).
            case toughened
            /// Each pane laminated (`LaminatedGlass.facade` unless `laminate` says).
            case laminated
            /// Security film on each pane (7 mil, wet glazed, unless `film` says).
            case filmed
            /// The windows filled in: no glass.
            case infill
        }
        public var name: String
        public var kind: Kind
        /// Per square metre of glass.
        public var costPerM2: Double
        public var laminate: LaminatedGlass?
        public var film: SecurityFilm?

        public init(
            name: String, kind: Kind, costPerM2: Double, laminate: LaminatedGlass? = nil,
            film: SecurityFilm? = nil
        ) {
            self.name = name
            self.kind = kind
            self.costPerM2 = costPerM2
            self.laminate = laminate
            self.film = film
        }

        /// A side's windows `mix` given this glazing.
        public func applied(to mix: GlazingMix) -> GlazingMix {
            switch kind {
            case .toughened: return mix.with(.init(toughened: true))
            case .laminated: return mix.with(.init(laminate: laminate ?? .facade))
            case .filmed: return mix.with(.init(film: film ?? .mils(7, anchorage: .wetGlazed)))
            case .infill:
                var filled = mix
                filled.glazedFraction = 0
                return filled
            }
        }
    }

    /// A stand-off line: the threats it keeps back, each moved to where it would be stopped. Either
    /// one of the scene's lines by name (`Scenario.standOffLines`), each threat it guards against
    /// moved to its stop point (`StandOffLine.stopPoint`), or the moves given.
    public struct StandOff: Codable, Sendable {
        public struct Move: Codable, Sendable {
            public var threat: Int
            public var x: Double
            public var y: Double

            public init(threat: Int, x: Double, y: Double) {
                self.threat = threat
                self.x = x
                self.y = y
            }
        }
        public var name: String
        public var cost: Double
        /// The scene's stand-off line it puts up, by name.
        public var line: String?
        public var moves: [Move]?

        public init(name: String, cost: Double, line: String? = nil, moves: [Move]? = nil) {
            self.name = name
            self.cost = cost
            self.line = line
            self.moves = moves
        }
    }

    /// A barrier wall the site may build, along x or y between two points on the plan, standing on
    /// the lowest ground under it (`Scenario.addBarrier`): the surrogate's loads see it as they see
    /// the scene's fixed blocks, buildings crossed and shadow behind it.
    public struct Barrier: Codable, Sendable {
        public var name: String
        public var cost: Double
        public var from: SIMD2<Float>
        public var to: SIMD2<Float>
        public var height: Float
        public var thickness: Float?

        public init(
            name: String, cost: Double, from: SIMD2<Float>, to: SIMD2<Float>, height: Float,
            thickness: Float? = nil
        ) {
            self.name = name
            self.cost = cost
            self.from = from
            self.to = to
            self.height = height
            self.thickness = thickness
        }
    }

    /// The target: no pane of a side thrown worse than `worseThan` (a GSA condition: "3a", "3b",
    /// "4"), except with at most `chance`; another condition per building by name where
    /// `buildings` says (an unoccupied store's "4", say).
    public struct Target: Codable, Sendable {
        public struct Override: Codable, Sendable {
            public var worseThan: String?

            public init(worseThan: String?) { self.worseThan = worseThan }
        }
        public var worseThan: String
        public var chance: Double
        public var buildings: [String: Override]?

        public init(worseThan: String, chance: Double, buildings: [String: Override]? = nil) {
            self.worseThan = worseThan
            self.chance = chance
            self.buildings = buildings
        }
    }

    /// The user's file: the threat, the target, the changes allowed and their costs.
    public struct Inputs: Codable, Sendable {
        public var threats: [Threat]
        public var target: Target
        public var glazing: [Glazing]
        public var standOffs: [StandOff]?
        /// Barrier walls the site may build; after the stand-offs among the site-wide changes.
        public var barriers: [Barrier]?
        public var draws: Int?
        public var seed: UInt64?

        public init(
            threats: [Threat], target: Target, glazing: [Glazing], standOffs: [StandOff]? = nil,
            barriers: [Barrier]? = nil, draws: Int? = nil, seed: UInt64? = nil
        ) {
            self.threats = threats
            self.target = target
            self.glazing = glazing
            self.standOffs = standOffs
            self.barriers = barriers
            self.draws = draws
            self.seed = seed
        }
    }

    /// A building side: its owner, its strips and their glazed area.
    struct Side {
        var object: Int
        var name: String
        var axis: Int
        var outward: Int
        var mix: GlazingMix
        var strips: [EnvelopeComponent]
        var glazedM2: Double
        var condition: GlazingHazard.Condition

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            object: Int,
            name: String,
            axis: Int,
            outward: Int,
            mix: GlazingMix,
            strips: [EnvelopeComponent],
            glazedM2: Double,
            condition: GlazingHazard.Condition
        ) {
            self.object = object
            self.name = name
            self.axis = axis
            self.outward = outward
            self.mix = mix
            self.strips = strips
            self.glazedM2 = glazedM2
            self.condition = condition
        }
    }

    /// The district's sides, their options and the search's problem.
    public struct Model: Sendable {
        public let problem: ProtectionSearch.Problem
        /// Each side's building's name and its face ("east", …), in the problem's order.
        public let names: [String]
        public let glazedM2: [Double]
        public let condition: [GlazingHazard.Condition]
        /// Each side's building, by id, and which way it faces.
        public let owners: [UUID]
        public let axes: [Int]
        public let outwards: [Int]
        /// Each side's windows as built.
        public let mixes: [GlazingMix]
        public let glazing: [Glazing]
        /// Each side's building by its index in the scene's envelopes, and the chances' draws and
        /// seed: what `strength(seed:draw:object:)` takes to draw a side's glass as its chance did.
        public let objects: [Int]
        public let draws: Int
        public let seed: UInt64
    }

    /// The constructions `plan` writes into the scene: each building with a side changed, its
    /// construction with that side's windows as the plan gives them (`EnvelopeConstruction.sideGlazing`).
    public static func constructions(_ plan: ProtectionSearch.Plan, model: Model, scene: Scenario)
        -> [EnvelopeConstruction]
    {
        var changed: [UUID: EnvelopeConstruction] = [:]
        for (s, option) in plan.choices.enumerated() where option != 0 {
            let id = model.owners[s]
            var construction = changed[id] ?? scene.envelopeConstruction(for: id)
            var sides = construction.sideGlazing ?? [:]
            sides[EnvelopeConstruction.sideKey(axis: model.axes[s], outward: model.outwards[s])] =
                model.glazing[option - 1].applied(to: model.mixes[s])
            construction.sideGlazing = sides
            changed[id] = construction
        }
        return changed.values.sorted { $0.objectID.uuidString < $1.objectID.uuidString }
    }

    public enum InputError: Error, CustomStringConvertible {
        case condition(String)
        case line(String)
        case standOff(String)
        case barrier(String, String)
        case noGlass

        public var description: String {
            switch self {
            case .condition(let text): "\(text) is not a GSA condition (1, 2, 3a, 3b, 4, 5)"
            case .line(let name): "the scene has no stand-off line named \(name)"
            case .standOff(let name): "the stand-off \(name) names neither a line of the scene's nor moves"
            case .barrier(let name, let why): "the barrier \(name): \(why)"
            case .noGlass: "no building has glazing to protect"
            }
        }
    }

    /// Each stand-off's moves: those given, or each threat stopped at the scene's line.
    static func moves(_ inputs: Inputs, scene: Scenario) throws -> [[StandOff.Move]] {
        try (inputs.standOffs ?? []).map { standOff in
            if let name = standOff.line {
                guard let line = scene.standOffLines?.first(where: { $0.name == name }) else {
                    throw InputError.line(name)
                }
                return inputs.threats.enumerated().map { n, threat in
                    let stop = line.stopPoint(for: SIMD2(Float(threat.x), Float(threat.y)))
                    return StandOff.Move(threat: n, x: Double(stop.x), y: Double(stop.y))
                }
            }
            guard let moves = standOff.moves else { throw InputError.standOff(standOff.name) }
            return moves
        }
    }

    /// Each barrier's wall, as `Scenario.addBarrier` builds it on `scene`'s ground.
    static func barrierBoxes(_ inputs: Inputs, scene: Scenario) throws -> [Box] {
        try (inputs.barriers ?? []).map { barrier in
            var scratch = scene
            do {
                let id = try scratch.addBarrier(
                    from: barrier.from, to: barrier.to, height: barrier.height,
                    thickness: barrier.thickness ?? 0.3)
                guard let box = scratch.object(id: id)?.fixedBox else { throw SceneObjectError.missingObject }
                return box
            } catch {
                throw InputError.barrier(barrier.name, "\(error)")
            }
        }
    }

    static func condition(_ text: String) throws -> GlazingHazard.Condition {
        guard let condition = GlazingHazard.Condition(rawValue: text) else {
            throw InputError.condition(text)
        }
        return condition
    }

    /// The model of `scene`'s map buildings (those with a glazing mix) on cells `cellSize` m across.
    public static func model(
        scene: Scenario, cellSize: Float, inputs: Inputs,
        coefficients: FacadeLoadSurrogate.Coefficients = .fitted
    ) throws -> Model {
        let objects = scene.envelopeObjects
        let raster = FacadeLoadSurrogate.Raster(
            objects: objects, blocks: scene.boxes, terrain: scene.terrain, cell: cellSize)
        let moves = try Self.moves(inputs, scene: scene)
        let walls = try Self.barrierBoxes(inputs, scene: scene)
        var sides: [Side] = []
        for (n, object) in objects.enumerated() {
            guard let mix = scene.envelopeConstruction(for: object.id).glazing, let envelope = object.envelope
            else {
                continue
            }
            let override = inputs.target.buildings?[object.name]
            let condition = try Self.condition(override?.worseThan ?? inputs.target.worseThan)
            let strips = envelope.components(owner: object.id, cellSize: cellSize)
                .filter { $0.kind == .facade && FacadeLoadSurrogate.facesAir($0, raster: raster) }
            for (key, members) in Dictionary(grouping: strips, by: { $0.axis * 2 + ($0.outward > 0 ? 1 : 0) })
                .sorted(by: { $0.key < $1.key })
            {
                let axis = key / 2
                let outward = key % 2 == 1 ? 1 : -1
                let face = axis == 0 ? (outward > 0 ? "east" : "west") : (outward > 0 ? "north" : "south")
                let area = members.reduce(0.0) { $0 + Double($1.spans.x * $1.spans.y) }
                sides.append(
                    Side(
                        object: n, name: "\(object.name) \(face)", axis: axis, outward: outward, mix: mix,
                        strips: members, glazedM2: area * Double(mix.glazedFraction), condition: condition))
            }
        }
        guard !sides.isEmpty else { throw InputError.noGlass }
        let accepted = inputs.target.chance
        let options = sides.map { side -> [ProtectionSearch.Option] in
            [ProtectionSearch.Option(glazing: "as built", wall: "as built", cost: 0)]
                + inputs.glazing.map {
                    ProtectionSearch.Option(
                        glazing: $0.name, wall: "as built", cost: $0.costPerM2 * side.glazedM2)
                }
        }
        let searchSides = zip(sides, options).map { ProtectionSearch.Side(name: $0.name, options: $1) }
        let site =
            (inputs.standOffs ?? []).map { ProtectionSearch.SiteChange(name: $0.name, cost: $0.cost) }
            + (inputs.barriers ?? []).map { ProtectionSearch.SiteChange(name: $0.name, cost: $0.cost) }
        let evaluator = Evaluator(
            sides: sides, objects: objects, raster: raster, inputs: inputs, cellSize: cellSize,
            coefficients: coefficients, moves: moves, walls: walls, blocks: scene.boxes,
            terrain: scene.terrain)
        let problem = ProtectionSearch.Problem(sides: searchSides, site: site, targetChance: accepted) {
            site, side, option in
            evaluator.chance(site: site, side: side, option: option)
        }
        return Model(
            problem: problem, names: sides.map(\.name), glazedM2: sides.map(\.glazedM2),
            condition: sides.map(\.condition), owners: sides.map { objects[$0.object].id },
            axes: sides.map(\.axis),
            outwards: sides.map(\.outward), mixes: sides.map(\.mix), glazing: inputs.glazing,
            objects: sides.map(\.object), draws: max(1, inputs.draws ?? 64), seed: inputs.seed ?? 1)
    }

    /// Draw `draw`'s glass strength for building `object` (by its index in the scene's envelopes),
    /// over the flaw model's median: the same as the chances draw it, for judging them on a run.
    public static func strength(seed: UInt64, draw: Int, object: Int) -> Double {
        exp(0.25 * FacadeLoadSurrogate.Random.normal(seed, 2, UInt64(draw), UInt64(object)))
    }

    /// Every chance the exact search asks for, worked out on every core first.
    public static func prepare(_ model: Model) {
        let problem = model.problem
        var asks: [([Int], Int, Int)] = []
        for k in 0...problem.site.count {
            for site in ProtectionSearch.combinations(problem.site.count, k) {
                for (s, side) in problem.sides.enumerated() {
                    for o in side.options.indices { asks.append((site, s, o)) }
                }
            }
        }
        concurrently(iterations: asks.count) { n in _ = problem.chance(asks[n].0, asks[n].1, asks[n].2) }
    }

    /// The chances behind the problem: the surrogate's loads for each threat place, remembered,
    /// and each side's draws.
    final class Evaluator: @unchecked Sendable {
        let sides: [Side]
        let objects: [SceneObject]
        let raster: FacadeLoadSurrogate.Raster
        let inputs: Inputs
        let cellSize: Float
        let coefficients: FacadeLoadSurrogate.Coefficients
        let draws: Int
        let seed: UInt64
        let table = FacadeLoadSurrogate.GlassTable(binS: 0.7e-3)
        /// Each stand-off's moves, and each barrier's wall: the site-wide changes, stand-offs first.
        let moves: [[StandOff.Move]]
        let walls: [Box]
        let blocks: [Box]
        let terrain: Terrain?
        private let lock = NSLock()
        private var features: [[Int]: [FacadeLoadSurrogate.Features]] = [:]
        private var rasters: [[Int]: FacadeLoadSurrogate.Raster] = [:]

        init(
            sides: [Side], objects: [SceneObject], raster: FacadeLoadSurrogate.Raster, inputs: Inputs,
            cellSize: Float, coefficients: FacadeLoadSurrogate.Coefficients, moves: [[StandOff.Move]] = [],
            walls: [Box] = [], blocks: [Box] = [], terrain: Terrain? = nil
        ) {
            self.sides = sides
            self.objects = objects
            self.raster = raster
            self.inputs = inputs
            self.cellSize = cellSize
            self.coefficients = coefficients
            self.moves = moves
            self.walls = walls
            self.blocks = blocks
            self.terrain = terrain
            draws = max(1, inputs.draws ?? 64)
            seed = inputs.seed ?? 1
        }

        /// The threats with the stand-offs among `site` in place.
        func threats(_ site: [Int]) -> [Threat] {
            var threats = inputs.threats
            for i in site where i < moves.count {
                for move in moves[i] where threats.indices.contains(move.threat) {
                    threats[move.threat].x = move.x
                    threats[move.threat].y = move.y
                }
            }
            return threats
        }

        /// The barriers among `site`, by their index among the barriers.
        func barriers(_ site: [Int]) -> [Int] { site.filter { $0 >= moves.count }.map { $0 - moves.count } }

        /// The raster with `barriers` built, remembered.
        func raster(_ barriers: [Int]) -> FacadeLoadSurrogate.Raster {
            guard !barriers.isEmpty else { return raster }
            lock.lock()
            defer { lock.unlock() }
            if let known = rasters[barriers] { return known }
            let made = FacadeLoadSurrogate.Raster(
                objects: objects, blocks: blocks + barriers.map { walls[$0] }, terrain: terrain,
                cell: cellSize)
            rasters[barriers] = made
            return made
        }

        /// `side`'s strips' features with a charge at `threat`'s place and `barriers` built, remembered.
        func features(_ side: Int, _ threat: Threat, barriers: [Int] = []) -> [FacadeLoadSurrogate.Features] {
            let key = [side, Int(threat.x * 1000), Int(threat.y * 1000)] + barriers
            lock.lock()
            if let known = features[key] {
                lock.unlock()
                return known
            }
            lock.unlock()
            let s = sides[side]
            let raster = raster(barriers)
            let ground = raster.terrain?.height(at: SIMD2(Float(threat.x), Float(threat.y))) ?? 0
            let charge = SIMD3(Float(threat.x), Float(threat.y), ground + 0.5)
            let made = s.strips.map {
                FacadeLoadSurrogate.features($0, owner: s.object, charge: charge, raster: raster)
            }
            lock.lock()
            features[key] = made
            lock.unlock()
            return made
        }

        /// The chance that some pane of `side`, as option `option`, is thrown worse than its
        /// target condition, the threats weighted, with the stand-offs `site` in place.
        func chance(site: [Int], side: Int, option: Int) -> Double {
            let s = sides[side]
            let mix = option == 0 ? s.mix : inputs.glazing[option - 1].applied(to: s.mix)
            guard mix.glazedFraction > 0 else { return 0 }
            let threats = threats(site)
            let built = barriers(site)
            let total = threats.reduce(0) { $0 + $1.weight }
            var chance = 0.0
            for threat in threats where threat.weight > 0 {
                let features = features(side, threat, barriers: built)
                let middle = features.map(\.distanceM).sorted()[features.count / 2]
                let scatter = FacadeLoadSurrogate.Uncertainty().scatter(atZ: middle / cbrt(threat.mass))
                var sum = 0.0
                for k in 0..<draws {
                    let strength = ProtectionModel.strength(seed: seed, draw: k, object: s.object)
                    var errors = SIMD2<Double>.zero
                    if let scatter {
                        let a = FacadeLoadSurrogate.Random.normal(seed, 3, UInt64(k), UInt64(side))
                        let b = FacadeLoadSurrogate.Random.normal(seed, 4, UInt64(k), UInt64(side))
                        let r = scatter.correlation
                        errors = SIMD2(
                            scatter.peak * a, scatter.impulse * (r * a + (1 - r * r).squareRoot() * b))
                    }
                    var logNone = 0.0
                    for (strip, f) in zip(s.strips, features) {
                        var p = FacadeLoadSurrogate.predict(
                            f, mass: threat.mass, cellSize: Double(cellSize), coefficients: coefficients)
                        p.peakPa *= exp(errors.x)
                        p.impulsePaS *= exp(errors.y)
                        logNone +=
                            table.outcome(
                                mix, prediction: p, areaM2: Double(strip.spans.x * strip.spans.y),
                                strength: strength,
                                worseThan: s.condition
                            ).logNoneWorse
                    }
                    sum += 1 - exp(logNone)
                }
                chance += threat.weight / total * sum / Double(draws)
            }
            return chance
        }
    }
}
