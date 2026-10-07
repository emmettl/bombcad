import SwiftUI

struct AppSettingsView: View {
    @AppStorage(AppPreferences.Key.resolution) private var resolution = Resolution.medium.rawValue
    @AppStorage(AppPreferences.Key.detailedCharge) private var detailedCharge = false
    @AppStorage(AppPreferences.Key.sharpShocks) private var sharpShocks = false
    @AppStorage(AppPreferences.Key.playbackSpeed) private var playbackSpeed = PlaybackSpeed.x100.rawValue

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
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    resolution = Resolution.medium.rawValue
                    detailedCharge = false
                    sharpShocks = false
                    playbackSpeed = PlaybackSpeed.x100.rawValue
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 480, height: 400)
    }
}
