import Foundation
import simd

/// The best protection for a budget (emmettl/bombcad-work#117, stage 2; docs/protective-design.md,
/// "The best protection for a budget"): barrier walls (where, which way, how tall and long), film or
/// laminated glass building by building, and a stand-off, chosen so that the people hurt (or the
/// glass thrown past GSA's 3b) are fewest for what the user will spend. The search asks a model of the
/// district (`Evaluator`): the learned response in the app, so that it answers in seconds; the full
/// estimate then referees its answer, as on any let-go.
///
/// The search splits the plan in two, as the planner's design does: the site-wide changes (the walls
/// and the stand-off), which change the loads on every side, by a coordinate search over the live
/// model; and the glass, which changes no load in the model (the envelopes are rigid) and so is each
/// building's own, chosen for the money left by a multiple-choice knapsack on each building's own
/// gain. Costs are the user's: the table shipped is illustrative, its sources cited
/// (`Costs.sources`).
public enum ProtectionBudget {
    /// Standing: illustrative. The loads and the glass the live model's, the people Kummer's or
    /// Bowen's, the costs an order of magnitude from vendors' price guides.
    public static let level = EvidenceLevel.illustrative

    // MARK: Costs

    /// What each change costs, in dollars (US, 2025–26): illustrative, an order of magnitude from open
    /// price guides, not anyone's quote. Every figure is the user's to change.
    public struct Costs: Codable, Equatable, Sendable {
        /// Security film (8 mil, wet glazed), installed, per m² of glass.
        public var filmPerM2: Double
        /// Laminated glass in place of the panes, installed, per m² of glass.
        public var laminatedPerM2: Double
        /// A freestanding reinforced-concrete barrier wall, per m² of its face (length × height).
        public var barrierPerM2: Double
        /// A line of crash-rated bollards, per m of the line.
        public var bollardsPerM: Double

        public init(
            filmPerM2: Double = 160, laminatedPerM2: Double = 1000, barrierPerM2: Double = 400,
            bollardsPerM: Double = 2000
        ) {
            self.filmPerM2 = filmPerM2
            self.laminatedPerM2 = laminatedPerM2
            self.barrierPerM2 = barrierPerM2
            self.bollardsPerM = bollardsPerM
        }

        public static let illustrative = Costs()

        /// Where each figure comes from, for the sheet and the doc.
        public static let sources: [String] = [
            "Film: $12–20 per sq ft installed for 8–14 mil film wet glazed (vendors' 2026 price guides), "
                + "so about $160 per m².",
            "Laminated glass: $50–150 per sq ft for laminated security glass in place of the panes (the same "
                + "guides, sellers of film), so about $1,000 per m².",
            "Barrier wall: precast concrete walls 6–8 ft tall at $150–320 per linear foot (cost guides; a "
                + "city's fence wall at $300–320), about $250–480 per m² of face; a blast wall is more: $400.",
            "Bollards: crash-rated bollards at $1,200–2,500 or more each installed (vendors' guides), about "
                + "one every 1.2–1.5 m: $2,000 per m of line.",
        ]

        public static let note =
            "Illustrative costs, in dollars: an order of magnitude from open price guides, not a quote. Change them to yours."
    }

    // MARK: The choices

    /// The glass a plan may put in a building's panes.
    public enum GlassOption: String, CaseIterable, Codable, Sendable, Hashable {
        case film
        case laminated

        public var glass: LiveResponse.Glass {
            switch self {
            case .film: .filmed(.mils(8, anchorage: .wetGlazed))
            case .laminated: .laminated(.facade)
            }
        }

        public var label: String {
            switch self {
            case .film: "film, wet glazed"
            case .laminated: "laminated glass"
            }
        }

        public func costPerM2(_ costs: Costs) -> Double {
            switch self {
            case .film: costs.filmPerM2
            case .laminated: costs.laminatedPerM2
            }
        }
    }

    /// What is made fewest.
    public enum Objective: String, CaseIterable, Codable, Sendable, Identifiable {
        /// The people hurt, by the people's model chosen (Kummer's by the panes broken, by default; or
        /// the glass thrown into rooms, Bowen's).
        case peopleHurt
        /// The glazed façade, m², expected to throw its glass worse than GSA's condition 3b.
        case glassThrown

        public var id: Self { self }

        public var label: String {
            switch self {
            case .peopleHurt: "People hurt"
            case .glassThrown: "Glass thrown past GSA 3b"
            }
        }

        func value(_ outcome: Outcome) -> Double {
            switch self {
            case .peopleHurt: outcome.hurt
            case .glassThrown: outcome.glassM2
            }
        }

        func value(_ building: Outcome.Building) -> Double {
            switch self {
            case .peopleHurt: building.hurt
            case .glassThrown: building.glassM2
            }
        }

        /// A building's gain worth paying for: a hundredth of a person, or of a square metre.
        var least: Double { 0.01 }
    }

