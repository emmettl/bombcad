import Foundation

/// The search for the least costly set of changes that meets a hazard target (roadmap, Horizons 6;
/// docs/protective-design.md, "The search"), as the prototype's (`Scripts/protective/search.py`)
/// does it, over any problem that can say each side's chance:
///
/// - **site-wide** changes (a stand-off line, a barrier) change every side's loads, so each choice
///   of them is a problem of its own for the sides;
/// - **per side**, given the site-wide changes, each side's choice is its own: the cheapest option
///   whose chance of passing its target is no more than the chance accepted.
///
/// `exact` enumerates the site-wide choices (2^k; to k = 12), `greedy` buys the change removing the
/// most excess chance per unit of cost until the target holds and then prunes, and `anneal` walks
/// the site-wide choices for when they are too many to enumerate. `ranked` lists plans meeting the
/// target by cost, then the rest by how far they miss it.
public enum ProtectionSearch {
    /// One way a side may be: a glazing and a wall, and what it costs over the side as built
    /// (nothing for the side as built, which comes first).
    public struct Option: Codable, Sendable, Hashable {
        public var glazing: String
        public var wall: String
        public var cost: Double

        public init(glazing: String, wall: String, cost: Double) {
            self.glazing = glazing
            self.wall = wall
            self.cost = cost
        }
    }

    public struct Side: Codable, Sendable {
        public var name: String
        /// The side as built first.
        public var options: [Option]

        public init(name: String, options: [Option]) {
            self.name = name
            self.options = options
        }
    }

    public struct SiteChange: Codable, Sendable {
        public var name: String
        public var cost: Double

        public init(name: String, cost: Double) {
            self.name = name
            self.cost = cost
        }
    }

    /// A problem: its sides and site-wide changes, the largest chance accepted of a side passing
    /// its target, and each side's chance with an option under a choice of site-wide changes
    /// (`chance(site, side, option)`, the site's indices in increasing order), asked once each.
    public struct Problem: Sendable {
        public var sides: [Side]
        public var site: [SiteChange]
        public var targetChance: Double
        let chances: ChanceCache

        public init(
            sides: [Side], site: [SiteChange], targetChance: Double,
            chance: @escaping @Sendable (_ site: [Int], _ side: Int, _ option: Int) -> Double
        ) {
            self.sides = sides
            self.site = site
            self.targetChance = targetChance
            chances = ChanceCache(chance)
        }

        public func chance(_ site: [Int], _ side: Int, _ option: Int) -> Double {
            chances.value(site, side, option)
        }
    }

    /// The chances asked so far, so that a search asks each once.
    package final class ChanceCache: @unchecked Sendable {
        package struct Key: Hashable {
            var site: [Int]
            package var side: Int
            var option: Int
        }
        private let lock = NSLock()
        private var known: [Key: Double] = [:]
        private let chance: @Sendable ([Int], Int, Int) -> Double

        init(_ chance: @escaping @Sendable ([Int], Int, Int) -> Double) { self.chance = chance }

        package func value(_ site: [Int], _ side: Int, _ option: Int) -> Double {
            let key = Key(site: site, side: side, option: option)
            lock.lock()
            if let value = known[key] {
                lock.unlock()
                return value
            }
            lock.unlock()
            let value = chance(site, side, option)
            lock.lock()
            known[key] = value
            lock.unlock()
            return value
        }
    }

    public struct Plan: Codable, Sendable, Equatable {
        /// The site-wide changes, by index, in increasing order.
        public var site: [Int]
        /// Each side's option, by index.
        public var choices: [Int]
        /// Each side's chance of passing its target.
        public var chances: [Double]
        public var cost: Double
        public var meets: Bool
        public var method: String

        /// How far the sides' chances exceed the target's, summed.
        public func excess(_ target: Double) -> Double { chances.reduce(0) { $0 + max(0, $1 - target) } }
        /// The sides expected to pass their targets.
        public var expectedFailing: Double { chances.reduce(0, +) }
        public var worst: Double { chances.max() ?? 0 }
    }

