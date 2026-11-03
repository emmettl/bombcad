import Foundation
import Testing
import simd

@testable import BlastModel

/// The best protection for a budget (emmettl/bombcad-work#117, stage 2): the glass's knapsack, the plan
/// as a what-if, the stand-off, the search on a toy model of known answer, and the search on the learned
/// response itself.
@Suite("Protection for a budget: the knapsack, the plan and the search")
struct ProtectionBudgetTests {
    // MARK: The glass for the money left

    /// Every way of choosing one option or none per building, the best within `budget`.
    func brute(_ choices: [ProtectionBudget.Choice], budget: Double, least: Double) -> Double {
        var best = 0.0
        func walk(_ n: Int, _ cost: Double, _ gain: Double) {
            guard cost <= budget else { return }
            guard n < choices.count else {
                best = max(best, gain)
                return
            }
            walk(n + 1, cost, gain)
            for o in choices[n].options where o.gain >= least { walk(n + 1, cost + o.cost, gain + o.gain) }
        }
        walk(0, 0, 0)
        return best
    }

    @Test("The knapsack keeps to the budget, and comes within a few per cent of the best choice")
    func knapsack() {
        var random = SplitMix64(seed: 117)
        var worst = 1.0
        for _ in 0..<200 {
            let choices = (0..<7).map { _ in
                let area = 20 + 200 * random.unit()
                let gain = 5 * random.unit()
                return ProtectionBudget.Choice(
                    id: UUID(),
                    options: [
                        (.film, area * 160, gain * (0.3 + 0.5 * random.unit())),
                        (.laminated, area * 1000, gain * (0.6 + 0.4 * random.unit())),
                    ])
            }
            let budget = 300_000 * random.unit()
            let (plan, cost, gain) = ProtectionBudget.knapsack(choices, budget: budget, least: 0.01)
            #expect(cost <= budget + 1e-6)
            // Its cost and gain are its plan's.
            let byID = Dictionary(uniqueKeysWithValues: choices.map { ($0.id, $0) })
            let sum = plan.reduce(0.0) { total, entry in
                total + (byID[entry.key]!.options.first { $0.option == entry.value }!.gain)
            }
            #expect(abs(sum - gain) < 1e-9)
            let optimum = brute(choices, budget: budget, least: 0.01)
            if optimum > 0 { worst = min(worst, gain / optimum) }
        }
        #expect(worst > 0.7, "worst share of the best: \(worst)")
        // With money for everything, every building takes its option of most gain.
        let a = UUID()
        let b = UUID()
        let all = ProtectionBudget.knapsack(
            [
                .init(id: a, options: [(.film, 10, 1), (.laminated, 50, 3)]),
                .init(id: b, options: [(.film, 10, 2), (.laminated, 50, 1)]),
            ], budget: 1e9, least: 0.01)
        #expect(all.0 == [a: .laminated, b: .film])
        // Gains under the least worth buying are not bought.
        #expect(
            ProtectionBudget.knapsack([.init(id: a, options: [(.film, 1, 0.001)])], budget: 10, least: 0.01).0
                .isEmpty)
    }

    // MARK: The plan as a what-if

    /// Two 20 × 10 m blocks of flats 12 m high east of a 100 kg charge, 30 and 70 m off.
    func blocks() throws -> (Scenario, [UUID]) {
        var scene = Scenario(
            name: "Blocks", domainSize: SIMD3(300, 200, 60), boxes: [],
            charge: Charge(mass: 100, position: SIMD3(50, 100, 0)))
        var ids: [UUID] = []
        for x: Float in [80, 120] {
            let id = try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [Box(min: SIMD3(x, 95, 0), max: SIMD3(x + 20, 105, 12))]),
                name: "Block")
            ids.append(id)
        }
        scene.envelopeConstructions = ids.map {
            var c = EnvelopeConstruction.assumed(objectID: $0)
            c.glazing = .apartments
            c.use = .residential
            return c
        }
        return (scene, ids)
    }

    @Test("A plan's what-if puts up its walls and glazes the buildings it names, the others as built")
    func whatIf() throws {
        let (scene, ids) = try blocks()
        let walls = [
            LiveResponse.WhatIf.Barrier(centre: SIMD2(70, 100), lengthM: 20, heightM: 3, alongX: false),
            LiveResponse.WhatIf.Barrier(centre: SIMD2(110, 100), lengthM: 10, heightM: 2, alongX: false),
        ]
        let plan = ProtectionBudget.Plan(
            site: ProtectionBudget.Site(barriers: walls), glass: [ids[0]: .film], cost: .init())
        let w = plan.whatIf
        #expect(w.barriers == walls && w.barrier == walls[0] && w.changesConstructions && !w.isEmpty)
        let built = w.applied(to: scene)
        #expect(built.boxes.count == 2)
        #expect(built.envelopeConstruction(for: ids[0]).film != nil)
        #expect(built.envelopeConstruction(for: ids[1]).film == nil)
        #expect(built.envelopeConstruction(for: ids[1]) == scene.envelopeConstruction(for: ids[1]))
        #expect(w.label.contains("film on 1 building") && w.label.contains("2 m tall"))
        #expect(
            plan.label == "a wall 3 m tall and 20 m long; a wall 2 m tall and 10 m long; film on 1 building")
        // Glazed area: two sides of 20 m and two of 10, 12 m high, at the flats' glazed share.
        let b = ProtectionBudget.buildings(scene).first { $0.id == ids[0] }!
        #expect(abs(b.glazedM2 - 60 * 12 * Double(GlazingMix.apartments.glazedFraction)) < 1e-6)
    }

    @Test("A stand-off moves only a charge nearer than it, along its line; its bollards wrap or not")
    func standOff() {
        let line = ProtectionBudget.StandOff(
            from: SIMD2(0, 50), along: SIMD2(0, -1), range: 3...120, frontageM: 70, wraps: true)
        let charge = SIMD3<Float>(5, 10, 0)
        #expect(line.distance(charge) == 40)
        #expect(line.kept(charge, at: 30) == charge)
        #expect(line.kept(charge, at: 60) == SIMD3(5, -10, 0))
        #expect(line.lineM(25) == 120)
        let square = ExplorerScene.square.standOff!.budget(origin: SIMD3(100, 100, 0))
        let street = ExplorerScene.street.standOff!.budget(origin: SIMD3(100, 100, 0))
        #expect(square.wraps && square.lineM(10) == ExplorerScene.block + 20)
        #expect(!street.wraps && street.lineM(100) == ExplorerScene.streetWidth)
    }

    @Test("A wall stands clear of the buildings and outside Z 2 of the charge")
    func stands() throws {
        let (scene, _) = try blocks()
        let buildings = ProtectionBudget.buildings(scene)
        let charge = scene.charge.position
        var problem = ProtectionBudget.Problem(scene: scene, budget: 1)
        #expect(abs(problem.leastWallM - 2 * cbrt(100)) < 1e-4)
        problem.leastWallZ = 1
        func wall(_ x: Float) -> LiveResponse.WhatIf.Barrier {
            .init(centre: SIMD2(x, 100), lengthM: 20, heightM: 3, alongX: false)
        }
        #expect(
            ProtectionBudget.stands(wall(70), in: scene, charge: charge, buildings: buildings, least: 9.3))
        #expect(
            !ProtectionBudget.stands(wall(55), in: scene, charge: charge, buildings: buildings, least: 9.3))
        #expect(
            !ProtectionBudget.stands(wall(90), in: scene, charge: charge, buildings: buildings, least: 9.3))
    }

    // MARK: The search on a toy of known answer

    /// Each building's hurt 1000/d, d its distance from the charge; a wall across the line to it takes
    /// off a share 0.08 × its height, most within 10 m in front; film halves it, laminated takes 0.6.
    final class Toy: ProtectionBudget.Evaluator {
        let scene: Scenario
        var looks = 0
        var filmWorks = true
        init(_ scene: Scenario) { self.scene = scene }

        func evaluate(
            barriers: [LiveResponse.WhatIf.Barrier], charge: SIMD3<Float>,
            glass: [UUID: ProtectionBudget.GlassOption]
        ) throws -> ProtectionBudget.Outcome {
            looks += 1
            var out = ProtectionBudget.Outcome.empty
            let q = SIMD2(charge.x, charge.y)
            for object in scene.envelopeObjects {
                let bounds = OccupantInjury.Bounds(object)
                let c = SIMD2(bounds.centre.x, bounds.centre.y)
                var hurt = 1000 / Double(simd_length(c - q))
                for wall in barriers {
                    let (a, b) = wall.ends
                    // Crossing the line from the charge to the building's middle.
                    func side(_ p: SIMD2<Float>, _ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float {
                        (v.x - u.x) * (p.y - u.y) - (v.y - u.y) * (p.x - u.x)
                    }
                    guard side(a, q, c) * side(b, q, c) < 0, side(q, a, b) * side(c, a, b) < 0 else {
                        continue
                    }
                    let behind = Double(simd_length(c - wall.centre)) - Double(bounds.size.x) / 2
                    hurt *= 1 - 0.08 * Double(wall.heightM) * exp(-max(behind, 0) / 10)
                }
                switch glass[object.id] {
                case .film?: if filmWorks { hurt *= 0.5 }
                case .laminated?: hurt *= 0.4
                case nil: break
                }
                out.buildings[object.id] = .init(hurt: hurt, glassM2: hurt)
                out.hurt += hurt
                out.glassM2 += hurt
            }
            return out
        }
    }

    func problem(_ scene: Scenario, budget: Double) -> ProtectionBudget.Problem {
        var p = ProtectionBudget.Problem(scene: scene, budget: budget)
        p.leastWallZ = 1
        return p
    }

    @Test(
        "On the toy the search keeps to its budget, puts a wall close in front, and more money never does worse"
    )
    func toy() throws {
        let (scene, _) = try blocks()
        var last = Double.infinity
        for budget in [0.0, 10_000, 30_000, 100_000, 400_000, 2_000_000] {
            let toy = Toy(scene)
            let result = try ProtectionBudget.optimise(problem(scene, budget: budget), evaluator: toy)
            #expect(result.plan.cost.total <= budget + 1e-6)
            #expect(result.value <= result.asBuiltValue + 1e-9)
            #expect(result.value <= last + 1e-6, "budget \(budget): \(result.value) after \(last)")
            last = result.value
            #expect(result.plan.site.barriers.count <= 2)
            if budget == 0 { #expect(result.plan == .none) }
        }
        // With money for a wall but not for glass on the near block, a tall wall stands close in front of it.
        let toy = Toy(scene)
        toy.filmWorks = false
        var p = problem(scene, budget: 30_000)
        p.glassOptions = []
        let result = try ProtectionBudget.optimise(p, evaluator: toy)
        let wall = try #require(result.plan.site.barriers.first)
        #expect(!wall.alongX && wall.centre.x > 66 && wall.centre.x < 80, "\(wall)")
        #expect(result.value < result.asBuiltValue * 0.9, "\(result.value) against \(result.asBuiltValue)")
        #expect(result.evaluations == toy.looks)
    }

    @Test(
        "Where film is the better buy it is bought, the near block first; the rest goes on the glass thrown")
    func toyGlass() throws {
        let (scene, ids) = try blocks()
        let toy = Toy(scene)
        let glazed = ProtectionBudget.buildings(scene)[0].glazedM2
        var p = problem(scene, budget: glazed * 160 * 1.5)
        p.maxBarriers = 0
        let result = try ProtectionBudget.optimise(p, evaluator: toy)
        #expect(result.plan.glass == [ids[0]: .film])
        #expect(abs(result.plan.cost.glass - glazed * 160) < 1e-6)
    }

    @Test("Offered a stand-off, the finalists hold the best with none and with the most the budget buys")
    func finalists() throws {
        let (scene, _) = try blocks()
        let toy = Toy(scene)
        var p = problem(scene, budget: 200_000)
        // Kept back westward from the near block's west face.
        p.standOff = ProtectionBudget.StandOff(
            from: SIMD2(80, 100), along: SIMD2(-1, 0), range: 0...40, frontageM: 20, wraps: false)
        let result = try ProtectionBudget.optimise(p, evaluator: toy)
        let whys = result.finalists.map(\.why)
        #expect(result.finalists.first?.plan == result.plan)
        #expect(whys.contains("no stand-off") || result.plan.site.standOffM == nil)
        #expect(result.finalists.contains { $0.plan.site.standOffM == 40 }, "\(whys)")
        for f in result.finalists { #expect(f.plan.cost.total <= 200_000 + 1e-6) }
        // The toy's best keeps the charge as far back as it can go.
        #expect(result.plan.site.standOffM == 40)
        // A referee that agrees keeps the search's best.
        let refereed = try ProtectionBudget.referee(result, problem: p, referee: Toy(scene))
        #expect(refereed.keepsTheSearchsBest)
        #expect(refereed.finalists.count == result.finalists.count)
    }

    @Test("Stopped, the search gives the best it has found")
    func stops() throws {
        let (scene, _) = try blocks()
        var heard = 0
        let result = try ProtectionBudget.optimise(problem(scene, budget: 400_000), evaluator: Toy(scene)) {
            p in
            heard += 1
            #expect(p.bestValue <= p.asBuiltValue + 1e-9)
            return heard < 10
        }
        #expect(result.cancelled)
        #expect(heard == 10)
        #expect(result.value <= result.asBuiltValue + 1e-9)
    }

    // MARK: The search on the learned response

    @Test(
        "Through the learned response on the CPU, a plan within budget no worse than as built, Bowen's people"
    )
    func live() throws {
        let (scene, _) = try blocks()
        let weights = try #require(LiveResponse.Weights.builtIn)
        let model = LiveResponse.Model(weights: weights, engine: LiveResponse.CPUEngine(weights: weights))
        var people = OccupantInjury.Assumptions()
        people.glass = .thrownGlass
        let look = ProtectionBudget.Look(
            scene: scene, cellSize: 2, mode: .live(model, leavesUntrainedToCPU: false), people: people)
        var p = ProtectionBudget.Problem(scene: scene, budget: 150_000)
        p.people = people
        p.maxEvaluations = 40
        let result = try ProtectionBudget.optimise(p, evaluator: look)
        #expect(result.plan.cost.total <= 150_000 + 1e-6)
        #expect(result.value <= result.asBuiltValue + 1e-6)
        #expect(result.asBuiltValue > 0)
        // Bowen's people are hurt by the glass thrown, which film holds: some glass is bought.
        #expect(!result.plan.glass.isEmpty, "\(result.plan.label)")
        #expect(result.value < result.asBuiltValue)
        #expect(look.count == result.evaluations)
    }
}