    /// A stand-off the plan may buy: the charge kept back along a line from the protected building,
    /// by a line of bollards across the way in.
    public struct StandOff: Sendable, Equatable {
        /// Where the stand-off is measured from, on the plan, and the way out.
        public var from: SIMD2<Float>
        public var along: SIMD2<Float>
        public var range: ClosedRange<Float>
        /// The bollards' line: this long, and, if it wraps round the building's front, twice the
        /// stand-off more.
        public var frontageM: Float
        public var wraps: Bool

        public init(
            from: SIMD2<Float>, along: SIMD2<Float>, range: ClosedRange<Float>, frontageM: Float, wraps: Bool
        ) {
            self.from = from
            self.along = simd_normalize(along)
            self.range = range
            self.frontageM = frontageM
            self.wraps = wraps
        }

        /// The bollards' length for a stand-off of `metres`.
        public func lineM(_ metres: Float) -> Float { frontageM + (wraps ? 2 * metres : 0) }

        /// How far `charge` stands out along the line.
        public func distance(_ charge: SIMD3<Float>) -> Float {
            simd_dot(SIMD2(charge.x, charge.y) - from, along)
        }

        /// `charge` kept `metres` back: moved out along the line if it is nearer, else where it is.
        public func kept(_ charge: SIMD3<Float>, at metres: Float) -> SIMD3<Float> {
            let short = metres - distance(charge)
            guard short > 0 else { return charge }
            return charge + SIMD3(along.x, along.y, 0) * short
        }
    }

    /// The site-wide part of a plan: its walls and its stand-off.
    public struct Site: Hashable, Sendable {
        public var barriers: [LiveResponse.WhatIf.Barrier]
        /// The stand-off bought, m; nil for none.
        public var standOffM: Float?

        public init(barriers: [LiveResponse.WhatIf.Barrier] = [], standOffM: Float? = nil) {
            self.barriers = barriers
            self.standOffM = standOffM
        }
    }

    /// A plan: its site-wide changes, the glass of each building it pays for, and what it all costs.
    public struct Plan: Sendable, Equatable {
        public var site: Site
        public var glass: [UUID: GlassOption]
        public var cost: Cost

        public init(site: Site, glass: [UUID: GlassOption], cost: Cost) {
            self.site = site
            self.glass = glass
            self.cost = cost
        }

        public struct Cost: Sendable, Equatable {
            public var barriers: Double
            public var glass: Double
            public var standOff: Double
            public var total: Double { barriers + glass + standOff }

            public init(barriers: Double = 0, glass: Double = 0, standOff: Double = 0) {
                self.barriers = barriers
                self.glass = glass
                self.standOff = standOff
            }
        }

        public static let none = Plan(site: Site(), glass: [:], cost: Cost())

        /// As a what-if on the quick estimate: the walls, the first draggable, and the glass.
        public var whatIf: LiveResponse.WhatIf {
            LiveResponse.WhatIf(
                barrier: site.barriers.first, moreBarriers: Array(site.barriers.dropFirst()),
                glassOf: glass.mapValues(\.glass))
        }

        /// In words: "a wall 3 m tall and 30 m long; film on 12 buildings; the charge kept 40 m back".
        public var label: String {
            var parts: [String] = site.barriers.map {
                String(format: "a wall %g m tall and %g m long", $0.heightM, $0.lengthM)
            }
            let films = glass.values.filter { $0 == .film }.count
            let laminated = glass.count - films
            if films > 0 { parts.append("film on \(films) building\(films == 1 ? "" : "s")") }
            if laminated > 0 {
                parts.append("laminated glass in \(laminated) building\(laminated == 1 ? "" : "s")")
            }
            if let d = site.standOffM { parts.append(String(format: "the charge kept %.0f m back", d)) }
            return parts.isEmpty ? "nothing" : parts.joined(separator: "; ")
        }
    }

    // MARK: The problem

    public struct Problem: Sendable {
        /// The project's scene as built, its charge where the threat is.
        public var scene: Scenario
        public var budget: Double
        public var costs: Costs = .illustrative
        public var objective: Objective = .peopleHurt
        /// For the people: any budget the people's gain leaves goes on the glass thrown, building by
        /// building (Kummer's people are hurt by the panes broken, which film does not prevent).
        public var restOnGlass = true
        public var people = OccupantInjury.Assumptions()
        /// The barrier walls' heights and lengths offered, m, and how many.
        public var heights: [Float] = [2, 3, 4]
        public var lengths: [Float] = [10, 20, 30, 40, 60]
        public var maxBarriers = 2
        /// A wall stands no nearer the charge than this scaled distance, m/kg^(1/3): its shelter's term
        /// holds Z within 2–8 and was fitted on walls in front of façades at Z 2–10, and the walls are
        /// rigid in the model, where one this close would be thrown down.
        public var leastWallZ: Float = 2
        /// The nearest a wall may stand to the charge, m.
        public var leastWallM: Float { max(3, leastWallZ * cbrt(max(scene.charge.mass, 0))) }
        public var glassOptions: [GlassOption] = GlassOption.allCases
        public var standOff: StandOff?
        /// The search stops after this many looks, or this long.
        public var maxEvaluations = 600
        public var timeLimitS = 20.0