    /// Each side given its cheapest option meeting the target, or, where none does, the one least
    /// likely to fail (the cheaper of equals).
    public static func plan(_ problem: Problem, site: [Int], method: String = "exact") -> Plan {
        let target = problem.targetChance
        var cost = site.reduce(0) { $0 + problem.site[$1].cost }
        var meets = true
        var choices: [Int] = []
        var chances: [Double] = []
        for (s, side) in problem.sides.enumerated() {
            var best: (option: Int, cost: Double, chance: Double)?
            var fallback: (option: Int, cost: Double, chance: Double)?
            for (o, option) in side.options.enumerated() {
                let p = problem.chance(site, s, o)
                if p <= target, best == nil || option.cost < best!.cost { best = (o, option.cost, p) }
                if fallback == nil || p < fallback!.chance
                    || (p == fallback!.chance && option.cost < fallback!.cost)
                {
                    fallback = (o, option.cost, p)
                }
            }
            if best == nil {
                best = fallback
                meets = false
            }
            choices.append(best!.option)
            chances.append(best!.chance)
            cost += best!.cost
        }
        return Plan(site: site, choices: choices, chances: chances, cost: cost, meets: meets, method: method)
    }

    /// A plan with the given site-wide changes and choices, costed and judged.
    public static func evaluate(_ problem: Problem, site: [Int], choices: [Int], method: String) -> Plan {
        var cost = site.reduce(0) { $0 + problem.site[$1].cost }
        var chances: [Double] = []
        for (s, side) in problem.sides.enumerated() {
            cost += side.options[choices[s]].cost
            chances.append(problem.chance(site, s, choices[s]))
        }
        return Plan(
            site: site, choices: choices, chances: chances, cost: cost,
            meets: chances.allSatisfy { $0 <= problem.targetChance }, method: method)
    }

    public static func asBuilt(_ problem: Problem) -> Plan {
        evaluate(
            problem, site: [], choices: Array(repeating: 0, count: problem.sides.count), method: "as built")
    }

    /// The best plan for every combination of site-wide changes, fewest changes first.
    public static func exact(_ problem: Problem) -> [Plan] {
        let n = problem.site.count
        precondition(n <= 12, "\(n) site-wide changes are too many to enumerate; anneal")
        var plans: [Plan] = []
        for k in 0...n {
            for site in combinations(n, k) { plans.append(plan(problem, site: site)) }
        }
        return plans
    }

    /// The `k`-element subsets of 0..<n, in the lexicographic order Python's itertools gives.
    static func combinations(_ n: Int, _ k: Int) -> [[Int]] {
        guard k <= n else { return [] }
        var out: [[Int]] = []
        var index = Array(0..<k)
        while true {
            out.append(index)
            var i = k - 1
            while i >= 0, index[i] == i + n - k { i -= 1 }
            if i < 0 { return out }
            index[i] += 1
            for j in (i + 1)..<k { index[j] = index[j - 1] + 1 }
        }
    }

    /// The cheapest plan meeting the target, or, with none, the one missing it by least.
    public static func best(_ plans: [Plan], target: Double) -> Plan {
        let meeting = plans.filter(\.meets)
        if !meeting.isEmpty {
            return meeting.min { ($0.cost, $0.expectedFailing) < ($1.cost, $1.expectedFailing) }!
        }
        return plans.min { ($0.excess(target), $0.cost) < ($1.excess(target), $1.cost) }!
    }

