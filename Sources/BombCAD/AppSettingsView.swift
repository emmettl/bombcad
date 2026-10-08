import SwiftUI

struct AppSettingsView: View {
    @AppStorage(AppPreferences.Key.resolution) private var resolution = Resolution.medium.rawValue
    @AppStorage(AppPreferences.Key.detailedCharge) private var detailedCharge = false
    @AppStorage(AppPreferences.Key.sharpShocks) private var sharpShocks = false
    @AppStorage(AppPreferences.Key.playbackSpeed) private var playbackSpeed = PlaybackSpeed.x100.rawValue
    @AppStorage(AppPreferences.Key.sweepHost) private var sweepHost = ""
    @AppStorage(AppPreferences.Key.sweepUsesRemote) private var sweepUsesRemote = false
    @State private var connection = ""
    @State private var testing = false

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
                    TextField("SSH host", text: $sweepHost, prompt: Text("my-mac.local"))
                        .autocorrectionDisabled()
                    Toggle("Share sweeps with this Mac", isOn: $sweepUsesRemote)
                    HStack {
                        Button(testing ? "Testing…" : "Test Connection") { test() }
                            .disabled(testing || sweepHost.trimmingCharacters(in: .whitespaces).isEmpty)
                        Text(connection).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Sweeps on another Mac")
                } footer: {
                    Text(
                        "Sweep cases are shared with an Apple silicon Mac reached over SSH without a password. BombCAD sends it a copy of itself the first time. A slower Mac is given only the cases it will finish before this one."
                    )
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    resolution = Resolution.medium.rawValue
                    detailedCharge = false
                    sharpShocks = false
                    playbackSpeed = PlaybackSpeed.x100.rawValue
                    sweepUsesRemote = false
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 480, height: 640)
    }

    private func test() {
        let host = sweepHost.trimmingCharacters(in: .whitespacesAndNewlines)
        testing = true
        connection = "Connecting to \(host)…"
        Task {
            do {
                let worker = try await RemoteSweepWorker.connect(host: host)
                let hello = worker.hello
                worker.close()
                connection = "Ready: \(hello?.device ?? "a Metal device"), \(hello?.operatingSystem ?? "")"
            } catch {
                connection = error.localizedDescription
            }
            testing = false
        }
    }
}