        public init(scene: Scenario, budget: Double) {
            self.scene = scene
            self.budget = budget
        }
    }

    // MARK: What a look gives

    /// The objective's figures from one look at a plan.
    public struct Outcome: Sendable, Equatable {
        public struct Building: Sendable, Equatable {
            public var hurt: Double
            public var glassM2: Double
        }
        public var hurt: Double
        public var severe: Double
        public var glassM2: Double
        public var buildings: [UUID: Building]

        public static let empty = Outcome(hurt: 0, severe: 0, glassM2: 0, buildings: [:])
    }

    /// A model of the district the search asks: one look at the scene with `barriers` put up, the
    /// charge at `charge`, and `glass` in the buildings named.
    public protocol Evaluator: AnyObject {
        func evaluate(
            barriers: [LiveResponse.WhatIf.Barrier], charge: SIMD3<Float>, glass: [UUID: GlassOption]
        ) throws -> Outcome
    }

    /// Each envelope building's glass on the plan, for the costs and the glass thrown.
    package struct Building: Sendable {
        package var id: UUID
        package var bounds: OccupantInjury.Bounds
        /// Each side's glazed area, m², by axis (0, x-facing; 1, y-facing): one side's.
        package var sideGlazedM2: SIMD2<Double>
        package var glazedM2: Double { 2 * (sideGlazedM2.x + sideGlazedM2.y) }
    }

    /// The scene's glazed envelope buildings: each side's glass, its bounds' sides scaled to its
    /// footprint where its outline is not a rectangle on the grid.
    package static func buildings(_ scene: Scenario) -> [Building] {
        let mapped = Set((scene.envelopeSources ?? []).filter { $0.kind == .map }.map(\.objectID))
        return scene.envelopeObjects.compactMap { object in
            let c = scene.envelopeConstruction(for: object.id)
            guard let mix = c.glazing else { return nil }
            let bounds = OccupantInjury.Bounds(object)
            let size = SIMD3<Double>(bounds.size)
            guard size.x > 0, size.y > 0, size.z > 0 else { return nil }
            let footprint = OccupantInjury.floorArea(of: object, map: mapped.contains(object.id)).footprintM2
            let shape = footprint > 0 ? min(1, (footprint / (size.x * size.y)).squareRoot()) : 1
            let share = Double(mix.glazedFraction) * shape * size.z
            return Building(
                id: object.id, bounds: bounds, sideGlazedM2: SIMD2(size.y * share, size.x * share))
        }
    }

    /// The glass thrown past 3b, m², from a look's glazed sides.
    package static func glassThrown(
        _ sides: [FacadeLoadSurrogate.SideGlass], buildings: [UUID: Building]
    ) -> [UUID: Double] {
        var out: [UUID: Double] = [:]
        for side in sides where side.axis < 2 {
            guard let b = buildings[side.owner] else { continue }
            out[side.owner, default: 0] +=
                side.thrownPast3b * (side.axis == 0 ? b.sideGlazedM2.x : b.sideGlazedM2.y)
        }
        return out
    }

    // MARK: Glass for the money left

    /// One building's choice of glass: what each option costs and gains.
    package struct Choice: Sendable {
        package var id: UUID
        package var options: [(option: GlassOption, cost: Double, gain: Double)]
    }

    /// The glass to buy within `budget`, a multiple-choice knapsack solved by its convex hull: each
    /// building's options on their hull of gain against cost, the steps up every hull taken in order
    /// of gain per dollar while the money lasts (a step too dear ends its building's climb). Gains
    /// under `least` are not bought.
    package static func knapsack(_ choices: [Choice], budget: Double, least: Double) -> (
        [UUID: GlassOption], cost: Double, gain: Double
    ) {
        struct Step {
            var building: Int
            var option: GlassOption
            var cost: Double
            var gain: Double
            var rank: Int
        }
        var steps: [Step] = []
        for (n, choice) in choices.enumerated() {
            // The hull from (0, 0): each next point the one of most gain per added dollar.
            var options = choice.options.filter { $0.gain >= least && $0.cost > 0 }
            var at = (cost: 0.0, gain: 0.0)
            var rank = 0
            while true {
                let next = options.filter { $0.gain > at.gain && $0.cost > at.cost }.max {
                    ($0.gain - at.gain) / ($0.cost - at.cost) < ($1.gain - at.gain) / ($1.cost - at.cost)
                }
                guard let next else { break }
                steps.append(
                    Step(
                        building: n, option: next.option, cost: next.cost - at.cost,
                        gain: next.gain - at.gain,
                        rank: rank))
                rank += 1
                at = (next.cost, next.gain)
                options.removeAll { $0.cost <= at.cost }
            }
        }
        steps.sort { $0.gain / $0.cost > $1.gain / $1.cost }
        var left = budget
        var chosen: [Int: (GlassOption, Int)] = [:]
        var stopped = Set<Int>()
        var gain = 0.0
        for step in steps where !stopped.contains(step.building) {
            // A building's steps come in its hull's order: a later one only after the one before.
            let had = chosen[step.building]?.1 ?? -1
            guard had == step.rank - 1 else { continue }
            if step.cost <= left {
                left -= step.cost
                gain += step.gain
                chosen[step.building] = (step.option, step.rank)
            } else {
                stopped.insert(step.building)
            }
        }
        let plan = Dictionary(uniqueKeysWithValues: chosen.map { (choices[$0.key].id, $0.value.0) })
        return (plan, budget - left, gain)
    }