    /// Change by change, the most excess chance removed per unit of cost, then each undone if the
    /// target still holds without it, latest first.
    public static func greedy(_ problem: Problem) -> Plan {
        let target = problem.targetChance
        var site: [Int] = []
        var choices = Array(repeating: 0, count: problem.sides.count)
        var plan = evaluate(problem, site: site, choices: choices, method: "greedy")
        enum Move {
            case site(Int)
            case side(Int, Int)
        }
        var history: [Move] = []
        while !plan.meets {
            let base = plan.excess(target)
            var bestMove: Move?
            var bestScore = 0.0
            for (i, change) in problem.site.enumerated() where !site.contains(i) {
                let trial = evaluate(problem, site: (site + [i]).sorted(), choices: choices, method: "greedy")
                let gain = base - trial.excess(target)
                if gain > 1e-12, gain / max(change.cost, 1e-9) > bestScore {
                    bestMove = .site(i)
                    bestScore = gain / max(change.cost, 1e-9)
                }
            }
            for (s, side) in problem.sides.enumerated() {
                let now = choices[s]
                let p0 = problem.chance(site, s, now)
                guard p0 > target else { continue }
                for (o, option) in side.options.enumerated() {
                    let extra = option.cost - side.options[now].cost
                    guard extra > 0 else { continue }
                    let p = problem.chance(site, s, o)
                    let gain = max(0, p0 - target) - max(0, p - target)
                    if gain > 1e-12, gain / extra > bestScore {
                        bestMove = .side(s, o)
                        bestScore = gain / extra
                    }
                }
            }
            guard let move = bestMove else { break }
            history.append(move)
            switch move {
            case .site(let i): site = (site + [i]).sorted()
            case .side(let s, let o): choices[s] = o
            }
            plan = evaluate(problem, site: site, choices: choices, method: "greedy")
        }
        guard plan.meets else { return plan }
        for move in history.reversed() {
            var trialSite = site
            var trialChoices = choices
            switch move {
            case .site(let i): trialSite = site.filter { $0 != i }
            case .side(let s, _): trialChoices[s] = 0
            }
            let trial = evaluate(problem, site: trialSite, choices: trialChoices, method: "greedy")
            if trial.meets, trial.cost < plan.cost {
                site = trialSite
                choices = trialChoices
                plan = trial
            }
        }
        return plan
    }

    /// Simulated annealing over the site-wide changes, each side given its cheapest option, a plan
    /// missing the target charged its excess chance at a large price; the best plan seen.
    public static func anneal(_ problem: Problem, steps: Int = 300, seed: UInt64 = 1) -> Plan {
        let n = problem.site.count
        let scale = (problem.site.map(\.cost) + [1]).max()!
        let penalty = 100 * scale * Double(problem.sides.count)
        func energy(_ p: Plan) -> Double { p.cost + penalty * p.excess(problem.targetChance) }
        var state: Set<Int> = []
        var current = plan(problem, site: [], method: "anneal")
        var found = current
        guard n > 0 else { return current }
        var random = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        func next() -> Double {
            // xorshift64*, uniform in [0, 1).
            random ^= random >> 12
            random ^= random << 25
            random ^= random >> 27
            return Double((random &* 0x2545_F491_4F6C_DD1D) >> 11) * 0x1p-53
        }
        var temperature = scale
        for step in 0..<steps {
            let i = min(Int(next() * Double(n)), n - 1)
            let trialState = state.symmetricDifference([i])
            let trial = plan(problem, site: trialState.sorted(), method: "anneal")
            let delta = energy(trial) - energy(current)
            if delta <= 0 || next() < exp(-delta / max(temperature, 1e-9)) {
                state = trialState
                current = trial
                if energy(current) < energy(found) { found = current }
            }
            temperature = scale * (1 - Double(step + 1) / Double(steps)) + 1e-6
        }
        return found
    }

    /// Plans in order, one for each different plan: meeting the target by cost, then the rest by
    /// excess chance, ties by the sides expected to pass their targets.
    public static func ranked(_ problem: Problem, plans: [Plan], count: Int = 6) -> [Plan] {
        let target = problem.targetChance
        let order = plans.enumerated().sorted { a, b in
            let ka = (a.element.meets ? 0 : 1, a.element.meets ? a.element.cost : a.element.excess(target))
            let kb = (b.element.meets ? 0 : 1, b.element.meets ? b.element.cost : b.element.excess(target))
            if ka != kb { return ka < kb }
            if a.element.expectedFailing != b.element.expectedFailing {
                return a.element.expectedFailing < b.element.expectedFailing
            }
            return a.offset < b.offset
        }
        var seen = Set<[Int]>()
        var out: [Plan] = []
        for (_, p) in order {
            guard seen.insert(p.site + [-1] + p.choices).inserted else { continue }
            out.append(p)
            if out.count == count { break }
        }
        return out
    }

    /// How many sides pass within a factor of three of the target: the ones to confirm first.
    public static func narrow(_ plan: Plan, target: Double) -> Int {
        plan.chances.filter { $0 >= target / 3 && $0 <= target }.count
    }
}
