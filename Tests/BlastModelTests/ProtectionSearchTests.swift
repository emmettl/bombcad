import Foundation
import Testing

@testable import BlastModel

/// The protective-design search (`ProtectionSearch`) against the prototype's
/// (`Scripts/protective/search.py`), on the prototype's own problems and chances
/// (Fixtures/ProtectiveDesign/prototype.json, `Scripts/protective/export.py`).
@Suite("Protective design search")
struct ProtectionSearchTests {
    struct Scenario: Decodable {
        struct PlanJSON: Decodable {
            var site: [Int]
            var cost: Double
            var meets: Bool
            var choices: [[String]]
        }
        var scenario: String
        var targetChance: Double
        var site: [ProtectionSearch.SiteChange]
        var sides: [ProtectionSearch.Side]
        var chances: [String: [[Double]]]
        var best: PlanJSON
        var ranked: [PlanJSON]
        var greedy: PlanJSON
        var annealed: PlanJSON
        var asBuilt: PlanJSON
    }

    static func scenarios() throws -> [Scenario] {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures/ProtectiveDesign/prototype.json")
        return try JSONDecoder().decode([Scenario].self, from: Data(contentsOf: url))
    }

    static func problem(_ s: Scenario) -> ProtectionSearch.Problem {
        let table = s.chances
        return ProtectionSearch.Problem(sides: s.sides, site: s.site, targetChance: s.targetChance) {
            site, side, option in
            table[site.map(String.init).joined(separator: ",")]![side][option]
        }
    }

    /// A plan's choices as the prototype names them: each side's (glazing, wall).
    static func named(_ plan: ProtectionSearch.Plan, _ s: Scenario) -> [[String]] {
        plan.choices.enumerated().map { side, option in
            [s.sides[side].options[option].glazing, s.sides[side].options[option].wall]
        }
    }

    static func same(_ plan: ProtectionSearch.Plan, _ expected: Scenario.PlanJSON, _ s: Scenario) -> Bool {
        plan.site == expected.site && abs(plan.cost - expected.cost) < 1e-6 && plan.meets == expected.meets
            && named(plan, s) == expected.choices
    }