    // MARK: Costs of a plan

    static func barrierCost(_ b: LiveResponse.WhatIf.Barrier, _ costs: Costs) -> Double {
        Double(b.lengthM * b.heightM) * costs.barrierPerM2
    }

    static func siteCost(_ site: Site, _ problem: Problem) -> (barriers: Double, standOff: Double) {
        let walls = site.barriers.reduce(0) { $0 + barrierCost($1, problem.costs) }
        let line = site.standOffM.flatMap { d in problem.standOff.map { Double($0.lineM(d)) } } ?? 0
        return (walls, line * problem.costs.bollardsPerM)
    }

    /// Whether `barrier` can stand: within the scene, clear of every building by half a metre and of
    /// the charge by `least` m.
    package static func stands(
        _ barrier: LiveResponse.WhatIf.Barrier, in scene: Scenario, charge: SIMD3<Float>,
        buildings: [Building],
        least: Float = 3
    ) -> Bool {
        let (a, b) = barrier.ends
        let half = barrier.thicknessM / 2
        let low = simd_min(a, b) - (barrier.alongX ? SIMD2(0, half) : SIMD2(half, 0))
        let high = simd_max(a, b) + (barrier.alongX ? SIMD2(0, half) : SIMD2(half, 0))
        let size = SIMD2(scene.domainSize.x, scene.domainSize.y)
        guard low.x >= 1, low.y >= 1, high.x <= size.x - 1, high.y <= size.y - 1 else { return false }
        let q = SIMD2(charge.x, charge.y)
        let nearest = simd_clamp(q, low, high)
        guard simd_length(q - nearest) >= least else { return false }
        for building in buildings {
            let c = SIMD2(building.bounds.centre.x, building.bounds.centre.y)
            let h = SIMD2(building.bounds.size.x, building.bounds.size.y) / 2 + 0.5
            if low.x < c.x + h.x, high.x > c.x - h.x, low.y < c.y + h.y, high.y > c.y - h.y { return false }
        }
        return true
    }

    // MARK: The search

    /// How the search goes, after each look.
    public struct Progress: Sendable {
        public var evaluations: Int
        public var seconds: Double
        public var best: Plan
        /// The objective, the best plan's and the scene's as built, by the model searched.
        public var bestValue: Double
        public var asBuiltValue: Double
        public var stage: String
    }

    /// A plan the search puts forward for the referee, and its look by the model searched.
    public struct Finalist: Sendable {
        public var plan: Plan
        public var outcome: Outcome
        /// Why it is put forward: "the search's best", "kept 60 m back".
        public var why: String
    }

    public struct Result: Sendable {
        public var plan: Plan
        /// The plan's look and the scene's as built, by the model searched.
        public var outcome: Outcome
        public var asBuilt: Outcome
        public var objective: Objective
        /// The plans for the referee (`referee`), the search's best first: with a stand-off offered,
        /// the best with none, at half the stand-off the budget buys and at all of it, since the live
        /// model reads a charge moved less well than a wall put up (docs/protective-design.md); else
        /// the best few site-wide plans.
        public var finalists: [Finalist]
        public var evaluations: Int
        public var seconds: Double
        /// Stopped by the caller before it finished.
        public var cancelled: Bool
        /// The site-wide plans looked at, with the objective each was scored at (the glass for its
        /// money left estimated from the gains at the plan before), best first: for the ranking's check.
        public var tried: [(site: Site, value: Double)]

        public var value: Double { objective.value(outcome) }
        public var asBuiltValue: Double { objective.value(asBuilt) }
    }

    struct Stop: Error {}

    /// What the searches share: the looks taken, the clock, and whether the caller stopped them.
    final class Searching {
        let problem: Problem
        let evaluator: Evaluator
        let progress: ((Progress) -> Bool)?
        let start = ContinuousClock.now
        var evaluations = 0
        var cancelled = false
        var stage = "As built"
        var best = (plan: Plan.none, value: Double.infinity)
        var asBuilt = Outcome.empty
        var tried: [Site: Double] = [:]
        let buildings: [Building]
        var glazed: [UUID] { buildings.map(\.id) }

        init(_ problem: Problem, _ evaluator: Evaluator, _ progress: ((Progress) -> Bool)?) {
            self.problem = problem
            self.evaluator = evaluator
            self.progress = progress
            buildings = ProtectionBudget.buildings(problem.scene)
        }

        var seconds: Double {
            let d = start.duration(to: .now)
            return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
        }

        func charge(_ site: Site) -> SIMD3<Float> {
            let charge = problem.scene.charge.position
            guard let d = site.standOffM, let line = problem.standOff else { return charge }
            return line.kept(charge, at: d)
        }

