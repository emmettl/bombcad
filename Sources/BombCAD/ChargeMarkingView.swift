#if os(macOS)
    import BlastCore
    import SwiftUI
    import UniformTypeIdentifiers

    /// Simulation ▸ Read the Charge from the Damage…: a panel beside the view (emmettl/bombcad-work#116,
    /// stage 2). A click on a building marks it with the brush chosen here; the chance of where the
    /// charge was is painted on the ground, its likeliest half and nine tenths outlined, and its yield
    /// drawn below, all following each mark (`ChargeMarkingModel`).
    struct ChargeMarkingView: View {
        let model: SimulationModel
        @Bindable var marking: ChargeMarkingModel
        @State private var importing = false

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Charge from the Damage").font(.headline)
                    Spacer()
                    Button("Close", systemImage: "xmark") { model.showsChargeMarking = false }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .accessibilityLabel("Close the Charge from the Damage panel")
                        .help("Close the panel; the marks are kept while the window is open")
                }
                .padding(12)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let error = marking.error {
                            Text(error).foregroundStyle(.red)
                        }
                        Text(
                            "Click a building in the view to mark what was seen of it. Where the charge was, and how big, is read back from the marks as each is made."
                        )
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Picker("Mark a building as", selection: $marking.brush) {
                            ForEach(ChargeMarkingModel.Brush.allCases) { brush in
                                Text(brush.title).tag(brush).help(brush.help)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .help("A click on a building gives it this mark; the same again takes it away")
                        if marking.isWorking {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Weighing the marks…").font(.callout)
                            }
                        }
                        Text(countsText).font(.callout).foregroundStyle(.secondary)
                        if let posterior = marking.posterior {
                            Text(marking.words).fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("Result: \(marking.words)")
                            YieldChart(posterior: posterior)
                            ChanceKey()
                        }
                        if let warning = oversure {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        actions
                        survey
                        weighingChoice
                        if marking.hasMarks {
                            Text(
                                String(
                                    format: "The last change was weighed in %.1f ms and laid out in %.1f ms.",
                                    1000 * marking.weighSeconds, 1000 * marking.drawSeconds)
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(
                            "It reads charges of 100 kg to 3.3 kt within 500 m of where it searches, from each building's distance and its own make alone: it knows nothing of which buildings shield which. "
                                + ChargeFromDamage.standing
                        )
                        .font(.caption).foregroundStyle(.secondary).fixedSize(
                            horizontal: false, vertical: true)
                    }
                    .padding(12)
                }
            }
            .task(id: model.sceneVersion) { await marking.open(model) }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [
                    .commaSeparatedText, .folder, UTType(filenameExtension: "shp") ?? .data,
                    UTType(filenameExtension: "dbf") ?? .data,
                ]
            ) { picked in
                guard case .success(let url) = picked else { return }
                Task {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    await marking.loadSurvey(url, model)
                }
            }
        }

        /// Said when the marks' answer is likely surer than it should be: weighed as independent
        /// (stage 2's) past a few dozen marks, or, however weighed, past a hundred, where on the
        /// districts held out the regions held the truth less often than they say
        /// (docs/charge-inference.md, "Marks that err together").
        private var oversure: String? {
            guard let m = marking.marking else { return nil }
            if m.weighing.isIndependent, m.marks.count > 20 {
                return
                    "The marks are weighed as independent: with \(m.marks.count) of them the regions and the yield's range are likely far narrower than they should be."
            }
            guard m.marks.count > ChargeMarkingModel.manyMarks else { return nil }
            return
                "With \(m.marks.count) marks the answer is likely surer than it should be: it rests on the quick estimate's own errors, which so many marks share. Tested with every building marked, the nine-in-ten region held the true place 70% of the time on a made-up district and 28% on Beirut."
        }

        @ViewBuilder private var survey: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("A survey").font(.caption.weight(.semibold))
                Button("Load a Survey…") { importing = true }
                    .disabled(marking.marking == nil || marking.isWorking)
                    .help(
                        "Mark the buildings a survey saw, in place of these marks: a marks CSV, GEER's façade shapefile or structural .dbf, a CSV of lat,lon,class, or a folder of them"
                    )
                if let location = model.sceneLocation {
                    Text(
                        "New District kept this scene's place on the map (corner \(location.scene.latitude.formatted(.number.precision(.fractionLength(5)))), \(location.scene.longitude.formatted(.number.precision(.fractionLength(5))))), so a survey's longitudes and latitudes land on its buildings."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack {
                        Text("Corner").font(.caption)
                        TextField("Longitude", text: $marking.cornerLongitude).frame(width: 90)
                            .accessibilityLabel("Scene corner longitude")
                        TextField("Latitude", text: $marking.cornerLatitude).frame(width: 90)
                            .accessibilityLabel("Scene corner latitude")
                    }
                    .help(
                        "The longitude and latitude of the scene's corner (0, 0), as a map import places it, to put a survey's places on the scene"
                    )
                    if marking.corner == nil {
                        Text(
                            "This project doesn't record where its scene lies on the map (it was made before New District kept that, or not from a map), so a survey in longitudes and latitudes can't be placed until you give the corner above. A marks CSV in the scene's metres needs none."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !marking.surveyReport.isEmpty {
                    Text(marking.surveyReport).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if marking.farBuildings > 0 {
                    Text(
                        "The far field's \(marking.farBuildings.formatted(.number)) buildings can be marked too."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        private var weighingChoice: some View {
            Picker(
                "Weigh the marks",
                selection: Binding(
                    get: { marking.weighing.isIndependent },
                    set: { independent in
                        Task {
                            await marking.weigh(
                                as: independent ? .independent : .adopted, model)
                        }
                    })
            ) {
                Text("As erring together").tag(false)
                Text("As independent (stage 2)").tag(true)
            }
            .help(
                "Neighbouring buildings judged by the same estimate, or seen by the same survey, err together; weighed as independent, many marks make the answer far too sure"
            )
            .disabled(marking.isWorking)
        }

        private var countsText: String {
            let c = marking.counts
            guard c.buildings > 0 else { return "No building marked yet." }
            var parts: [String] = []
            if c.glassBroken > 0 { parts.append("\(c.glassBroken) glass broken") }
            if c.glassWhole > 0 { parts.append("\(c.glassWhole) glass whole") }
            if c.undamaged > 0 { parts.append("\(c.undamaged) walls undamaged") }
            if c.damaged > 0 { parts.append("\(c.damaged) walls damaged") }
            if c.heavy > 0 { parts.append("\(c.heavy) walls heavily damaged") }
            return "\(c.buildings) building\(c.buildings == 1 ? "" : "s") marked: "
                + parts.joined(separator: ", ") + "."
        }

        @ViewBuilder private var actions: some View {
            VStack(alignment: .leading, spacing: 6) {
                Button("Mark from the Damage Shown") { Task { await marking.markFromDamage(model) } }
                    .disabled(model.envelopeDamage.isEmpty || marking.isWorking || marking.marking == nil)
                    .help(
                        model.envelopeDamage.isEmpty
                            ? "Make a quick estimate of the envelopes' damage, or run the scene, to mark from"
                            : "Mark every building the \(model.envelopeDamageIsEstimate ? "quick estimate" : "run") judged, as its damage would be marked, in place of these marks"
                    )
                Button("Move the Charge There") { marking.moveChargeThere(model) }
                    .disabled(marking.posterior == nil || marking.isWorking)
                    .help("Move the scene's charge to the likeliest place, at the yield's median")
                if marking.aboutCharge {
                    Button("Search About the Likeliest Place") {
                        Task { await marking.centre(onCharge: false, model) }
                    }
                    .disabled(marking.posterior == nil || marking.isWorking)
                    .help("Search within 500 m of the likeliest place instead of the scene's charge")
                } else {
                    Button("Search About the Charge") { Task { await marking.centre(onCharge: true, model) } }
                        .disabled(marking.isWorking)
                        .help("Search within 500 m of the scene's charge again")
                }
                Button("Clear All Marks") { marking.clearAll(model) }
                    .disabled(!marking.hasMarks || marking.isWorking)
            }
        }
    }

    /// The yield's chance, bin by bin on a logarithmic axis, its nine tenths shaded and its median
    /// marked.
    private struct YieldChart: View {
        let posterior: ChargeFromDamage.Posterior

        var body: some View {
            let low = posterior.yieldQuantile(0.05)
            let median = posterior.yieldQuantile(0.5)
            let high = posterior.yieldQuantile(0.95)
            VStack(alignment: .leading, spacing: 4) {
                Text("Yield, TNT").font(.caption.weight(.semibold))
                Canvas { context, size in
                    let logs = posterior.logYields
                    guard let first = logs.first, let last = logs.last, logs.count > 1 else { return }
                    let step = logs[1] - logs[0]
                    let left = first - 0.5 * step
                    let span = last + 0.5 * step - left
                    func x(_ log: Double) -> CGFloat { CGFloat((log - left) / span) * size.width }
                    let most = posterior.yieldProbabilities.max() ?? 1
                    let plot = size.height - 14
                    context.fill(
                        Path(
                            CGRect(
                                x: x(Foundation.log(low)), y: 0,
                                width: x(Foundation.log(high)) - x(Foundation.log(low)), height: plot)),
                        with: .color(.accentColor.opacity(0.12)))
                    for (k, p) in posterior.yieldProbabilities.enumerated() {
                        let h = most > 0 ? CGFloat(p / most) * plot : 0
                        context.fill(
                            Path(
                                CGRect(
                                    x: x(logs[k] - 0.5 * step) + 0.5, y: plot - h,
                                    width: x(logs[k] + 0.5 * step) - x(logs[k] - 0.5 * step) - 1, height: h)),
                            with: .color(.accentColor))
                    }
                    var tick = Path()
                    tick.move(to: CGPoint(x: x(Foundation.log(median)), y: 0))
                    tick.addLine(to: CGPoint(x: x(Foundation.log(median)), y: plot))
                    context.stroke(tick, with: .color(.primary), lineWidth: 1.5)
                    for (kg, label) in [
                        (100.0, "100 kg"), (1e3, "1 t"), (1e4, "10 t"), (1e5, "100 t"), (1e6, "1 kt"),
                    ] {
                        let at = x(Foundation.log(kg))
                        guard at >= 0, at <= size.width else { continue }
                        context.draw(
                            Text(label).font(.caption2).foregroundStyle(.secondary),
                            at: CGPoint(x: min(max(at, 18), size.width - 14), y: size.height - 6))
                    }
                }
                .frame(height: 74)
                .accessibilityElement()
                .accessibilityLabel("Yield chart")
                .accessibilityValue(
                    "Median \(ChargeFromDamage.Posterior.mass(median)); nine in ten between \(ChargeFromDamage.Posterior.mass(low)) and \(ChargeFromDamage.Posterior.mass(high))"
                )
            }
        }
    }

    /// What the view draws: the chance on the ground's colours, and the outlines.
    private struct ChanceKey: View {
        // Matches `glow` in Render.metal, as the thermal radiation's key does.
        private static let stops: [Color] = [
            Color(red: 0.30, green: 0.04, blue: 0.07), Color(red: 0.62, green: 0.08, blue: 0.06),
            Color(red: 0.91, green: 0.32, blue: 0.07), Color(red: 0.99, green: 0.67, blue: 0.17),
            Color(red: 1.00, green: 0.96, blue: 0.78),
        ]

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("The charge's place, against the likeliest").font(.caption.weight(.semibold))
                LinearGradient(colors: Self.stops, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 10).clipShape(.rect(cornerRadius: 3))
                HStack {
                    Text("1%")
                    Spacer()
                    Text("10%")
                    Spacer()
                    Text("100%")
                }
                .font(.caption2.monospacedDigit())
                Text(
                    "A thick white line holds the likeliest half of the chance, a thin one nine tenths. Marked buildings are outlined over their roofs: glass broken crimson, whole cyan; walls undamaged blue, damaged amber, heavily damaged dark red."
                )
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Colour key: the charge's place")
            .accessibilityValue(
                "On the ground, from dark red at one hundredth of the likeliest place's chance to pale yellow at the likeliest. A thick white line holds the likeliest half of the chance, a thin one nine tenths. Marked buildings are outlined: glass broken crimson, whole cyan; walls undamaged blue, damaged amber, heavily damaged dark red."
            )
        }
    }
#endif
