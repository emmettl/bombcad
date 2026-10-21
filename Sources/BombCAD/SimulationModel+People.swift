import BlastCore
import Foundation
import simd

// People in the scene (emmettl/bombcad-work#41): the quick estimate's chances turned into each
// building's occupants and the people it would expect hurt (`OccupantInjury`), following the
// charge as it is dragged. Illustrative: the planner shows shares, and changes against a baseline
// the user pins, with the counts behind a disclosure.

/// A people's estimate pinned to compare others with, and what it was made for.
struct PeopleBaseline: Equatable {
    var estimate: OccupantInjury.Estimate
    var charge: SIMD3<Float>
    var mass: Float
    var assumptions: OccupantInjury.Assumptions
    var constructions: [EnvelopeConstruction]

    /// What differs now from the pinned estimate, in words: "the charge 40 m away, 2 am, the
    /// constructions changed"; empty when nothing does.
    func differences(
        charge now: SIMD3<Float>, mass: Float, assumptions: OccupantInjury.Assumptions,
        constructions: [EnvelopeConstruction]
    ) -> [String] {
        var out: [String] = []
        let moved = simd_length(SIMD2(now.x - charge.x, now.y - charge.y))
        if moved >= 0.5 { out.append(String(format: "the charge %.0f m from the pinned one", moved)) }
        if mass != self.mass {
            out.append(String(format: "the charge ×%.2g", Double(mass / max(self.mass, 1e-9))))
        }
        if assumptions.time != self.assumptions.time { out.append(assumptions.time.label.lowercased()) }
        if assumptions.untaggedUse != self.assumptions.untaggedUse {
            out.append("untagged buildings \(assumptions.untaggedUse.label.lowercased())")
        }
        if assumptions.densityScale != self.assumptions.densityScale {
            out.append(String(format: "density ×%g", assumptions.densityScale))
        }
        if constructions != self.constructions { out.append("the buildings' constructions changed") }
        return out
    }
}

extension SimulationModel {
    /// The draws over the assumptions a preview takes, and a full estimate.
    static let peopleDraws = (preview: 40, full: 200)

    /// Works out the people again from the chances on screen; none without the estimate's glass.
    func refreshPeople() {
        guard envelopeDamageIsEstimate, !envelopeGlassChances.isEmpty else {
            peopleEstimate = nil
            return
        }
        let preview = envelopeEstimateIsPreview
        let scenario = settings.scenario
        peopleEstimate = OccupantInjury.estimate(
            scene: scenario, glass: envelopeGlassChances,
            structure: peopleUsesStructure ? envelopeStructureChances : [], charge: scenario.charge.position,
            mass: Double(scenario.charge.mass), assumptions: occupancy, preview: preview,
            draws: preview ? Self.peopleDraws.preview : Self.peopleDraws.full)
        if envelopeColouring == .peopleHurt { applyEnvelopeDamageColours() }
    }

    /// Pins the people's estimate shown, a full one, as the baseline the next are compared with.
    func pinPeopleBaseline() {
        guard let estimate = peopleEstimate, !estimate.preview else { return }
        let scenario = settings.scenario
        peopleBaseline = PeopleBaseline(
            estimate: estimate, charge: scenario.charge.position, mass: scenario.charge.mass,
            assumptions: occupancy, constructions: scenario.envelopeConstructions ?? [])
    }

    /// The estimate shown against the pinned one; nil without both.
    var peopleComparison: OccupantInjury.Comparison? {
        guard let peopleEstimate, let peopleBaseline else { return nil }
        return OccupantInjury.compare(peopleEstimate, against: peopleBaseline.estimate)
    }

    /// The comparison in words: "−38% hurt (…) against the pinned baseline: the charge 40 m from the
    /// pinned one"; nil without a comparison.
    var peopleComparisonLine: String? {
        guard let comparison = peopleComparison, let peopleBaseline else { return nil }
        let scenario = settings.scenario
        let changed = peopleBaseline.differences(
            charge: scenario.charge.position, mass: scenario.charge.mass, assumptions: occupancy,
            constructions: scenario.envelopeConstructions ?? [])
        var line = comparison.summary + " against the pinned baseline"
        line += changed.isEmpty ? ": nothing changed." : ": " + changed.joined(separator: ", ") + "."
        if !comparison.sameBuildings {
            line += " Its buildings are not these: the change is the district's as a whole."
        }
        return line
    }

    /// Each building's colour code by the share of its people expected hurt, the same on every side.
    func peopleCodes() -> [UUID: Int] {
        Dictionary(
            uniqueKeysWithValues: (peopleEstimate?.buildings ?? []).map { building in
                let share = building.share
                return (
                    building.owner,
                    EnvelopeChanceColour.code([(0, -1, share), (0, 1, share), (1, -1, share), (1, 1, share)])
                )
            })
    }
}