        /// One look, counted against the search's looks and time; `free`, not counted (the plan's last).
        func look(_ site: Site, _ glass: [UUID: GlassOption], free: Bool = false) throws -> Outcome {
            if !free, cancelled || evaluations >= problem.maxEvaluations || seconds > problem.timeLimitS {
                throw Stop()
            }
            let outcome = try evaluator.evaluate(barriers: site.barriers, charge: charge(site), glass: glass)
            evaluations += 1
            if !free, let progress, best.value.isFinite,
                !progress(
                    Progress(
                        evaluations: evaluations, seconds: seconds, best: best.plan, bestValue: best.value,
                        asBuiltValue: problem.objective.value(asBuilt), stage: stage))
            {
                cancelled = true
                throw Stop()
            }
            return outcome
        }

        /// What each glass gains each building at a site: the objective's and the glass thrown's.
        struct Gains {
            var reference: Outcome
            var gains: [GlassOption: [UUID: Outcome.Building]]
        }

        func gains(at site: Site, reference: Outcome, free: Bool = false) throws -> Gains {
            var out = Gains(reference: reference, gains: [:])
            for option in problem.glassOptions {
                let all = try look(
                    site, Dictionary(uniqueKeysWithValues: glazed.map { ($0, option) }), free: free)
                var mine: [UUID: Outcome.Building] = [:]
                for (id, was) in reference.buildings {
                    let now = all.buildings[id] ?? was
                    mine[id] = Outcome.Building(
                        hurt: max(0, was.hurt - now.hurt), glassM2: max(0, was.glassM2 - now.glassM2))
                }
                out.gains[option] = mine
            }
            return out
        }

        /// The glass for `money` at a site seen as `outcome`, the gains measured at another scaled by
        /// each building's own figure here against there; and the objective it leaves.
        func glass(for outcome: Outcome, money: Double, gains: Gains) -> ([UUID: GlassOption], Double, Double)
        {
            let objective = problem.objective
            guard money > 0, !gains.gains.isEmpty else { return ([:], 0, objective.value(outcome)) }
            func choices(_ value: (Outcome.Building) -> Double, skip: Set<UUID>) -> [Choice] {
                buildings.compactMap { b in
                    guard !skip.contains(b.id), let here = outcome.buildings[b.id],
                        let there = gains.reference.buildings[b.id]
                    else { return nil }
                    let (h, t) = (value(here), value(there))
                    guard h > 0, t > 0 else { return nil }
                    let options = problem.glassOptions.compactMap {
                        option -> (option: GlassOption, cost: Double, gain: Double)? in
                        guard let g = gains.gains[option]?[b.id] else { return nil }
                        return (
                            option, b.glazedM2 * option.costPerM2(problem.costs), min(h, value(g) * h / t)
                        )
                    }
                    return Choice(id: b.id, options: options)
                }
            }
            let main = knapsack(choices(objective.value, skip: []), budget: money, least: objective.least)
            var plan = main.0
            var spent = main.cost
            if objective == .peopleHurt, problem.restOnGlass, money - spent > 0 {
                let rest = knapsack(
                    choices(\.glassM2, skip: Set(plan.keys)), budget: money - spent,
                    least: Objective.glassThrown.least)
                plan.merge(rest.0) { a, _ in a }
                spent += rest.cost
            }
            return (plan, spent, objective.value(outcome) - main.gain)
        }

        func plan(_ site: Site, _ outcome: Outcome, _ gains: Gains) -> (Plan, Double) {
            let (walls, line) = siteCost(site, problem)
            let (glass, spent, value) = glass(
                for: outcome, money: problem.budget - walls - line, gains: gains)
            return (
                Plan(
                    site: site, glass: glass, cost: Plan.Cost(barriers: walls, glass: spent, standOff: line)),
                value
            )
        }

        /// Within the budget, and every wall clear of the charge where the stand-off leaves it.
        func allowed(_ site: Site) -> Bool {
            let (walls, line) = siteCost(site, problem)
            guard walls + line <= problem.budget else { return false }
            let c = charge(site)
            return site.barriers.allSatisfy {
                stands($0, in: problem.scene, charge: c, buildings: buildings, least: problem.leastWallM)
            }
        }

        /// The plan for `site` as a whole: its own glass's gains measured there, its glass bought, and
        /// the plan looked at glass and all. Not counted against the search's looks.
        func finish(_ site: Site) throws -> (Plan, Outcome) {
            let here = try look(site, [:], free: true)
            let (walls, line) = siteCost(site, problem)
            var plan = Plan(site: site, glass: [:], cost: Plan.Cost(barriers: walls, standOff: line))
            if !problem.glassOptions.isEmpty, problem.budget - walls - line > 0 {
                plan = self.plan(site, here, try gains(at: site, reference: here, free: true)).0
            }
            return (plan, plan.glass.isEmpty ? here : try look(site, plan.glass, free: true))
        }

