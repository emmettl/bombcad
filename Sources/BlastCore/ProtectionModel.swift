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

    /// A glazing a side may be given instead of its own.
    public struct Glazing: Codable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// Its panes' glass `strength` times stronger (fully toughened: E1300's factor of 4).
            case toughened
            /// Each pane laminated (`LaminatedGlass.facade` unless `laminate` says).
            case laminated
            /// The windows filled in: no glass.
            case infill
        }
        public var name: String
        public var kind: Kind
        /// Per square metre of glass.
        public var costPerM2: Double
        public var strength: Double?
        public var laminate: LaminatedGlass?
    }

    /// A stand-off line: the threats it keeps back, each moved to where it would be stopped.
    public struct StandOff: Codable, Sendable {
        public struct Move: Codable, Sendable {
            public var threat: Int
            public var x: Double
            public var y: Double
        }
        public var name: String
        public var cost: Double
        public var moves: [Move]
    }

    /// The target: no pane of a side thrown worse than `worseThan` (a GSA condition: "3a", "3b",
    /// "4"), except with at most `chance`; another condition per building by name where
    /// `buildings` says (an unoccupied store's "4", say).
    public struct Target: Codable, Sendable {
        public struct Override: Codable, Sendable {
            public var worseThan: String?
        }
        public var worseThan: String
        public var chance: Double
        public var buildings: [String: Override]?
    }

    /// The user's file: the threat, the target, the changes allowed and their costs.
    public struct Inputs: Codable, Sendable {
        public var threats: [Threat]
        public var target: Target
        public var glazing: [Glazing]
        public var standOffs: [StandOff]?
        /// Barrier walls: not yet (they need the wall as a scene element the surrogate's raster
        /// sees, roadmap #63); refused if given.
        public var barriers: [String]?
        public var draws: Int?
        public var seed: UInt64?
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
    }

    /// The district's sides, their options and the search's problem.
    public struct Model: Sendable {
        public let problem: ProtectionSearch.Problem
        /// Each side's building's name and its face ("east", …), in the problem's order.
        public let names: [String]
        public let glazedM2: [Double]
        public let condition: [GlazingHazard.Condition]
    }

    public enum InputError: Error, CustomStringConvertible {
        case condition(String)
        case barriers
        case noGlass

        public var description: String {
            switch self {
            case .condition(let text): "\(text) is not a GSA condition (1, 2, 3a, 3b, 4, 5)"
            case .barriers: "barrier walls are not yet a scene element the loads see (roadmap #63)"
            case .noGlass: "no building has glazing to protect"
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
        guard (inputs.barriers ?? []).isEmpty else { throw InputError.barriers }
        let objects = scene.envelopeObjects
        let raster = FacadeLoadSurrogate.Raster(objects: objects, terrain: scene.terrain, cell: cellSize)
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
        let site = (inputs.standOffs ?? []).map { ProtectionSearch.SiteChange(name: $0.name, cost: $0.cost) }
        let evaluator = Evaluator(
            sides: sides, objects: objects, raster: raster, inputs: inputs, cellSize: cellSize,
            coefficients: coefficients)
        let problem = ProtectionSearch.Problem(sides: searchSides, site: site, targetChance: accepted) {
            site, side, option in
            evaluator.chance(site: site, side: side, option: option)
        }
        return Model(
            problem: problem, names: sides.map(\.name), glazedM2: sides.map(\.glazedM2),
            condition: sides.map(\.condition))
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
        private let lock = NSLock()
        private var features: [[Int]: [FacadeLoadSurrogate.Features]] = [:]

        init(
            sides: [Side], objects: [SceneObject], raster: FacadeLoadSurrogate.Raster, inputs: Inputs,
            cellSize: Float, coefficients: FacadeLoadSurrogate.Coefficients
        ) {
            self.sides = sides
            self.objects = objects
            self.raster = raster
            self.inputs = inputs
            self.cellSize = cellSize
            self.coefficients = coefficients
            draws = max(1, inputs.draws ?? 64)
            seed = inputs.seed ?? 1
        }

        /// The threats with the stand-offs `site` in place.
        func threats(_ site: [Int]) -> [Threat] {
            var threats = inputs.threats
            for i in site {
                for move in inputs.standOffs![i].moves where threats.indices.contains(move.threat) {
                    threats[move.threat].x = move.x
                    threats[move.threat].y = move.y
                }
            }
            return threats
        }

        /// `side`'s strips' features with a charge at `threat`'s place, remembered.
        func features(_ side: Int, _ threat: Threat) -> [FacadeLoadSurrogate.Features] {
            let key = [side, Int(threat.x * 1000), Int(threat.y * 1000)]
            lock.lock()
            if let known = features[key] {
                lock.unlock()
                return known
            }
            lock.unlock()
            let s = sides[side]
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
            let glazing = option == 0 ? nil : inputs.glazing[option - 1]
            if glazing?.kind == .infill { return 0 }
            let threats = threats(site)
            let total = threats.reduce(0) { $0 + $1.weight }
            var chance = 0.0
            for threat in threats where threat.weight > 0 {
                let features = features(side, threat)
                var sum = 0.0
                for k in 0..<draws {
                    let strength =
                        ProtectionModel.strength(seed: seed, draw: k, object: s.object)
                        * (glazing?.kind == .toughened ? (glazing?.strength ?? 4) : 1)
                    let middle = features.map(\.distanceM).sorted()[features.count / 2]
                    var errors = SIMD2<Double>.zero
                    if let scatter = FacadeLoadSurrogate.Uncertainty().scatter(
                        atZ: middle / cbrt(threat.mass))
                    {
                        let a = FacadeLoadSurrogate.Random.normal(seed, 3, UInt64(k), UInt64(side))
                        let b = FacadeLoadSurrogate.Random.normal(seed, 4, UInt64(k), UInt64(side))
                        let r = scatter.correlation
                        errors = SIMD2(
                            scatter.peak * a, scatter.impulse * (r * a + (1 - r * r).squareRoot() * b))
                    }
                    var logNone = 0.0
                    var worse = 0.0
                    for (strip, f) in zip(s.strips, features) {
                        var p = FacadeLoadSurrogate.predict(
                            f, mass: threat.mass, cellSize: Double(cellSize), coefficients: coefficients)
                        p.peakPa *= exp(errors.x)
                        p.impulsePaS *= exp(errors.y)
                        let area = Double(strip.spans.x * strip.spans.y)
                        if glazing?.kind == .laminated {
                            worse = max(
                                worse,
                                table.laminatedWorse(
                                    s.mix, laminate: glazing?.laminate ?? .facade, prediction: p,
                                    areaM2: area,
                                    worseThan: s.condition))
                        } else {
                            logNone +=
                                table.outcome(
                                    s.mix, prediction: p, areaM2: area, strength: strength,
                                    worseThan: s.condition
                                ).logNoneWorse
                        }
                    }
                    sum += glazing?.kind == .laminated ? worse : 1 - exp(logNone)
                }
                chance += threat.weight / total * sum / Double(draws)
            }
            return chance
        }
    }
}
