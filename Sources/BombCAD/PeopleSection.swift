import BlastCore
import SwiftUI

/// People in the scene (emmettl/bombcad-work#41): where the quick estimate's people are hurt, as
/// shares by building and by distance, and how a place of the charge, the time of day or a
/// protection changes it against a pinned baseline. The counts, which read 4–12 times Beirut's
/// record, are behind a disclosure with that warning.
struct PeopleSection: View {
    @Bindable var model: SimulationModel
    @State private var showsCounts = false

    var body: some View {
        if model.envelopeDamageIsEstimate, !model.envelopeGlassChances.isEmpty {
            Section("People in the scene") {
                // Before anything else: what this is.
                Label(OccupantInjury.relativeNote, systemImage: "exclamationmark.triangle")
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
                    comparison(people)
                    if people.preview {
                        Text(
                            "Preview while dragging: the glass's chances alone, \(SimulationModel.peopleDraws.preview) draws of the assumptions; the walls and roofs follow when you let go."
                        )
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    shares(people)
                    DisclosureGroup("Show counts", isExpanded: $showsCounts) {
                        Text(OccupantInjury.warning).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(people.summary).font(.caption).fixedSize(horizontal: false, vertical: true)
                        ForEach(Self.worst(people), id: \.owner) { building in
                            LabeledContent(name(building)) {
                                Text(
                                    "\(OccupantInjury.count(building.expected)) of \(OccupantInjury.count(building.occupants + building.outdoors))"
                                )
                                .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                        ForEach(OccupantInjury.countsStanding, id: \.self) {
                            Text($0).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.caption)
                }
                ForEach(OccupantInjury.standing, id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                }
            }
            .monospacedDigit()
        }
    }

    /// Against the pinned baseline, and the buttons to pin one or let it go.
    @ViewBuilder private func comparison(_ people: OccupantInjury.Estimate) -> some View {
        if let line = model.peopleComparisonLine {
            Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
        } else {
            Text(
                "Pin a baseline, then move the charge, change the time of day or protect a building to see the change."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Button(model.peopleBaseline == nil ? "Pin as Baseline" : "Pin This Instead") {
                model.pinPeopleBaseline()
            }
            .disabled(people.preview)
            .help(
                "Compare the next estimates with this one: the charge, the time of day and the buildings as they are now."
            )
            if model.peopleBaseline != nil {
                Button("Clear Baseline") { model.peopleBaseline = nil }
            }
        }
    }

    /// Where people are hurt: the share by distance, the colouring, and the buildings with the most.
    @ViewBuilder private func shares(_ people: OccupantInjury.Estimate) -> some View {
        let hurt = people.people > 0 ? people.expected / people.people : 0
        Text(String(format: "Share of the people placed expected hurt: %.0f%%.", hurt * 100))
            .font(.caption)
        ForEach(OccupantInjury.bands(people)) { band in
            LabeledContent(
                band.toM.isFinite
                    ? String(format: "%.0f–%.0f m", band.fromM, band.toM)
                    : String(format: "Beyond %.0f m", band.fromM)
            ) {
                Text(
                    String(
                        format: "%.0f%% hurt, %.0f%% of the hurt", band.share * 100,
                        people.expected > 0 ? band.hurt / people.expected * 100 : 0)
                )
                .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        if model.envelopeColouring == .peopleHurt {
            EnvelopeDamageSection.ChanceLegend()
            Text("Each building by the share of its people expected hurt.").font(.caption).foregroundStyle(
                .secondary)
        } else {
            Button("Colour Buildings by People Hurt") {
                model.showsEnvelopeDamage = true
                model.envelopeColouring = .peopleHurt
            }
            .help("Colour each building by the share of its people expected hurt; it follows a drag.")
        }
        ForEach(Self.mostHurt(people), id: \.owner) { building in
            LabeledContent(name(building)) {
                Text(String(format: "%.0f%% of its people", building.share * 100)).foregroundStyle(.secondary)
            }
            .font(.caption)
            .help(
                "\(building.use.label)\(building.useAssumed ? " (assumed)" : ""), "
                    + String(
                        format:
                            "%.0f m from the charge, %.0f m² of floor; %.0f%% of its panes expected broken.",
                        building.distanceM, building.floorAreaM2, building.broken * 100))
        }
    }

    private func name(_ building: OccupantInjury.Building) -> String {
        model.settings.scenario.object(id: building.owner)?.name ?? "Building"
    }

    /// The five buildings with the most people expected hurt.
    static func worst(_ estimate: OccupantInjury.Estimate) -> [OccupantInjury.Building] {
        Array(estimate.buildings.filter { $0.expected >= 0.5 }.sorted { $0.expected > $1.expected }.prefix(5))
    }

    /// The five buildings with the largest share of their people hurt, of those with people.
    static func mostHurt(_ estimate: OccupantInjury.Estimate) -> [OccupantInjury.Building] {
        Array(
            estimate.buildings.filter { $0.occupants + $0.outdoors >= 1 }.sorted { $0.share > $1.share }
                .prefix(5))
    }
}