        /// The coordinate search from `startSite`: each round every move from the plan, the best
        /// taken; none better, the steps halved. The stand-off moves only if `movesStandOff`. Gives the
        /// best site found and the ones next best, their scores.
        func search(from startSite: Site, movesStandOff: Bool) throws -> [(Site, Double)] {
            var found: [Site: Double] = [:]
            do {
                try search(from: startSite, movesStandOff: movesStandOff, found: &found)
            } catch is Stop {
                // Out of looks or time: the best found so far, unless the caller stopped it.
                if cancelled { throw Stop() }
            }
            return found.sorted { $0.value < $1.value }.map { ($0.key, $0.value) }
        }

        private func search(from startSite: Site, movesStandOff: Bool, found: inout [Site: Double]) throws {
            let objective = problem.objective
            let scene = problem.scene
            var seen: [Site: Outcome] = [:]
            var incumbent = startSite
            let startOutcome = try startSite == Site() ? asBuilt : look(startSite, [:])
            stage = "What glass gains"
            var table = try gains(at: startSite, reference: startOutcome)
            var current = plan(startSite, startOutcome, table).1
            found[startSite] = current
            func score(_ site: Site) throws -> Double? {
                if let known = found[site] { return known }
                guard allowed(site) else { return nil }
                let outcome = try look(site, [:])
                seen[site] = outcome
                let (made, value) = plan(site, outcome, table)
                found[site] = value
                tried[site] = min(tried[site] ?? .infinity, value)
                if value < best.value { best = (made, value) }
                return value
            }
            if current < best.value { best = (plan(startSite, startOutcome, table).0, current) }

            // The walls to try first: across the line to each of the buildings that count most, 6 m in
            // front of it (where a wall shelters most, within a height or two of it), half way, and as
            // near the charge as a wall may stand.
            stage = "Where walls might go"
            let c = charge(startSite)
            let q = SIMD2(c.x, c.y)
            let worst = buildings.filter { (startOutcome.buildings[$0.id].map(objective.value) ?? 0) > 0 }
                .sorted {
                    objective.value(startOutcome.buildings[$0.id]!)
                        > objective.value(startOutcome.buildings[$1.id]!)
                }
                .prefix(6)
            let heights = problem.heights.sorted()
            let lengths = problem.lengths.sorted()
            let (startWalls, startLine) = siteCost(startSite, problem)
            let money = problem.budget - startWalls - startLine
            func sized(_ wall: LiveResponse.WhatIf.Barrier) -> LiveResponse.WhatIf.Barrier? {
                // 3 m tall and 30 m long, or the most of each the budget buys.
                var w = wall
                for h in heights.filter({ $0 <= 3 }).reversed() + heights.filter({ $0 > 3 }) {
                    for l in lengths.filter({ $0 <= 30 }).reversed() {
                        w.heightM = h
                        w.lengthM = l
                        if barrierCost(w, problem.costs) <= money { return w }
                    }
                }
                return nil
            }
            var seeds: [LiveResponse.WhatIf.Barrier] = []
            if problem.maxBarriers > 0, !heights.isEmpty, !lengths.isEmpty {
                for b in worst {
                    let centre = SIMD2(b.bounds.centre.x, b.bounds.centre.y)
                    let half = SIMD2(b.bounds.size.x, b.bounds.size.y) / 2
                    let nearest = simd_clamp(q, centre - half, centre + half)
                    let d = simd_length(nearest - q)
                    guard d > 1 else { continue }
                    for at in [d - 6, d / 2, problem.leastWallM + 1]
                    where at >= problem.leastWallM && at < d - 1 {
                        let wall = LiveResponse.WhatIf.Barrier.across(
                            from: q, to: nearest, at: at / d, lengthM: 30, heightM: 3)
                        guard var w = sized(wall) else { continue }
                        w.centre = (w.centre * 4).rounded(.toNearestOrEven) / 4
                        guard
                            stands(w, in: scene, charge: c, buildings: buildings, least: problem.leastWallM),
                            !seeds.contains(where: {
                                $0.alongX == w.alongX && simd_length($0.centre - w.centre) < 4
                            })
                        else { continue }
                        seeds.append(w)
                    }
                }
            }
            var seedScores: [(LiveResponse.WhatIf.Barrier, Double)] = []
            for seed in seeds where startSite.barriers.count < problem.maxBarriers {
                var s = startSite
                s.barriers.append(seed)
                if let value = try score(s) { seedScores.append((seed, value)) }
            }
            seedScores.sort { $0.1 < $1.1 }

            stage = "Moving the walls"
            var step: Float = 8
            var standStep: Float =
                problem.standOff.map { ($0.range.upperBound - $0.range.lowerBound) / 4 } ?? 0
            let tolerance = 1e-4 * max(objective.value(asBuilt), 1)
            for _ in 0..<60 {
                var moves: [Site] = []
                if movesStandOff, let line = problem.standOff {
                    let r = line.range
                    if let d = incumbent.standOffM {
                        for next in [d + standStep, d - standStep] {
                            var s = incumbent
                            s.standOffM =
                                next < r.lowerBound ? nil : (min(next, r.upperBound) * 4).rounded() / 4
                            moves.append(s)
                        }
                    } else {
                        // A stand-off helps only past where the charge is.
                        let now = max(line.distance(problem.scene.charge.position), r.lowerBound)
                        for next in [now + standStep, now + 2 * standStep, r.upperBound]
                        where next <= r.upperBound {
                            var s = incumbent
                            s.standOffM = (next * 4).rounded() / 4
                            moves.append(s)
                        }
                    }
                }
                for (i, wall) in incumbent.barriers.enumerated() {
                    let normal: SIMD2<Float> = wall.alongX ? SIMD2(0, 1) : SIMD2(1, 0)
                    let tangent: SIMD2<Float> = wall.alongX ? SIMD2(1, 0) : SIMD2(0, 1)
                    var variants: [LiveResponse.WhatIf.Barrier] = []
                    for shift in [normal * step, -normal * step, tangent * step, -tangent * step] {
                        var w = wall
                        w.centre += shift
                        variants.append(w)
                    }
                    if let k = heights.firstIndex(of: wall.heightM) {
                        for j in [k - 1, k + 1] where heights.indices.contains(j) {
                            var w = wall
                            w.heightM = heights[j]
                            variants.append(w)
                        }
                    }
                    if let k = lengths.firstIndex(of: wall.lengthM) {
                        for j in [k - 1, k + 1] where lengths.indices.contains(j) {
                            var w = wall
                            w.lengthM = lengths[j]
                            variants.append(w)
                        }
                    }
                    var turned = wall
                    turned.alongX.toggle()
                    variants.append(turned)
                    for var w in variants {
                        w.centre = (w.centre * 4).rounded(.toNearestOrEven) / 4
                        var s = incumbent
                        s.barriers[i] = w
                        moves.append(s)
                    }
                    var s = incumbent
                    s.barriers.remove(at: i)
                    moves.append(s)
                }
                if incumbent.barriers.count < problem.maxBarriers {
                    for (seed, _) in seedScores.prefix(incumbent.barriers.isEmpty ? seedScores.count : 3)
                    where !incumbent.barriers.contains(where: {
                        $0.alongX == seed.alongX && simd_length($0.centre - seed.centre) < 6
                    }) {
                        var s = incumbent
                        s.barriers.append(seed)
                        moves.append(s)
                    }
                }
                var bestMove: (site: Site, value: Double)?
                for move in moves where move != incumbent {
                    guard let value = try score(move) else { continue }
                    if value < bestMove?.value ?? .infinity { bestMove = (move, value) }
                }
                if let (site, value) = bestMove, value < current - tolerance {
                    incumbent = site
                    current = value
                    // The glass's gains again where the plan now is.
                    let (walls, line) = siteCost(site, problem)
                    if !problem.glassOptions.isEmpty, problem.budget - walls - line > 0 {
                        let outcome = try seen[site] ?? look(site, [:])
                        stage = "What glass gains"
                        table = try gains(at: site, reference: outcome)
                        stage = "Moving the walls"
                        let (made, rescored) = plan(site, outcome, table)
                        current = rescored
                        found[site] = rescored
                        if rescored < best.value { best = (made, rescored) }
                    }
                    seen = [:]
                } else {
                    seen = [:]
                    step /= 2
                    standStep /= 2
                    if step < 1, !movesStandOff || problem.standOff == nil || standStep < 2 { break }
                }
            }
        }
    }

