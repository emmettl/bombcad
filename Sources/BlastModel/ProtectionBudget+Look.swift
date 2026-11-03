import Foundation
import simd

extension ProtectionBudget {
    /// The quick estimate as the budget's search asks it: the district laid out once, each look with
    /// the walls laid in its raster again (`Prepared.withBlocks`) and each plan's glass in its
    /// constructions (`withConstructions`); the glass by the learned response (`live`), as a drag's
    /// preview, or by the full estimate (`full`), as on a let-go; and the people over it.
    public final class Look: Evaluator, @unchecked Sendable {
        public enum Mode: Sendable {
            /// The learned response, `leavesUntrainedToCPU` as the drag's: 10 yields spread evenly,
            /// the people on 40 draws.
            case live(LiveResponse.Model, leavesUntrainedToCPU: Bool)
            /// The CPU's preview, the SDOF on each group's nearest component, as a drag's without the
            /// learned response.
            case preview
            /// The full estimate: 100 drawn yields, the people on 200 draws.
            case full
        }

        public let scene: Scenario
        public let mode: Mode
        public let terms: FacadeLoadSurrogate.TermSet
        public let people: OccupantInjury.Assumptions
        /// Whether the walls' and roofs' chances are worked out for the people too (the full estimate's
        /// people take them; the drag's preview of the people does not).
        public let structure: Bool
        /// The yield's spread: nine times in ten within this factor.
        public let yieldWithin: Double
        let base: FacadeLoadSurrogate.Prepared
        let buildings: [UUID: Building]
        private var built: [[UUID: GlassOption]: FacadeLoadSurrogate.Prepared] = [:]
        private var order: [[UUID: GlassOption]] = []
        /// How many looks, and how long they took, s.
        public private(set) var count = 0
        public private(set) var seconds = 0.0

        public init(
            scene: Scenario, cellSize: Float, mode: Mode, terms: FacadeLoadSurrogate.TermSet = .adopted,
            people: OccupantInjury.Assumptions = OccupantInjury.Assumptions(), structure: Bool = false,
            yieldWithin: Double = 1.5, prepared: FacadeLoadSurrogate.Prepared? = nil
        ) {
            self.scene = scene
            self.mode = mode
            self.terms = terms
            self.people = people
            self.structure = structure
            self.yieldWithin = yieldWithin
            base =
                prepared
                ?? FacadeLoadSurrogate.Prepared(
                    scene: scene, cellSize: cellSize, incidence: terms.coefficients.incidence)
            buildings = Dictionary(
                ProtectionBudget.buildings(scene).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }

        /// The scene with the plan in it.
        public func scene(barriers: [LiveResponse.WhatIf.Barrier], glass: [UUID: GlassOption]) -> Scenario {
            LiveResponse.WhatIf(
                barrier: barriers.first, moreBarriers: Array(barriers.dropFirst()),
                glassOf: glass.mapValues(\.glass)
            ).applied(to: scene)
        }

        public func evaluate(
            barriers: [LiveResponse.WhatIf.Barrier], charge: SIMD3<Float>, glass: [UUID: GlassOption]
        ) throws -> Outcome {
            let start = ContinuousClock.now
            let planned = scene(barriers: barriers, glass: glass)
            var prepared = base
            if !glass.isEmpty {
                if let known = built[glass] {
                    prepared = known
                } else {
                    prepared = base.withConstructions(of: planned)
                    built[glass] = prepared
                    order.append(glass)
                    // Only a few kept: every building's glass for the gains, and the plans'.
                    if order.count > 4 { built[order.removeFirst()] = nil }
                }
            }
            if planned.boxes != scene.boxes { prepared = prepared.withBlocks(planned.boxes) }
            let mass = Double(scene.charge.mass)
            let live: Bool
            let parts: FacadeLoadSurrogate.Prepared.Parts = structure ? [.glass, .structure] : .glass
            var uncertainty = FacadeLoadSurrogate.Uncertainty(
                yieldLogSD: log(yieldWithin) / 1.645, loadScatter: terms.loadScatter, samples: 100)
            let look: FacadeLoadSurrogate.Prepared.Look
            switch mode {
            case .live(let model, let leaves):
                live = true
                uncertainty.samples = structure ? 20 : 10
                uncertainty.stratified = true
                look =
                    try prepared.livePreview(
                        charge: charge, mass: mass, uncertainty: uncertainty, parts: parts, terms: terms,
                        model: model,
                        leavesUntrainedToCPU: leaves)?.look
                    ?? prepared.look(
                        charge: charge, mass: mass, constructions: { planned.envelopeConstruction(for: $0) },
                        uncertainty: uncertainty, preview: true, parts: parts, terms: terms)
            case .preview:
                live = true
                uncertainty.samples = structure ? 20 : 10
                uncertainty.stratified = true
                look = prepared.look(
                    charge: charge, mass: mass, constructions: { planned.envelopeConstruction(for: $0) },
                    uncertainty: uncertainty, preview: true, parts: parts, terms: terms)
            case .full:
                live = false
                uncertainty.stratified = false
                look = prepared.look(
                    charge: charge, mass: mass, constructions: { planned.envelopeConstruction(for: $0) },
                    uncertainty: uncertainty, parts: parts, terms: terms)
            }
            let estimate = OccupantInjury.estimate(
                scene: planned, glass: look.glass, structure: structure ? look.structure : [], charge: charge,
                mass: mass, assumptions: people, preview: live, draws: live ? 40 : 200)
            let thrown = ProtectionBudget.glassThrown(look.glass, buildings: buildings)
            var outcome = Outcome(
                hurt: estimate.expected, severe: estimate.severe, glassM2: thrown.values.reduce(0, +),
                buildings: [:])
            for b in estimate.buildings {
                outcome.buildings[b.owner] = Outcome.Building(hurt: b.expected, glassM2: thrown[b.owner] ?? 0)
            }
            for (id, m2) in thrown where outcome.buildings[id] == nil {
                outcome.buildings[id] = Outcome.Building(hurt: 0, glassM2: m2)
            }
            count += 1
            let took = start.duration(to: .now)
            seconds += Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
            return outcome
        }
    }
}
