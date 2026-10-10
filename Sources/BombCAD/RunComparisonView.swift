import BlastCore
import Charts
import SwiftUI

struct RunComparisonView: View {
    @Bindable var model: SimulationModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<UUID> = []
    @State private var baselineID: UUID?
    @State private var gaugeKey: SavedSimulationRun.Gauge.Key?
    @State private var plotsStructure = false
    @State private var arrivalThreshold = 0.1
    @State private var currentInputHash: String?
    @State private var removed: [SavedSimulationRun] = []
    @State private var export: ResultsDocument?
    @State private var exportError: String?

    private var runs: [SavedSimulationRun] { model.savedRuns.filter { selectedIDs.contains($0.id) } }
    private var baseline: SavedSimulationRun? { runs.first { $0.id == baselineID } ?? runs.first }
    private var duration: Double { max(0.001, runs.map(\.elapsedTime).max() ?? 0.001) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compare saved runs").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(
                "Select up to four runs. Differences use the reference run; gauge matches require the same name and position."
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading) {
                    Text("Saved runs (\(model.savedRuns.count)/\(SavedSimulationRun.maximumRuns))").font(
                        .headline)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(model.savedRuns) { run in
                                SavedRunRow(
                                    run: run, selected: selection(run), editable: !model.sweep.isActive,
                                    differs: run.inputSHA256 != currentInputHash,
                                    rename: { try model.renameRun(id: run.id, name: $0) },
                                    remove: {
                                        removed.append(run)
                                        model.removeRun(id: run.id)
                                        reconcile()
                                    },
                                    export: { export = ResultsDocument(text: run.csv()) },
                                    useInputs: {
                                        do {
                                            try model.useRunInputs(id: run.id)
                                            dismiss()
                                        } catch { exportError = error.localizedDescription }
                                    })
                            }
                        }
                    }
                    if !removed.isEmpty {
                        Button("Undo last removal") {
                            if let run = removed.last {
                                model.restoreRun(run)
                                if model.savedRuns.contains(where: { $0.id == run.id }) {
                                    removed.removeLast()
                                }
                                reconcile()
                            }
                        }.disabled(
                            model.sweep.isActive || model.savedRuns.count >= SavedSimulationRun.maximumRuns)
                    }
                    Text(
                        "Keeping, renaming and removing runs are saved with the project. Chart selections are temporary."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }.frame(width: 245)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    if runs.isEmpty {
                        ContentUnavailableView(
                            "Select saved runs", systemImage: "chart.xyaxis.line",
                            description: Text("Complete a simulation, then use Keep Run beside the chart."))
                    } else {
                        controls
                        comparisonChart.frame(minHeight: 240)
                        ScrollView {
                            readouts
                            if !plotsStructure { gridSummary }
                        }.frame(maxHeight: 200)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20).frame(minWidth: 920, minHeight: 640)
        .onAppear {
            selectedIDs = Set(model.savedRuns.prefix(2).map(\.id))
            let inputs = model.sweep.baseline ?? model.currentInputs
            currentInputHash = try? SavedSimulationRun.fingerprint(inputs.scenario, settings: inputs.settings)
            reconcile()
        }
        .onChange(of: baselineID) { gaugeKey = baseline?.gauges.first?.key }
        .fileExporter(
            isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
            document: export, contentType: .commaSeparatedText, defaultFilename: "BombCAD saved run"
        ) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert(
            "Run action failed",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } })
        ) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading) {
            Picker("Reference", selection: $baselineID) {
                ForEach(runs) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("Plot", selection: $plotsStructure) {
                Text("Pressure").tag(false)
                Text("Deflection").tag(true)
            }.pickerStyle(.segmented)
            if !plotsStructure {
                Picker("Gauge", selection: $gaugeKey) {
                    ForEach(baseline?.gauges ?? []) { gauge in
                        let p = gauge.key.position
                        Text(
                            "\(gauge.key.name) (\(p.x, format: .number), \(p.y, format: .number), \(p.z, format: .number) m)"
                        )
                        .tag(Optional(gauge.key))
                    }
                }
            }
            if !plotsStructure {
                HStack {
                    Text("Arrival threshold (kPa)")
                    TextField("Threshold", value: $arrivalThreshold, format: .number)
                        .frame(width: 80)
                }.font(.caption)
                Text(
                    "Impulse uses the full recorded window. Phase duration runs from threshold arrival to the first zero crossing."
                )
                .font(.caption).foregroundStyle(.secondary)
                if !arrivalThreshold.isFinite || arrivalThreshold <= 0 {
                    Text("Enter a finite threshold greater than zero.").font(.caption).foregroundStyle(
                        .orange)
                }
            }
            if Set(runs.map(\.solverVersion)).count > 1 {
                Label("These runs use different solver versions.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            standingWarnings
        }
    }

    /// Differences in what the selected runs' results rest on, beside those in their numbers.
    @ViewBuilder private var standingWarnings: some View {
        let differences = baseline.map { runs.standingDifferences(from: $0) } ?? []
        if !differences.isEmpty {
            Label(
                "These runs differ in standing, not only in their numbers:",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption).foregroundStyle(.orange)
            .help("Their results rest on different evidence. Click a run's badge below for each one's.")
            ForEach(differences, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        }
        if runs.count > 1, runs.contains(where: { $0.standing == nil }) {
            Text("Standing not recorded for runs kept before it was, so differences in it cannot be shown.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var comparisonChart: some View {
        Chart {
            ForEach(runs) { run in
                let points = plotsStructure ? run.structure?.points ?? [] : measurement(run)?.points ?? []
                ForEach(Array(SavedSimulationRun.plotPoints(points).enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Time", point.time * 1000), y: .value("Response", point.value),
                        series: .value("Run", run.name)
                    )
                    .foregroundStyle(by: .value("Run", run.name))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
        }
        .chartXScale(domain: 0...(duration * 1000))
        .chartXAxisLabel("Time since detonation (ms)")
        .chartYAxisLabel(plotsStructure ? "Largest intact deflection (mm)" : "Overpressure (kPa)")
    }

    private var readouts: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(runs) { run in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(run.name + (run.id == baseline?.id ? " · Reference" : "")).font(.headline)
                        StandingBadge(
                            standing: run.standing,
                            kinds: plotsStructure
                                ? [.structuralResponse, .structuralDamage] : [.peakOverpressure, .impulse],
                            unrecorded: true)
                    }
                    Text(
                        "\(run.settings.resolution.capitalized) grid · Afterburning \(run.settings.detailedCharge ? "on" : "off") · Shock refinement \(run.settings.sharpShocks ? ((run.settings.shockLevels ?? 1) > 1 ? "in two levels" : "on") : "off")"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Run inputs") {
                        Text(
                            "Charge: \(run.scenario.charge.mass, format: .number) kg TNT · \(run.settings.duration * 1000, format: .number) ms target"
                        )
                        if let body = run.scenario.structure {
                            Text("Materials: " + body.materials.map(\.name).joined(separator: ", "))
                            Text(
                                "\(body.solids.count) structural regions · \(body.openings.count) openings · \(body.supports.count) support regions · \(body.reinforcement.count) reinforcement layers"
                            )
                            Text(
                                "Base: "
                                    + (body.fixedBase ? connectionTitle(body.baseAnchorage) : "Unrestrained"))
                            ForEach(body.supports.indices, id: \.self) { index in
                                Text(
                                    "Support \(index + 1): "
                                        + connectionTitle(body.anchorage(ofSupport: index)))
                            }
                        }
                        if let fragments = run.fragments { Text(fragments.summary) }
                        if let groundShock = run.groundShock { Text(groundShock.summary) }
                        ForEach(run.envelopeExposure ?? []) { building in
                            Text(
                                String(
                                    format:
                                        "%@: %.2f kPa peak surface pressure · %.2f Pa s mean positive impulse",
                                    building.name, building.peakPositivePa / 1000,
                                    building.meanPositiveImpulsePaS ?? 0))
                        }
                        Text(run.deviceName + " · " + run.operatingSystem)
                    }.font(.caption)
                    if let thermal = run.thermal { Text(thermal.comparison).font(.callout) }
                    if let cloud = run.cloud { Text(cloud.comparison).font(.callout) }
                    if plotsStructure {
                        if let response = run.structure {
                            metric("Peak recorded deflection", response.peak, baseline?.structure?.peak, "mm")
                            HStack {
                                Text(
                                    "Elements failed: \(response.failedFraction * 100, format: .number.precision(.fractionLength(1)))%"
                                )
                                if let reference = baseline?.structure {
                                    Text(
                                        String(
                                            format: "Δ %+.1f pp",
                                            (response.failedFraction - reference.failedFraction) * 100)
                                    )
                                    .foregroundStyle(.secondary).help("Difference in percentage points")
                                }
                            }.font(.callout)
                            Text(
                                "Maximum damage: \(min(response.maximumDamage, 1) * 100, format: .number.precision(.fractionLength(1)))%"
                            )
                            .font(.callout)
                        } else {
                            Text("No structural response in this run.").foregroundStyle(.secondary)
                        }
                    } else if let gauge = measurement(run) {
                        metric(
                            "Peak positive overpressure", gauge.peak,
                            baseline.flatMap { measurement($0)?.peak }, "kPa")
                        let values = PressureMeasurements(points: gauge.points, threshold: arrivalThreshold)
                        let reference = baseline.flatMap { measurement($0) }.map {
                            PressureMeasurements(points: $0.points, threshold: arrivalThreshold)
                        }
                        metric(
                            "Positive impulse (recorded window)", values.positiveImpulse,
                            reference?.positiveImpulse, "Pa·s")
                        metric(
                            "Signed impulse (recorded window)", values.signedImpulse,
                            reference?.signedImpulse, "Pa·s")
                        if let arrival = values.arrival {
                            metric("Arrival", arrival * 1000, reference?.arrival.map { $0 * 1000 }, "ms")
                        } else {
                            Text(
                                !arrivalThreshold.isFinite || arrivalThreshold <= 0
                                    ? "Arrival requires a valid threshold."
                                    : values.startsAboveThreshold
                                        ? "Arrival unresolved: recording starts above threshold."
                                        : "Arrival threshold not reached."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        if let phase = values.positivePhaseDuration {
                            metric(
                                "Positive-phase duration", phase * 1000,
                                reference?.positivePhaseDuration.map { $0 * 1000 }, "ms")
                        } else if values.phaseIsIncomplete {
                            Text("Positive phase incomplete in the recorded window.").font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No matching gauge in this run; its pressure trace is omitted.")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gridSummary: some View {
        let study = GridMeasurementStudy(runs: runs)
        return DisclosureGroup("Grid sensitivity") {
            if study.isComparable {
                Text(
                    "Successive coarse-to-fine changes; these measure sensitivity and do not establish convergence."
                )
                .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(zip(study.runs, study.runs.dropFirst()).enumerated()), id: \.offset) {
                    _, pair in
                    if let coarse = measurement(pair.0), let fine = measurement(pair.1) {
                        let a = PressureMeasurements(points: coarse.points, threshold: arrivalThreshold)
                        let b = PressureMeasurements(points: fine.points, threshold: arrivalThreshold)
                        Text(
                            "\(pair.0.settings.resolution.capitalized) → \(pair.1.settings.resolution.capitalized)"
                        ).font(.headline)
                        metric("Peak", fine.peak, coarse.peak, "kPa")
                        metric("Positive impulse", b.positiveImpulse, a.positiveImpulse, "Pa·s")
                        if let arrival = b.arrival {
                            metric("Arrival", arrival * 1000, a.arrival.map { $0 * 1000 }, "ms")
                        }
                        if let phase = b.positivePhaseDuration {
                            metric(
                                "Phase duration", phase * 1000, a.positivePhaseDuration.map { $0 * 1000 },
                                "ms")
                        }
                    } else {
                        Text("A matching gauge is required in each run.").font(.caption)
                    }
                }
            } else {
                Text(
                    "Select distinct grid resolutions with identical physical inputs, target duration and solver version. Runs with resampled imported geometry require a separate geometry-sensitivity study."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.top, 8)
    }

    private func connectionTitle(_ law: Anchorage?) -> String {
        if law == nil { return "Clamped" }
        return BaseConnection.allCases.first { $0.anchorage == law }?.title ?? "Custom connection"
    }

    private func metric(_ title: String, _ value: Double, _ reference: Double?, _ unit: String) -> some View {
        HStack {
            Text("\(title): \(value, format: .number.precision(.fractionLength(2))) \(unit)")
            if let reference {
                Text(String(format: "Δ %+.2f %@", value - reference, unit)).foregroundStyle(.secondary)
            }
        }.font(.callout).monospacedDigit()
    }

    private func measurement(_ run: SavedSimulationRun) -> SavedSimulationRun.Gauge? {
        run.gauges.first { $0.key == gaugeKey }
    }
    private func selection(_ run: SavedSimulationRun) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(run.id) },
            set: { selected in
                if selected && selectedIDs.count < 4 { selectedIDs.insert(run.id) }
                if !selected { selectedIDs.remove(run.id) }
                reconcile()
            })
    }
    private func reconcile() {
        selectedIDs.formIntersection(Set(model.savedRuns.map(\.id)))
        if !runs.contains(where: { $0.id == baselineID }) { baselineID = runs.first?.id }
        if !(baseline?.gauges.contains { $0.key == gaugeKey } ?? false) {
            gaugeKey = baseline?.gauges.first?.key
        }
    }
}

private struct SavedRunRow: View {
    let run: SavedSimulationRun
    @Binding var selected: Bool
    let editable: Bool
    let differs: Bool
    let rename: (String) throws -> Void
    let remove: () -> Void
    let export: () -> Void
    let useInputs: () -> Void
    @State private var draft = ""
    @State private var renameError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(run.name, isOn: $selected).toggleStyle(.checkbox)
            TextField("Name", text: $draft).textFieldStyle(.roundedBorder).disabled(!editable)
                .onSubmit {
                    do {
                        try rename(draft)
                        draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        renameError = nil
                    } catch {
                        renameError = error.localizedDescription
                    }
                }
                .help("Press Return to rename this run; names must be unique and at most 120 characters.")
            if let renameError {
                Text(renameError).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(run.capturedAt, format: .dateTime.month().day().hour().minute()).font(.caption)
            Text(
                "\(run.scenario.name) · \(run.elapsedTime * 1000, format: .number.precision(.fractionLength(1))) ms"
            )
            .font(.caption)
            Text("\(run.solverVersion) · \(run.appVersion)").font(.caption2).foregroundStyle(.secondary)
            if differs { Text("Inputs differ from the editor.").font(.caption).foregroundStyle(.secondary) }
            Button("Use this run’s inputs", action: useInputs).disabled(!editable)
            HStack {
                Button("Export CSV…", action: export)
                Button("Remove", role: .destructive, action: remove).disabled(!editable)
            }.controlSize(.small)
        }
        .onAppear { draft = run.name }
        .onChange(of: run.name) {
            draft = run.name
            renameError = nil
        }
        .onChange(of: draft) { renameError = nil }
    }
}