    /// The best plan for `problem`'s budget, by `evaluator` (the learned response in the app), and the
    /// finalists for the referee; `progress` hears of each look and may stop the search (returning
    /// false), which then gives the best found so far.
    public static func optimise(
        _ problem: Problem, evaluator: Evaluator, progress: ((Progress) -> Bool)? = nil
    ) throws -> Result {
        let s = Searching(problem, evaluator, progress)
        s.asBuilt = try evaluator.evaluate(barriers: [], charge: problem.scene.charge.position, glass: [:])
        s.evaluations += 1
        var starts: [(Site, String)] = []
        if let line = problem.standOff {
            // The stand-off fixed in turn at none, half of what the budget buys past the charge, and all of
            // it, each searched for its walls and glass; then the stand-off free.
            let now = max(line.distance(problem.scene.charge.position), line.range.lowerBound)
            let most = stride(from: line.range.upperBound, through: now, by: -1).first {
                Double(line.lineM($0)) * problem.costs.bollardsPerM <= problem.budget
            }
            starts.append((Site(), "no stand-off"))
            if let most, most > now + 2 {
                let half = ((now + most) / 2).rounded()
                if half > now + 1 {
                    starts.append((Site(standOffM: half), String(format: "kept %.0f m back", half)))
                }
                starts.append((Site(standOffM: most), String(format: "kept %.0f m back", most)))
            }
        }
        var candidates: [(Site, String)] = []
        var searched = false
        do {
            if starts.isEmpty {
                let found = try s.search(from: Site(), movesStandOff: false)
                searched = true
                // The best three site-wide plans that differ: by their walls' count, a wall 20 m or more
                // away, or another way.
                func distinct(_ a: Site, _ b: Site) -> Bool {
                    guard a.barriers.count == b.barriers.count, a.standOffM == b.standOffM else {
                        return true
                    }
                    return zip(a.barriers, b.barriers).contains {
                        $0.alongX != $1.alongX || simd_length($0.centre - $1.centre) >= 20
                    }
                }
                for (site, _) in found where candidates.count < 3 {
                    if candidates.allSatisfy({ distinct($0.0, site) }) {
                        candidates.append((site, candidates.isEmpty ? "the search's best" : "the next best"))
                    }
                }
            } else {
                let looks = problem.maxEvaluations
                for (n, (start, why)) in starts.enumerated() {
                    // Each its share of the looks, the free search the rest.
                    var limited = s.problem
                    limited.maxEvaluations = min(looks, s.evaluations + looks / (starts.count + 1))
                    limited.timeLimitS = max(0, problem.timeLimitS - s.seconds)
                    let fixed = Searching(limited, evaluator, progress)
                    fixed.asBuilt = s.asBuilt
                    fixed.best = s.best
                    fixed.evaluations = s.evaluations
                    defer {
                        s.evaluations = fixed.evaluations
                        s.cancelled = s.cancelled || fixed.cancelled
                        s.tried.merge(fixed.tried) { min($0, $1) }
                        if fixed.best.value < s.best.value { s.best = fixed.best }
                    }
                    s.stage = "Searching, \(why) (\(n + 1) of \(starts.count + 1))"
                    fixed.stage = s.stage
                    if let site = try fixed.search(from: start, movesStandOff: false).first?.0 {
                        candidates.append((site, why))
                    }
                }
                s.stage = "Searching, the stand-off free"
                if let site = try s.search(from: s.best.plan.site, movesStandOff: true).first?.0 {
                    candidates.insert((site, "the stand-off free"), at: 0)
                }
                searched = true
            }
        } catch is Stop {
            // Out of looks or time, or stopped: the best so far.
        }
        if !searched || candidates.isEmpty || s.cancelled {
            if s.best.value.isFinite { candidates.insert((s.best.plan.site, "the search's best"), at: 0) }
        }
        // Each finalist as a whole, glass and all; the search's best first.
        s.stage = "The plans as a whole"
        var finalists: [Finalist] = []
        for (site, why) in candidates where !finalists.contains(where: { $0.plan.site == site }) {
            if s.cancelled, !finalists.isEmpty { break }
            let (plan, outcome) = try s.finish(site)
            finalists.append(Finalist(plan: plan, outcome: outcome, why: why))
        }
        if finalists.isEmpty { finalists = [Finalist(plan: .none, outcome: s.asBuilt, why: "as built")] }
        // The search's best is the finalist best by the model searched.
        let objective = problem.objective
        let top = finalists.indices.min {
            objective.value(finalists[$0].outcome) < objective.value(finalists[$1].outcome)
        }!
        let lead = finalists.remove(at: top)
        finalists.insert(Finalist(plan: lead.plan, outcome: lead.outcome, why: lead.why), at: 0)
        let ranked = s.tried.map { (site: $0.key, value: $0.value) }.sorted { $0.value < $1.value }
        return Result(
            plan: lead.plan, outcome: lead.outcome, asBuilt: s.asBuilt, objective: objective,
            finalists: finalists,
            evaluations: s.evaluations, seconds: s.seconds, cancelled: s.cancelled, tried: ranked)
    }

