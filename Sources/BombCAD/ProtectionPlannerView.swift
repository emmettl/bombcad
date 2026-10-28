import BlastCore
import SwiftUI

/// Simulation ▸ Protective Design: the least costly glazing changes that keep each building side's
/// chance of glass thrown worse than its target under the chance accepted (`ProtectionModel`,
/// `ProtectionSearch`; docs/protective-design.md). An estimate on the façade load surrogate's loads,
/// never a run: illustrative until a run confirms it.
struct ProtectionPlannerView: View {
    let model: SimulationModel
    @State var planner: ProtectionPlannerModel
    @Environment(\.dismiss) private var dismiss

    static let conditions: [GlazingHazard.Condition] = [.two, .threeA, .threeB, .four]

    var body: some View {
        @Bindable var planner = planner
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Protective design").font(.title2)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Text(
                    "The least costly glazing changes that keep each building side's chance of glass thrown worse than its target under the chance you accept, against the scene's charges. Each side's chance comes from the quick estimate's loads, drawn over their scatter and the glass's strength: an estimate, not a run. A side that passes on its chance, but not with its load well up its scatter, is given the next dearer change, so that a plan meets its target on a run's one load per side. Walls and roofs are not searched."
                )
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                target(planner)
                changes(planner)
                HStack {
                    Button(planner.isRunning ? "Searching…" : "Search") {
                        planner.search(model.settings.scenario, cellSize: model.settings.resolution.cellSize)
                    }
                    .disabled(planner.isRunning || !planner.changes.contains(where: \.allowed))
                    .keyboardShortcut(.defaultAction)
                    if planner.isRunning { ProgressView().controlSize(.small) }
                    if !planner.plans.isEmpty, !planner.isRunning {
                        Text(
                            String(
                                format: "%d sides in %.0f s", planner.model?.problem.sides.count ?? 0,
                                planner.seconds)
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = planner.error {
                    Text(error).foregroundStyle(.red).font(.callout).fixedSize(
                        horizontal: false, vertical: true)
                }
                if !planner.plans.isEmpty { plans(planner) }
            }
            .padding(20)
        }
        .frame(width: 640, alignment: .leading).frame(minHeight: 560, alignment: .top)
        .onChange(of: planner.selected) { model.showProtectionPlan(planner.selectedChances) }
        .onAppear { planner.offerLines(of: model.settings.scenario) }
        .onDisappear { model.showProtectionPlan([:]) }
    }

    private func target(_ planner: ProtectionPlannerModel) -> some View {
        @Bindable var planner = planner
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Target")
                HStack {
                    Picker("Worst glazing condition", selection: $planner.condition) {
                        ForEach(Self.conditions, id: \.self) { Text("GSA \($0.rawValue)").tag($0) }
                    }
                    .labelsHidden().frame(width: 100)
                    .accessibilityLabel("Worst glazing condition allowed")
                    Text("or better, except with a chance under")
                    TextField("Chance (%)", value: $planner.chance, format: .percent).frame(width: 60)
                        .accessibilityLabel("Largest chance accepted")
                }
            }
            GridRow {
                Text("Draws")
                HStack {
                    TextField("Draws", value: $planner.draws, format: .number).frame(width: 60)
                        .accessibilityLabel("Draws for each side's chance")
                    Text("for each side's chance; more are steadier and slower").font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text("")
                Toggle("Planner of 23 October (earlier plans)", isOn: $planner.earlierSettings)
                    .help(
                        "The façade terms of 23 October and no margin for the scatter between sides, as the planner was until 25 October 2026, to reproduce an earlier plan. Off, the deep-city façade terms, each wall facing as the cells (the quick estimate's until 28 October 2026), and a side that passes on its chance but not with its load 2.5 standard deviations of its scatter up is given the next dearer change (docs/protective-design.md)."
                    )
            }
        }
    }

    private func changes(_ planner: ProtectionPlannerModel) -> some View {
        @Bindable var planner = planner
        return VStack(alignment: .leading, spacing: 6) {
            Text("Changes allowed").font(.headline)
            ForEach($planner.changes) { $change in
                HStack {
                    Toggle(change.name, isOn: $change.allowed).frame(width: 240, alignment: .leading)
                    TextField("Cost", value: $change.costPerM2, format: .number).frame(width: 70)
                        .disabled(!change.allowed)
                        .accessibilityLabel("\(change.name): cost per square metre of glass")
                    Text("per m² of glass").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(
                "The costs are yours, in any unit: the ones shown are only the usual order (film cheapest, then toughened and laminated glass, then filling the window in). Barrier walls are searched headless (scenebench protect): the loads take little off for one yet (docs/protective-design.md)."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !planner.lines.isEmpty {
                Text("Stand-off lines").font(.headline).padding(.top, 4)
                ForEach($planner.lines) { $line in
                    HStack {
                        Toggle(line.name, isOn: $line.allowed).frame(width: 240, alignment: .leading)
                        TextField("Cost", value: $line.cost, format: .number).frame(width: 70)
                            .disabled(!line.allowed)
                            .accessibilityLabel("\(line.name): cost of putting it up")
                        Text("for the line").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(
                    "The scene's lines: each charge on the side a line guards is stopped a metre outside it."
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func plans(_ planner: ProtectionPlannerModel) -> some View {
        @Bindable var planner = planner
        let target = planner.model?.problem.targetChance ?? planner.chance
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Plans, the cheapest meeting the target first").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Cost").gridColumnAlignment(.trailing)
                    Text("Meets")
                    Text("Sides failing").gridColumnAlignment(.trailing)
                    Text("Worst").gridColumnAlignment(.trailing)
                    Text("Narrow").gridColumnAlignment(.trailing)
                    Text("Changes")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(planner.plans) { row in
                    GridRow {
                        Button(row.label) { planner.selected = row.id }
                            .buttonStyle(.borderless)
                            .fontWeight(planner.selected == row.id ? .bold : .regular)
                            .accessibilityLabel("Show plan \(row.label)")
                        Text(row.plan.cost, format: .number.precision(.fractionLength(0)))
                        Text(row.plan.meets ? "yes" : "no")
                        Text(row.plan.expectedFailing, format: .number.precision(.fractionLength(2)))
                        Text(row.plan.worst, format: .percent.precision(.fractionLength(0)))
                        Text("\(row.narrow)")
                        Text(row.changes).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }
            Text(
                String(
                    format:
                        "Narrow: sides passing within a third of the %.0f%% accepted, the ones to confirm with a run. Illustrative: your costs and charges, the quick estimate's loads, the glass's chances a run's spread, not the event's. Confirm a plan on a run's façade histories with scenebench protect --confirm. The view colours each side by the shown plan's residual chance.",
                    target * 100)
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let selected = planner.selected, planner.plans.indices.contains(selected), selected > 0 {
                Button("Apply Plan \(planner.plans[selected].label)") {
                    if let plan = planner.model.map({ (planner.plans[selected].plan, $0) }) {
                        model.applyProtectionPlan(plan.0, model: plan.1, label: planner.plans[selected].label)
                    }
                }
                .help("Write the plan's glazing into the project's envelope constructions, side by side.")
            }
        }
    }
}
