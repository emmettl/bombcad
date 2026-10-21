import BlastCore
import Foundation

// People in the scene (emmettl/bombcad-work#41): the quick estimate's chances turned into each
// building's occupants and the people it would expect hurt (`OccupantInjury`), following the
// charge as it is dragged. Illustrative, and labelled so wherever it is shown.
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
