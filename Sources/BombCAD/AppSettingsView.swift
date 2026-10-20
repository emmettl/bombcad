import SwiftUI

struct AppSettingsView: View {
    @AppStorage(AppPreferences.Key.resolution) private var resolution = Resolution.medium.rawValue
    @AppStorage(AppPreferences.Key.detailedCharge) private var detailedCharge = true
    @AppStorage(AppPreferences.Key.sharpShocks) private var sharpShocks = false
    @AppStorage(AppPreferences.Key.playbackSpeed) private var playbackSpeed = PlaybackSpeed.x100.rawValue
    @AppStorage(AppPreferences.Key.sweepHosts) private var sweepHosts = ""
    @AppStorage(AppPreferences.Key.sweepUsesRemote) private var sweepUsesRemote = false
    @AppStorage(AppPreferences.Key.recordsTimelines) private var recordsTimelines = true
    @AppStorage(AppPreferences.Key.timelineBudgetMB) private var timelineBudgetMB =
        RunTimelineRecorder.defaultBudgetBytes >> 20
    @AppStorage(AppPreferences.Key.checkpointBudgetMB) private var checkpointBudgetMB =
        RunTimelineRecorder.defaultCheckpointBudgetBytes >> 20
    @State private var newHost = ""
    @State private var addError: String?
    /// Each host's last test result, and the hosts being tested.
    @State private var connections: [String: String] = [:]
    @State private var testing: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker(
                        "Grid",
                        selection: Binding(
                            get: { Resolution(rawValue: resolution) ?? .medium },
                            set: { resolution = $0.rawValue }
                        )
                    ) {
                        ForEach(Resolution.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Afterburning and hot air", isOn: $detailedCharge)
                    Toggle("Sharpen shocks", isOn: $sharpShocks)
                } header: {
                    Text("New project defaults")
                } footer: {
                    Text(
                        "Used when you create a project. Existing projects keep their own simulation settings. Finer grids use more memory and take longer."
                    )
                }

                Section {
                    Picker(
                        "Default speed",
                        selection: Binding(
                            get: { PlaybackSpeed(rawValue: playbackSpeed) ?? .x100 },
                            set: { playbackSpeed = $0.rawValue }
                        )
                    ) {
                        ForEach(PlaybackSpeed.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text(
                        "The starting playback speed for new windows. You can change it in each window’s Run tab."
                    )
                }

                Section {
                    Toggle("Record runs to replay", isOn: $recordsTimelines)
                    Picker("Space for each run", selection: $timelineBudgetMB) {
                        ForEach([64, 128, 256, 512, 1024], id: \.self) { Text("\($0) MB").tag($0) }
                    }
                    .disabled(!recordsTimelines)
                    Picker("Space for saved states", selection: $checkpointBudgetMB) {
                        Text("Only those saved by hand").tag(0)
                        ForEach([256, 512, 1024, 2048, 4096], id: \.self) {
                            Text($0 < 1024 ? "\($0) MB" : "\($0 / 1024) GB").tag($0)
                        }
                    }
                    .disabled(!recordsTimelines)
                } header: {
                    Text("Replay")
                } footer: {
                    Text(
                        "A run records what the view draws, about 240 frames, so that it can be replayed and scrubbed without running again, and a kept run keeps its recording in the project. Past its space, a run records less often rather than stopping. A run also saves its full state every eighth of the way, while those fit their space, and wherever you choose Simulation ▸ Save State Here; replaying it, Continue runs on from the state saved at that time or just before."
                    )
                }

                NearbySettingsSections(hosts: $sweepHosts)

                Section {
                    ForEach(hosts, id: \.self) { host in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host)
                                if let result = connections[host] {
                                    Text(result).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                            Button(testing.contains(host) ? "Testing…" : "Test") { test(host) }
                                .disabled(testing.contains(host))
                            Button {
                                remove(host)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove \(host)")
                            .accessibilityLabel("Remove \(host)")
                        }
                    }
                    HStack {
                        TextField("Add SSH host", text: $newHost, prompt: Text("my-mac.local"))
                            .autocorrectionDisabled()
                            .onSubmit(add)
                        Button("Add", action: add)
                            .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let addError {
                        Text(addError).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle("Share sweeps with these Macs", isOn: $sweepUsesRemote)
                        .disabled(hosts.isEmpty)
                } header: {
                    Text("Sweeps on other Macs")
                } footer: {
                    Text(
                        "Sweep cases are shared with Macs nearby once paired, and with Apple silicon Macs reached over SSH without a password, to which BombCAD sends a copy of itself the first time. A slower Mac is given only the cases it will finish before the rest of the sweep. Fragments fly on the first."
                    )
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    resolution = Resolution.medium.rawValue
                    detailedCharge = true
                    sharpShocks = false
                    playbackSpeed = PlaybackSpeed.x100.rawValue
                    sweepUsesRemote = false
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 480, height: 720)
    }

    private var hosts: [String] { AppPreferences.hosts(sweepHosts) }

    private func add() {
        let host = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try RemoteSweepWorker.validate(host)
            guard !hosts.contains(host) else {
                addError = "\(host) is already in the list."
                return
            }
            sweepHosts = AppPreferences.text(hosts + [host])
            newHost = ""
            addError = nil
        } catch {
            addError = error.localizedDescription
        }
    }

    private func remove(_ host: String) {
        sweepHosts = AppPreferences.text(hosts.filter { $0 != host })
        connections[host] = nil
    }

    private func test(_ host: String) {
        testing.insert(host)
        connections[host] = "Connecting…"
        Task {
            do {
                let worker = try await RemoteSweepWorker.connect(host: host)
                let hello = worker.hello
                worker.close()
                connections[host] =
                    "Ready: \(hello?.device ?? "a Metal device"), \(hello?.operatingSystem ?? "")"
            } catch {
                connections[host] = error.localizedDescription
            }
            testing.remove(host)
        }
    }
}
