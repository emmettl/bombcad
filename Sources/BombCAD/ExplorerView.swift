#if os(macOS)
    import AppKit
    import BlastCore
    import SwiftUI

    /// The explorer's window (emmettl/bombcad-work#114; docs/explorer.md): the scenes, then the view with
    /// the explorer's sidebar beside it, the wave's captions over it and its bar beneath. View ▸ Workbench
    /// opens the full app in the same window.
    struct ExplorerWindow: View {
        @Bindable var explorer: ExplorerModel
        var showWorkbench: () -> Void
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            HStack(spacing: 0) {
                ExplorerSidebar(explorer: explorer, showWorkbench: showWorkbench)
                    .frame(width: 340)
                Divider()
                VStack(spacing: 0) {
                    view
                    if explorer.scene != nil {
                        Divider()
                        ExplorerWaveBar(explorer: explorer)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Workbench", systemImage: "slider.horizontal.3", action: showWorkbench)
                        .help("Open the full app in this window: the Run and Edit sidebar (View ▸ Workbench)")
                }
            }
            // A charge dragged and let go: the wave plays again for where it now is.
            .onChange(of: explorer.model.isDraggingCharge) { _, dragging in
                if !dragging { Task { await explorer.replayWhenReady() } }
            }
            .onAppear { explorer.reduceMotion = reduceMotion }
            .onChange(of: reduceMotion) { _, reduce in explorer.reduceMotion = reduce }
            // The wave played to its end: its last caption said once.
            .onChange(of: explorer.model.liveWavePlaying) { was, playing in
                if was, !playing, explorer.model.liveWaveTime >= explorer.model.liveWaveEnd * 0.999,
                    let caption = explorer.caption
                {
                    AccessibilityNotification.Announcement(caption).post()
                }
            }
        }

        private var view: some View {
            MetalView(model: explorer.model)
                .accessibilityElement()
                .accessibilityLabel("3D view")
                .accessibilityValue(explorer.viewSummary)
                .accessibilityHint("Click to put the charge there, or drag it. Drag elsewhere to orbit.")
                .accessibilityAddTraits(.allowsDirectInteraction)
                .accessibilityAction(named: "Orbit left") { explorer.model.orbitCamera(.left) }
                .accessibilityAction(named: "Orbit right") { explorer.model.orbitCamera(.right) }
                .accessibilityAction(named: "Zoom in") { explorer.model.zoomCamera(in: true) }
                .accessibilityAction(named: "Zoom out") { explorer.model.zoomCamera(in: false) }
                .overlay(alignment: .top) {
                    if let caption = explorer.caption, explorer.scene != nil {
                        Text(caption)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 560)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.regularMaterial, in: .rect(cornerRadius: 10))
                            .padding(16)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if explorer.scene != nil { ExplorerLegend(explorer: explorer).padding(12) }
                }
                .overlay {
                    if explorer.scene == nil { ExplorerScenes(explorer: explorer) }
                }
        }
    }

    /// The scenes offered first, over the view.
    struct ExplorerScenes: View {
        let explorer: ExplorerModel

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("See what a blast does").font(.largeTitle.weight(.semibold))
                Text(ExplorerWords.intro).font(.title3).foregroundStyle(.secondary)
                ForEach(ExplorerScene.allCases) { scene in
                    Button {
                        Task { await explorer.open(scene) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(scene.title).font(.title2.weight(.semibold))
                            Text(scene.summary).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.background.secondary, in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(explorer.isOpening)
                    .accessibilityLabel("\(scene.title): \(scene.summary)")
                    .accessibilityHint("Opens the scene")
                }
                if explorer.beirutDownloadInFlight {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Downloading Beirut's port…")
                        Button("Cancel Download") { explorer.cancelBeirutDownload() }
                    }
                } else if !explorer.beirutStatus.isEmpty {
                    Text(explorer.beirutStatus).foregroundStyle(.red)
                }
                if explorer.isOpening {
                    ProgressView("Laying out the scene…").controlSize(.small)
                }
                if let problem = explorer.problem {
                    Text(problem).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 520)
            .padding(28)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .padding(24)
            .confirmationDialog(
                "Download Beirut's port?",
                isPresented: Binding(
                    get: { explorer.offersBeirutDownload },
                    set: { if !$0 { explorer.offersBeirutDownload = false } })
            ) {
                Button(explorer.beirutDownloadTitle) { explorer.downloadBeirut() }
                Button("Not Now", role: .cancel) { explorer.offersBeirutDownload = false }
            } message: {
                Text((ExplorerScene.beirut.opening.map { $0 + "\n\n" } ?? "") + explorer.beirutOffer)
            }
        }
    }

    /// Beside the view: the charge, the layers with their words, the comparisons and the safety rings.
    struct ExplorerSidebar: View {
        @Bindable var explorer: ExplorerModel
        var showWorkbench: () -> Void
        @State private var whyShown = false

        private var model: SimulationModel { explorer.model }

        var body: some View {
            Form {
                if let scene = explorer.scene {
                    sceneSection(scene)
                    chargeSection(scene)
                    layerSection
                    trySection
                    ringsSection
                } else {
                    Section("The explorer") {
                        Text(ExplorerWords.intro).fixedSize(horizontal: false, vertical: true)
                        Text("Choose a scene to begin.").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text(ExplorerWords.leftOut).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open the Workbench", action: showWorkbench)
                        .help(
                            "The full app, with every setting and the simulation that referees these estimates"
                        )
                }
            }
            .formStyle(.grouped)
        }

        private func sceneSection(_ scene: ExplorerScene) -> some View {
            Section(scene.title) {
                if let opening = scene.opening {
                    Text(opening).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                }
                Text(scene.summary).fixedSize(horizontal: false, vertical: true)
                if explorer.isRefining {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(ExplorerWords.refining).font(.caption)
                    }
                    .accessibilityElement(children: .combine)
                }
                Button("Choose Another Scene") { explorer.close() }
            }
        }

        private func chargeSection(_ scene: ExplorerScene) -> some View {
            Section("The charge") {
                Text(ExplorerWords.placePrompt).font(.callout).foregroundStyle(.secondary)
                HStack {
                    ForEach(ExplorerWords.steps, id: \.self) { kg in
                        let chosen = abs(model.settings.chargeMass - kg) < 0.5
                        Button(ExplorerWords.stepText(kg)) { explorer.setMass(kg) }
                            .buttonStyle(.bordered)
                            .tint(chosen ? .accentColor : nil)
                            .accessibilityLabel("Charge of \(ExplorerWords.massSpoken(kg))")
                            .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
                LabeledSlider(
                    title: "Charge",
                    value: Binding(
                        get: { log10(Double(model.settings.chargeMass)) },
                        set: { model.settings.chargeMass = SimulationSettings.roundedMass(pow(10, $0)) }),
                    range: log10(
                        Double(ExplorerWords.massRange.lowerBound))...log10(
                            Double(ExplorerWords.massRange.upperBound)),
                    text: ExplorerWords.massText(model.settings.chargeMass) + " of TNT",
                    onEditingChanged: { editing in
                        if editing { model.beginAdjustingEstimate() } else { model.endAdjustingEstimate() }
                    })
                VStack(alignment: .leading, spacing: 4) {
                    Text("Where it is")
                    Picker(
                        "Where it is",
                        selection: Binding(
                            get: { explorer.place?.name ?? "" },
                            set: { name in if let place = scene.place(name) { explorer.put(at: place) } })
                    ) {
                        if explorer.place == nil { Text("Where you put it").tag("") }
                        ForEach(scene.places) { place in Text(place.name).tag(place.name) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("Put the charge at a named place")
                }
                HStack {
                    Text("Move it 10 m")
                    Spacer()
                    Button("10 m west", systemImage: "arrow.left") { explorer.nudge(east: -10, north: 0) }
                    Button("10 m north", systemImage: "arrow.up") { explorer.nudge(east: 0, north: 10) }
                    Button("10 m south", systemImage: "arrow.down") { explorer.nudge(east: 0, north: -10) }
                    Button("10 m east", systemImage: "arrow.right") { explorer.nudge(east: 10, north: 0) }
                }
                .labelStyle(.iconOnly)
            }
        }

        private var layerSection: some View {
            Section("What to look at") {
                Picker("Layer", selection: $explorer.layer) {
                    ForEach(ExplorerWords.Layer.allCases) { layer in
                        Text(layer.rawValue.capitalized).tag(layer)
                    }
                }
                .pickerStyle(.segmented)
                Text(ExplorerWords.what(explorer.layer)).fixedSize(horizontal: false, vertical: true)
                if let finding = explorer.finding {
                    Text(finding).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                }
                if explorer.layer == .people, explorer.pinned == nil {
                    Text("Pin this picture, then change something, to see how much it helps.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(
                            horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("How sure?").font(.headline)
                    Text(
                        ExplorerWords.howSure(explorer.layer, refinedWave: model.liveWave?.refined ?? false)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                DisclosureGroup("Why?", isExpanded: $whyShown) {
                    ForEach(Array(standing.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        /// The layer's standing as the workbench gives it.
        private var standing: [String] {
            switch explorer.layer {
            case .wave: model.liveWave?.refined == true ? LiveWave.Refinement.standing : LiveWave.standing
            case .glass, .walls: FacadeLoadSurrogate.standing + LiveResponse.standing
            case .people: OccupantInjury.standing
            case .fire: FireSpread.standing
            }
        }

        /// The comparisons the scene offers: Beirut's has no place behind a building.
        private var tries: [ExplorerModel.Try] {
            ExplorerModel.Try.allCases.filter {
                $0 != .behindABuilding || explorer.scene?.behindABuilding != nil
            }
        }

        private var trySection: some View {
            Section("Try something") {
                ForEach(tries) { t in
                    Button {
                        explorer.run(t)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(.body.weight(.semibold))
                            Text(t.summary).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary, in: .rect(cornerRadius: 6))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.envelopeGlassChances.isEmpty)
                    .accessibilityLabel("\(t.title): \(t.summary)")
                }
                if let comparison = explorer.comparison {
                    Text(comparison).font(.callout.weight(.medium)).fixedSize(
                        horizontal: false, vertical: true)
                }
                if let reach = explorer.pinnedReach, explorer.layer == .glass || explorer.layer == .wave {
                    Text(
                        "The faint ring marks how far windows broke in the pinned picture (or, where they broke "
                            + "everywhere, were blown in): \(ExplorerWords.distanceText(reach)) from its charge."
                    )
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if explorer.pinned != nil {
                    Toggle("Colour by what changed", isOn: $explorer.showsChange)
                    if explorer.tried != nil {
                        Button("Put It Back") { explorer.putBack() }
                    }
                    Button("Unpin") { explorer.unpin() }
                } else {
                    Button("Pin This Picture") { explorer.pin() }
                        .disabled(model.envelopeGlassChances.isEmpty)
                        .help("Keep this picture, to compare the next with it")
                }
            }
        }

        private var ringsSection: some View {
            Section("Safety rings") {
                Toggle("Show the safety rings", isOn: $explorer.showsRings)
                Text(ExplorerWords.rings).font(.caption).fixedSize(horizontal: false, vertical: true)
                Text(ExplorerWords.ringsHowSure).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The layer's colours in words, over the view's corner.
    struct ExplorerLegend: View {
        let explorer: ExplorerModel

        var body: some View {
            let entries = self.entries
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    explorer.showsChange && explorer.pinned != nil
                        ? "Against the pinned picture" : explorer.layer.title
                )
                .font(.caption.weight(.semibold))
                ForEach(entries.indices, id: \.self) { n in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(entries[n].colour).frame(width: 14, height: 10)
                        Text(entries[n].label).font(.caption)
                    }
                }
            }
            .padding(10)
            .background(.regularMaterial, in: .rect(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "Colour key: " + entries.map(\.label).joined(separator: ", "))
        }

        private static func colour(_ c: SIMD3<Float>) -> Color {
            Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
        }

        private var entries: [(label: String, colour: Color)] {
            if explorer.showsChange, explorer.pinned != nil,
                explorer.layer == .glass || explorer.layer == .walls
            {
                let film = explorer.tried == .glassWithFilm && explorer.layer == .glass
                return [
                    (film ? "Less glass thrown in" : "Better", Self.colour(ExplorerColours.betterColour)),
                    ("About the same", Self.colour(ExplorerColours.sameColour)),
                    (film ? "More glass thrown in" : "Worse", Self.colour(ExplorerColours.worseColour)),
                ]
            }
            let labels = ExplorerWords.legend(explorer.layer)
            let ramp = EnvelopeChanceColour.ramp
            switch explorer.layer {
            case .wave:
                return [
                    (labels[0], Color(red: 0.67, green: 0.14, blue: 0.42)),
                    (labels[1], Color(red: 0.99, green: 0.98, blue: 0.70)),
                ]
            case .glass, .walls:
                return [
                    (labels[0], Self.colour(ramp[0])), (labels[1], Self.colour(ramp[4])),
                    (labels[2], Self.colour(ramp[7])),
                ]
            case .people:
                return [(labels[0], Self.colour(ramp[0])), (labels[1], Self.colour(ramp[7]))]
            case .fire:
                return [
                    ("No fire reaches it", Self.colour(EnvelopeChanceColour.neutralColour)),
                    (labels[0], Self.colour(ramp[0])), (labels[1], Self.colour(ramp[7])),
                ]
            }
        }
    }

    /// Under the view: the wave played again, scrubbed, and its time.
    struct ExplorerWaveBar: View {
        let explorer: ExplorerModel
        private var model: SimulationModel { explorer.model }

        var body: some View {
            HStack(spacing: 10) {
                Button(model.liveWavePlaying ? "Pause the Wave" : "Play the Wave Again") {
                    if model.liveWavePlaying {
                        model.pauseLiveWave()
                    } else {
                        explorer.replay()
                    }
                }
                .disabled(model.liveWave == nil)
                Slider(
                    value: Binding(get: { model.liveWaveTime }, set: { model.scrubLiveWave(to: $0) }),
                    in: 0...max(model.liveWaveEnd, 1e-3)
                ) { Text("Time after the charge goes off") }
                .labelsHidden()
                .accessibilityValue(ExplorerWords.timeText(model.liveWaveTime))
                .disabled(model.liveWave == nil)
                Text(ExplorerWords.timeText(model.liveWaveTime))
                    .font(.caption.monospacedDigit()).frame(minWidth: 120, alignment: .trailing)
                if model.liveWaveLearnedDownloadInFlight {
                    ProgressView().controlSize(.small)
                } else if model.liveWaveLearnedWeightsMissing,
                    model.liveWaveLearnedWeightsURL == model.liveWaveLearnedHome
                {
                    Button("Sharpen the Wave…") { model.offerLiveWaveLearnedDownload() }
                        .help(LiveWave.Refinement.Release.offer)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .confirmationDialog(
                "Download the live wave's learned refinement?",
                isPresented: Binding(
                    get: { model.offersLiveWaveLearnedDownload },
                    set: {
                        if !$0, model.offersLiveWaveLearnedDownload { model.declineLiveWaveLearnedDownload() }
                    })
            ) {
                Button("Download " + LearnedField.Release.megabytes(LiveWave.Refinement.Release.asset.bytes))
                {
                    model.downloadLiveWaveLearnedWeights()
                }
                Button("Not Now", role: .cancel) { model.declineLiveWaveLearnedDownload() }
            } message: {
                Text(LiveWave.Refinement.Release.offer)
            }
        }
    }
#endif
