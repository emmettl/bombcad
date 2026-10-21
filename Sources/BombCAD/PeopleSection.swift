import BlastCore
import SwiftUI

/// People in the scene (emmettl/bombcad-work#41): each building's occupants by use and time of
/// day, and the people the quick estimate expects hurt, with its band and its standing. Shown
/// once a quick estimate has the glass's chances, and labelled illustrative throughout.
struct PeopleSection: View {
    @Bindable var model: SimulationModel

    var body: some View {
        if model.envelopeDamageIsEstimate, !model.envelopeGlassChances.isEmpty {
            Section("People in the scene") {
                // Before anything else: what this is not.
                Label(OccupantInjury.warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Picker("Time of day", selection: $model.occupancy.time) {
                    ForEach(OccupancyTime.allCases) { Text($0.label).tag($0) }
                }
                .help("Where people are, by Hazus's default distribution for 2 am, 2 pm and 5 pm.")
                Picker("Untagged buildings", selection: $model.occupancy.untaggedUse) {
                    ForEach(BuildingUse.allCases) { Text($0.label).tag($0) }
                }
                .help(
                    "The use of buildings whose map tags say none (most of a map's). Tagged buildings take their tag's."
                )
                Picker("Density", selection: $model.occupancy.densityScale) {
                    Text("×0.5").tag(0.5)
                    Text("×0.75").tag(0.75)
                    Text("As planned").tag(1.0)
                    Text("×1.5").tag(1.5)
                    Text("×2").tag(2.0)
                }
                .help("A factor on every use's people per floor area (docs/people-in-the-scene.md).")
                if let people = model.peopleEstimate {
                    Text(people.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                    if people.preview {
                        Text(
                            "Preview while dragging: the glass's chances alone, \(SimulationModel.peopleDraws.preview) draws of the assumptions; the walls and roofs follow when you let go."
                        )
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    if model.envelopeColouring == .peopleHurt {
                        EnvelopeDamageSection.ChanceLegend()
                        Text("Each building by the share of its people expected hurt.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Colour Buildings by People Hurt") {
                            model.showsEnvelopeDamage = true
                            model.envelopeColouring = .peopleHurt
                        }
                        .help(
                            "Colour each building by the share of its people expected hurt; it follows a drag."
                        )
                    }
                    ForEach(Self.worst(people), id: \.owner) { building in
                        LabeledContent(model.settings.scenario.object(id: building.owner)?.name ?? "Building")
                        {
                            Text(
                                "\(OccupantInjury.count(building.expected)) of \(OccupantInjury.count(building.occupants + building.outdoors))"
                            )
                            .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .help(
                            "\(building.use.label)\(building.useAssumed ? " (assumed)" : ""), "
                                + String(
                                    format:
                                        "%.0f m² of floor; %.0f%% of its panes expected broken; hurt %@–%@.",
                                    building.floorAreaM2, building.broken * 100,
                                    OccupantInjury.count(building.low),
                                    OccupantInjury.count(building.high)))
                    }
                }
                ForEach(OccupantInjury.standing, id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                }
            }
            .monospacedDigit()
        }
    }

    /// The five buildings with the most people expected hurt.
    static func worst(_ estimate: OccupantInjury.Estimate) -> [OccupantInjury.Building] {
        Array(estimate.buildings.filter { $0.expected >= 0.5 }.sorted { $0.expected > $1.expected }.prefix(5))
    }
}
