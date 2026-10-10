import SwiftUI

/// Where a companion of the run goes: this Mac, one of the Macs set for sweeps in Settings, or
/// Automatic, whichever of them the run is estimated to wait least for (`ConsumerPlacement`).
/// Shown only when there are some; a Mac taken out of the list since is offered until changed.
struct PlacementPicker: View {
    let title: String
    @Binding var host: String?
    let help: String
    @AppStorage(AppPreferences.Key.sweepHosts) private var sweepHosts = ""

    var body: some View {
        let hosts = AppPreferences.hosts(sweepHosts)
        if !hosts.isEmpty {
            Picker(title, selection: $host) {
                Text("This Mac").tag(String?.none)
                Text("Automatic").tag(String?.some(ConsumerPlacement.automatic))
                ForEach(
                    hosts
                        + (host.map { hosts.contains($0) || $0 == ConsumerPlacement.automatic ? [] : [$0] }
                            ?? []),
                    id: \.self
                ) { host in
                    Text(host).tag(String?.some(host))
                }
            }
            .help(
                help
                    + " Automatic chooses by what each costs: measured by the last run and probed on each Mac."
            )
        }
    }
}