    /// The finalists judged again by `referee` (the full estimate, as on a let-go), best first by it.
    public struct Refereed: Sendable {
        public var finalists: [(finalist: Finalist, judged: Outcome)]
        public var asBuilt: Outcome
        public var objective: Objective
        /// The live search's own best (`Result.plan`).
        public var searchsBest: Plan
        public var seconds: Double

        public var best: Finalist { finalists[0].finalist }
        /// Whether the referee's best is the live search's own.
        public var keepsTheSearchsBest: Bool { finalists.first?.finalist.plan == searchsBest }
    }

    /// `result`'s finalists judged by `referee`, and the scene as built; `progress` hears after each
    /// (the number done) and may stop it, the rest then left unjudged.
    public static func referee(
        _ result: Result, problem: Problem, referee: Evaluator, progress: ((Int) -> Bool)? = nil
    ) throws -> Refereed {
        let start = ContinuousClock.now
        let charge = problem.scene.charge.position
        func moved(_ site: Site) -> SIMD3<Float> {
            guard let d = site.standOffM, let line = problem.standOff else { return charge }
            return line.kept(charge, at: d)
        }
        let asBuilt = try referee.evaluate(barriers: [], charge: charge, glass: [:])
        var judged: [(finalist: Finalist, judged: Outcome)] = []
        for finalist in result.finalists {
            if let progress, !progress(judged.count) { break }
            let outcome = try referee.evaluate(
                barriers: finalist.plan.site.barriers, charge: moved(finalist.plan.site),
                glass: finalist.plan.glass)
            judged.append((finalist, outcome))
        }
        let objective = problem.objective
        judged.sort { objective.value($0.judged) < objective.value($1.judged) }
        let took = start.duration(to: .now)
        return Refereed(
            finalists: judged, asBuilt: asBuilt, objective: objective, searchsBest: result.plan,
            seconds: Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18)
    }
}