    @Test("Finds the prototype's plans on its problems: the exact best, the ranked list, greedy's, as built")
    func matchesPrototype() throws {
        let scenarios = try Self.scenarios()
        #expect(scenarios.map(\.scenario) == ["courtyard", "street", "weak-shielding"])
        for s in scenarios {
            let problem = Self.problem(s)
            let plans = ProtectionSearch.exact(problem)
            #expect(plans.count == 1 << s.site.count)
            let best = ProtectionSearch.best(plans, target: s.targetChance)
            #expect(Self.same(best, s.best, s), "\(s.scenario): best \(best.site) \(best.cost)")
            let ranked = ProtectionSearch.ranked(problem, plans: plans)
            #expect(ranked.count == s.ranked.count)
            for (a, b) in zip(ranked, s.ranked) {
                #expect(
                    Self.same(a, b, s),
                    "\(s.scenario): ranked \(a.site) \(a.cost) against \(b.site) \(b.cost)")
            }
            let greedy = ProtectionSearch.greedy(problem)
            #expect(Self.same(greedy, s.greedy, s), "\(s.scenario): greedy \(greedy.site) \(greedy.cost)")
            #expect(Self.same(ProtectionSearch.asBuilt(problem), s.asBuilt, s))
            // Annealing walks its own random path; like the prototype's it reaches the optimum.
            let annealed = ProtectionSearch.anneal(problem)
            #expect(abs(annealed.cost - s.annealed.cost) < 1e-6 && annealed.site == s.annealed.site)
        }
    }

    @Test("Combinations come in the order Python's itertools gives them")
    func combinations() {
        #expect(
            ProtectionSearch.combinations(4, 2) == [[0, 1], [0, 2], [0, 3], [1, 2], [1, 3], [2, 3]])
        #expect(ProtectionSearch.combinations(3, 0) == [[]])
        #expect(ProtectionSearch.combinations(3, 3) == [[0, 1, 2]])
    }

    @Test(
        "On BombCAD's model: stronger glazing and stand-off lower a side's chance, infill ends it, and the best plan meets the target"
    )
    func bombcadModel() throws {
        let scene = try FacadeGlassProbabilityTests.row()
        let inputs = ProtectionModel.Inputs(
            threats: [.init(mass: 100, x: 10, y: 30)],
            target: .init(worseThan: "3b", chance: 0.1, buildings: nil),
            glazing: [
                .init(name: "toughened", kind: .toughened, costPerM2: 4),
                .init(name: "laminated", kind: .laminated, costPerM2: 5),
                .init(name: "infill", kind: .infill, costPerM2: 6),
            ],
            standOffs: [.init(name: "keep it back", cost: 50, moves: [.init(threat: 0, x: -60, y: 30)])],
            barriers: nil, draws: 4, seed: 1)
        let model = try ProtectionModel.model(scene: scene, cellSize: 2, inputs: inputs)
        let problem = model.problem
        #expect(problem.sides.count == 16)
        // The nearest block's side facing the charge.
        let front = try #require(model.names.firstIndex { $0.hasSuffix("west") })
        let annealed = problem.chance([], front, 0)
        #expect(annealed > 0.5)
        #expect(problem.chance([], front, 1) <= annealed)
        #expect(problem.chance([], front, 3) == 0)
        #expect(problem.chance([0], front, 0) < annealed)
        let best = ProtectionSearch.best(ProtectionSearch.exact(problem), target: 0.1)
        #expect(best.meets)
        #expect(best.chances.allSatisfy { $0 <= 0.1 })
        #expect(ProtectionSearch.greedy(problem).cost >= best.cost - 1e-9)
    }

    @Test("A flag margin steps a side within its scatter of the target one option further; greedy alike")
    func flagMargin() {
        let options = [
            ProtectionSearch.Option(glazing: "as built", wall: "as built", cost: 0),
            ProtectionSearch.Option(glazing: "film", wall: "as built", cost: 1),
            ProtectionSearch.Option(glazing: "toughened", wall: "as built", cost: 2),
        ]
        let sides = (0..<3).map { ProtectionSearch.Side(name: "side \($0)", options: options) }
        // Each side's chance by option, and at the upper quantile of its load.
        let chance: [[Double]] = [[0.08, 0.01, 0.005], [0.5, 0.05, 0.01], [0.01, 0.001, 0.001]]
        let upper: [[Double]] = [[0.3, 0.05, 0.02], [0.9, 0.2, 0.05], [0.05, 0.01, 0.01]]
        let plain = ProtectionSearch.Problem(sides: sides, site: [], targetChance: 0.1) { _, s, o in
            chance[s][o]
        }
        let flagged = ProtectionSearch.Problem(
            sides: sides, site: [], targetChance: 0.1, chance: { _, s, o in chance[s][o] },
            upper: { _, s, o in upper[s][o] })
        #expect(ProtectionSearch.plan(plain, site: []).choices == [0, 1, 0])
        #expect(flagged.flagged([], 0, 0) && flagged.flagged([], 1, 1) && !flagged.flagged([], 2, 0))
        let plan = ProtectionSearch.plan(flagged, site: [])
        #expect(plan.choices == [1, 2, 0])
        #expect(plan.meets && abs(plan.cost - 3) < 1e-12)
        #expect(ProtectionSearch.greedy(flagged).choices == plan.choices)
    }

    @Test(
        "Margins on BombCAD's model: the load held up raises a side's chance; a target margin is the search's"
    )
    func modelMargins() throws {
        let scene = try FacadeGlassProbabilityTests.row()
        var inputs = ProtectionModel.Inputs(
            threats: [.init(mass: 100, x: 10, y: 30)],
            target: .init(worseThan: "3b", chance: 0.1, buildings: nil),
            glazing: [.init(name: "toughened", kind: .toughened, costPerM2: 4)], draws: 4, seed: 1)
        // By default the clear-top terms with flag 2.5, adopted on 25 October 2026
        // (emmettl/bombcad-work#102); `none` and the terms of 23 October are the planner before.
        let adopted = try ProtectionModel.model(scene: scene, cellSize: 2, inputs: inputs)
        #expect(
            adopted.margin == .adopted && adopted.terms == .clearTop && adopted.problem.targetChance == 0.1)
        #expect(ProtectionModel.Margin.adopted == .init(kind: .flag, value: 2.5))
        inputs.margin = .off
        let plain = try ProtectionModel.model(scene: scene, cellSize: 2, inputs: inputs)
        #expect(plain.margin == nil && plain.problem.targetChance == 0.1 && plain.accepted == 0.1)
        for s in plain.problem.sides.indices {
            #expect(adopted.problem.chance([], s, 0) == plain.problem.chance([], s, 0))
            #expect(
                plain.problem.upperChance([], s, 0) == nil && adopted.problem.upperChance([], s, 0) != nil)
        }
        let before = try ProtectionModel.model(scene: scene, cellSize: 2, inputs: inputs, terms: .fitted)
        #expect(before.terms == .fitted && before.margin == nil)
        #expect(
            ProtectionModel.Margin("flag:2.5") == .adopted && ProtectionModel.Margin("none") == .off
                && ProtectionModel.Margin.off.description == "none")
        #expect(ProtectionModel.Margin("none:1") == nil)
        let decoded = try JSONDecoder().decode(
            ProtectionModel.Margin.self, from: Data(#"{"kind": "none", "value": 0}"#.utf8))
        #expect(decoded == .off)
        #expect(ProtectionModel.Margin("quantile") == nil && ProtectionModel.Margin("wide:1") == nil)
        // Every side's chance with its load held at 0, 1 and 2 standard deviations up.
        let held = try [0.0, 1, 2].map { z in
            inputs.margin = .init(kind: .quantile, value: z)
            return try ProtectionModel.model(scene: scene, cellSize: 2, inputs: inputs).problem
        }
        var raised = false
        for s in plain.problem.sides.indices {
            for o in 0..<2 {
                let p = held.map { $0.chance([], s, o) }
                #expect(p[0] <= p[1] && p[1] <= p[2])
                raised = raised || p[2] > p[0]
            }
        }
        #expect(raised)
        inputs.margin = .init(kind: .target, value: 0.02)
        let lower = try ProtectionModel.model(scene: scene, cellSize: 2, inputs: inputs)
        #expect(lower.problem.targetChance == 0.02 && lower.accepted == 0.1)
        inputs.margin = .init(kind: .flag, value: 2)
        let flag = try ProtectionModel.model(scene: scene, cellSize: 2, inputs: inputs).problem
        for s in flag.sides.indices {
            #expect(flag.chance([], s, 0) == plain.problem.chance([], s, 0))
            #expect(flag.upperChance([], s, 0) == held[2].chance([], s, 0))
        }
    }

    @Test("A barrier wall is in the loads' way; a scene's stand-off line stops the charge at it")
    func barriersAndLines() throws {
        var scene = try FacadeGlassProbabilityTests.row()
        // A fence 5 m east of the domain's edge guarding the buildings (east of it), the charge 5 m inside.
        scene.standOffLines = [
            StandOffLine(name: "Fence", points: [SIMD2(5, 0), SIMD2(5, 60)], guardsLeft: false)
        ]
        let inputs = ProtectionModel.Inputs(
            threats: [.init(mass: 100, x: 10, y: 30)],
            target: .init(worseThan: "3b", chance: 0.1, buildings: nil),
            glazing: [.init(name: "laminated", kind: .laminated, costPerM2: 5)],
            standOffs: [
                .init(name: "the fence", cost: 30, line: "Fence"),
                .init(name: "moved by hand", cost: 30, moves: [.init(threat: 0, x: 4, y: 30)]),
            ],
            barriers: [
                .init(
                    name: "a wall", cost: 60, from: SIMD2(20, 15), to: SIMD2(20, 45), height: 10,
                    thickness: 0.5)
            ],
            draws: 4, seed: 1)
        let model = try ProtectionModel.model(scene: scene, cellSize: 2, inputs: inputs)
        let problem = model.problem
        #expect(problem.site.map(\.name) == ["the fence", "moved by hand", "a wall"])
        let front = try #require(model.names.firstIndex { $0.hasSuffix("west") })
        let asBuilt = problem.chance([], front, 0)
        #expect(asBuilt > 0.5)
        // The fence stops the charge a metre outside it, as the moves given by hand do.
        #expect(problem.chance([0], front, 0) == problem.chance([1], front, 0))
        #expect(problem.chance([0], front, 0) <= asBuilt)
        // The wall, 10 m high between them, is in the loads' way: crossed, its shadow over the front.
        // The surrogate was not fitted on barriers and takes little off for it (2% of the peak here,
        // docs/protective-design.md): no more than the chance as built.
        var walled = scene
        let id = try walled.addBarrier(from: SIMD2(20, 15), to: SIMD2(20, 45), height: 10, thickness: 0.5)
        let wall = try #require(walled.object(id: id)?.fixedBox)
        let objects = scene.envelopeObjects
        let plain = FacadeLoadSurrogate.Raster(objects: objects, terrain: nil, cell: 2)
        let shielded = FacadeLoadSurrogate.Raster(objects: objects, blocks: [wall], terrain: nil, cell: 2)
        let strips = objects[0].envelope!.components(owner: objects[0].id, cellSize: 2).filter {
            $0.kind == .facade && $0.axis == 0 && $0.outward < 0
        }
        #expect(!strips.isEmpty)
        for strip in strips {
            let open = FacadeLoadSurrogate.features(
                strip, owner: 0, charge: SIMD3(10, 30, 0.5), raster: plain)
            let behind = FacadeLoadSurrogate.features(
                strip, owner: 0, charge: SIMD3(10, 30, 0.5), raster: shielded)
            #expect(open.buildingsCrossed == 0 && behind.buildingsCrossed == 1 && behind.shadowM > 0)
            #expect(
                FacadeLoadSurrogate.predict(behind, mass: 5, cellSize: 2).peakPa
                    < FacadeLoadSurrogate.predict(open, mass: 5, cellSize: 2).peakPa)
        }
        #expect(problem.chance([2], front, 0) <= asBuilt)
        // A line the scene lacks, and a wall the scene cannot build, are refused.
        var unknown = inputs
        unknown.standOffs = [.init(name: "nowhere", cost: 1, line: "Gate")]
        #expect(throws: ProtectionModel.InputError.self) {
            _ = try ProtectionModel.model(scene: scene, cellSize: 2, inputs: unknown)
        }
        var slanted = inputs
        slanted.barriers = [
            .init(name: "slanted", cost: 1, from: SIMD2(15, 15), to: SIMD2(25, 45), height: 3)
        ]
        #expect(throws: ProtectionModel.InputError.self) {
            _ = try ProtectionModel.model(scene: scene, cellSize: 2, inputs: slanted)
        }
    }
}
