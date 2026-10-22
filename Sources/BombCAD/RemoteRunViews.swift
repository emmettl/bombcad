import SwiftUI

/// Where Run sends the blast: this Mac, or a Mac nearby paired with it (emmettl/bombcad-work#73).
/// Shown once a Mac is paired (Settings ▸ Macs nearby).
struct RunOnPicker: View {
    @Bindable var model: SimulationModel
    @State private var macs: [String] = []

    var body: some View {
        Group {
            if !macs.isEmpty || model.runHost != nil {
                Picker("Run on", selection: $model.runHost) {
                    Text("This Mac").tag(String?.none)
                    ForEach(macs + (model.runHost.map { macs.contains($0) ? [] : [$0] } ?? []), id: \.self) {
                        Text(NearbyWorkers.name(of: $0)).tag(String?.some($0))
                    }
                }
                .disabled(model.remoteRun?.isActive == true)
                .help(
                    "Where the blast runs. On a Mac nearby, its GPU runs the blast, the structures and the fragments, thermal radiation and ground points the project has, and sends the view here as it goes; the run comes back with its recording and their results, to replay and compare. The view shows the blast and the structures only."
                )
            }
        }
        .onAppear { macs = model.pairedMacs }
    }
}

/// The run on another Mac, over the viewport: how far it has got, and what to do if the link drops.
struct RemoteRunOverlay: View {
    let model: SimulationModel
    let remote: RemoteRun

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch remote.phase {
            case .connecting:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Connecting to \(remote.macName)…")
                    Button("Stop") { model.stopRemoteRun() }
                }
            case .running:
                HStack {
                    ProgressView(value: remote.fraction).frame(width: 120)
                    Text(running).monospacedDigit()
                    Button(remote.paused ? "Resume" : "Pause") { model.toggleRemotePause() }
                        .help(
                            remote.paused
                                ? "Let the run go on."
                                : "Hold the run there; the scene here can then be edited, and run again with the edits."
                        )
                    Button("Stop") { model.stopRemoteRun() }
                        .help("Stop the run on \(remote.macName); nothing comes back.")
                }
                if remote.paused {
                    HStack {
                        Text(
                            model.remoteRunEdited
                                ? "Paused. The scene has been edited here since it was sent."
                                : "Paused. Edit the scene to run it again with the edits.")
                        Button("Rerun with Edits") { model.rerunRemoteWithEdits() }
                            .disabled(!model.remoteRunEdited)
                            .help(
                                "Stop this run on \(remote.macName) and run the scene as it is now there, over the same connection; only what changed is sent."
                            )
                    }
                }
            case .lost(let reason):
                Text(reason).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Keep Watching") { model.resumeRemoteRun() }
                        .help("Connect again and watch the run where it has got to.")
                    Button("Fetch Result Later") { model.fetchRemoteResultLater() }
                        .help("Go back to this Mac's scene; the run carries on there.")
                    Button("Stop") { model.stopRemoteRun() }
                        .help("Stop the run on \(remote.macName); nothing comes back.")
                }
            case .waiting:
                HStack {
                    Text("“\(remote.name)” runs on, on \(remote.macName).")
                    Button("Fetch Result") { model.resumeRemoteRun() }
                        .help("Connect again: the result if it has finished, or the run where it has got to.")
                    Button("Forget") { model.stopRemoteRun() }
                }
            case .finished:
                HStack(alignment: .firstTextBaseline) {
                    Text("“\(remote.name)” came back from \(remote.macName) and is kept.")
                    Button("Dismiss") { model.dismissRemoteRun() }
                }
                if let summary = remote.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .failed(let reason):
                HStack(alignment: .firstTextBaseline) {
                    Text("The run on \(remote.macName) failed: \(reason)").fixedSize(
                        horizontal: false, vertical: true)
                    Button("Dismiss") { model.dismissRemoteRun() }
                }
            case .stopped:
                HStack {
                    Text("The run on \(remote.macName) was stopped.")
                    Button("Dismiss") { model.dismissRemoteRun() }
                }
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
    }

    private var running: String {
        var line = "On \(remote.link.isEmpty ? remote.macName : remote.link)"
        if !remote.device.isEmpty { line += " (\(remote.device))" }
        line += String(format: ": %.0f%%", 100 * remote.fraction)
        if remote.framesShown > 0 { line += ", \(remote.framesShown) frames shown" }
        return line
    }
}
