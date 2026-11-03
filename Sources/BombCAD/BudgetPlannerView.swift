import BlastCore
import SwiftUI

/// Best for a Budget… (emmettl/bombcad-work#117, stage 2): the budget, what to make fewest, the changes
/// allowed and their illustrative costs; the search seen as it goes, its walls drawn in the view; then
/// its best plans judged again by the full estimate, the best by it put in the scene.
struct BudgetPlannerView: View {
    let model: SimulationModel
    @State var planner: BudgetPlannerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var planner = planner
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Best for a budget").font(.title2)
                    Spacer()
                    Button("Done") {
                        planner.cancel()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                Text(
                    "Barrier walls, film or laminated glass building by building, and a stand-off, chosen so that the fewest people are hurt for what you will spend. The search asks the learned response, as a drag does, so it answers in seconds; its best few plans are then judged again by the full estimate, as when a drag is let go, and the best by that is put in the scene. A what-if: the project is not changed."
                )
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                form(planner)
                HStack {
                    if planner.isRunning {
                        Button("Stop") { planner.cancel() }
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Find the Best") { planner.find(in: model) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.settings.scenario.envelopeObjects.isEmpty)
                        if planner.result != nil {
                            Button("Take It Away") { planner.reset(in: model) }
                                .help("Back to the scene as built, the charge where it was")
                        }
                    }
                }
                if planner.phase == .searching, let p = planner.progress {
                    ProgressView(
                        value: Double(min(p.evaluations, planner.looks)), total: Double(planner.looks))
                }
                if !planner.progressText.isEmpty {
                    Text(planner.progressText).font(.callout).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                if let error = planner.error {
                    Text(error).foregroundStyle(.red).font(.callout).fixedSize(
                        horizontal: false, vertical: true)
                }
                if let refereed = planner.refereed { finalists(planner, refereed) }
                Text(
                    "Illustrative. The loads and the glass are the quick estimate's, the people \(model.occupancy.glass.label), the costs an order of magnitude from open price guides. The learned response reads a wall put up much as the full estimate does; a charge moved, less well, which is why the stand-off's plans are judged again."
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .frame(width: 600, alignment: .leading).frame(minHeight: 520, alignment: .top)
    }

    private func form(_ planner: BudgetPlannerModel) -> some View {
        @Bindable var planner = planner
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Budget") {
                TextField(
                    "Budget", value: $planner.budget,
                    format: .currency(code: "USD").precision(.fractionLength(0))
                )
                .frame(width: 140)
            }
            Picker("Make fewest", selection: $planner.objective) {
                ForEach(ProtectionBudget.Objective.allCases) { Text($0.label).tag($0) }
            }
            if planner.objective == .peopleHurt {
                Toggle(
                    "Count the glass thrown into rooms (Bowen)",
                    isOn: Binding(
                        get: { model.occupancy.glass == .thrownGlass },
                        set: { model.occupancy.glass = $0 ? .thrownGlass : .panesBroken })
                )
                .help(
                    "Off, Kummer's estimate by the panes broken, the default: film and laminated glass hold the glass but do not stop it breaking, so they rarely count, and any money left goes on the glass thrown. On, the people hurt by the glass thrown into their rooms, which film holds."
                )
            }
            Toggle("Barrier walls (up to two, 2–4 m tall)", isOn: $planner.walls)
            Toggle("Security film, building by building", isOn: $planner.film)
            Toggle("Laminated glass, building by building", isOn: $planner.laminated)
            if planner.standOff != nil {
                Toggle(
                    "A stand-off, bollards keeping the charge back " + planner.standOffPhrase,
                    isOn: $planner.usesStandOff)
            }
            DisclosureGroup("Costs (illustrative, in dollars)") {
                VStack(alignment: .leading, spacing: 6) {
                    cost("Film, per m² of glass", $planner.costs.filmPerM2)
                    cost("Laminated glass, per m² of glass", $planner.costs.laminatedPerM2)
                    cost("Barrier wall, per m² of its face", $planner.costs.barrierPerM2)
                    cost("Bollards, per m of line", $planner.costs.bollardsPerM)
                    Button("Back to the Illustrative Costs") { planner.costs = .illustrative }.controlSize(
                        .small)
                    ForEach(ProtectionBudget.Costs.sources, id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary).fixedSize(
                            horizontal: false, vertical: true)
                    }
                }
            }
        }
        .disabled(planner.isRunning)
    }

    private func cost(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number.precision(.fractionLength(0))).frame(width: 100)
        }
    }

    private func finalists(_ planner: BudgetPlannerModel, _ refereed: ProtectionBudget.Refereed) -> some View
    {
        let base = planner.value(refereed.asBuilt)
        return VStack(alignment: .leading, spacing: 8) {
            Text("The best plans, by the full estimate").font(.headline)
            Text("As built: " + planner.figure(refereed.asBuilt) + ".").font(.callout)
            ForEach(refereed.finalists.indices, id: \.self) { n in
                let (finalist, judged) = refereed.finalists[n]
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            (n == 0 ? "Best: " : "") + finalist.plan.label.prefix(1).uppercased()
                                + finalist.plan.label.dropFirst() + "."
                        )
                        .fontWeight(n == 0 ? .semibold : .regular)
                        .fixedSize(horizontal: false, vertical: true)
                        Text(
                            BudgetPlannerModel.dollars(finalist.plan.cost.total) + ". Full estimate: "
                                + planner.figure(judged) + " ("
                                + BudgetPlannerModel.change(planner.value(judged), against: base)
                                + "). Learned response: "
                                + BudgetPlannerModel.change(
                                    planner.value(finalist.outcome),
                                    against: planner.value(planner.result?.asBuilt ?? .empty))
                                + ". Found as " + finalist.why + "."
                        )
                        .font(.caption).foregroundStyle(.secondary).fixedSize(
                            horizontal: false, vertical: true)
                    }
                    Spacer()
                    if planner.shown == n {
                        Text("Shown").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Show") { planner.show(finalist, at: n, in: model) }.controlSize(.small)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !refereed.keepsTheSearchsBest, let lead = planner.result?.finalists.first {
                Text(
                    "The learned response's own best (" + lead.plan.label
                        + ") is not the full estimate's: where a plan moves the charge, the learned response's preview reads the change less well."
                )
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
