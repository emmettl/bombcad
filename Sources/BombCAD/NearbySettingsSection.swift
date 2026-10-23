#if os(macOS)
    import AppKit
    import SwiftUI

    /// This Mac sharing its GPU with Macs nearby, for as long as the app runs with the setting on
    /// (see `NearbyServer`). A Mac asking to pair is shown in an alert with its code.
    @MainActor @Observable
    final class NearbySharing {
        static let shared = NearbySharing()
        static let key = "nearby.sharing"

        private var server: NearbyServer?
        private(set) var problem: String?
        /// The Macs paired to send work here, for the list in Settings.
        private(set) var pairedHere: [NearbyPairing.Peer] = []

        var isSharing: Bool { server?.isRunning ?? false }

        /// Starts sharing if it was on when the app last quit.
        func restore() {
            if UserDefaults.standard.bool(forKey: Self.key) { set(true) }
        }

        func set(_ on: Bool) {
            UserDefaults.standard.set(on, forKey: Self.key)
            problem = nil
            if on, server == nil {
                // The saved projects open now: their kept runs' recordings an iPad paired here can
                // replay (emmettl/bombcad-work#43).
                NearbyServer.sharedProjects = { NSDocumentController.shared.documents.compactMap(\.fileURL) }
                let server = NearbyServer(allow: Self.askToAllow)
                server.paired = { [weak self] _ in self?.refresh() }
                do {
                    try server.start()
                    self.server = server
                } catch {
                    problem = error.localizedDescription
                }
            } else if !on {
                server?.stop()
                server = nil
            }
            refresh()
        }

        func forget(_ peer: NearbyPairing.Peer) {
            if let server { try? server.forget(peer.id) } else { try? NearbyWorkers.store.forget(peer.id) }
            refresh()
        }

        func refresh() {
            // Pairings this Mac answered and those it asked for share the store; the list shows them all.
            pairedHere = NearbyWorkers.store.pairings().map(\.peer)
        }

        private static let askToAllow: @Sendable (NearbyPairing.Peer, String) async -> Bool = { peer, code in
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "\(peer.name) wants to use this Mac’s GPU"
                alert.informativeText =
                    "Allow only if \(peer.name) shows the code \(code). It can then run simulations here whenever this Mac shares its GPU."
                alert.addButton(withTitle: "Allow")
                alert.addButton(withTitle: "Don’t Allow")
                NSApp.activate(ignoringOtherApps: true)
                return alert.runModal() == .alertFirstButtonReturn
            }
        }
    }

    /// The Settings sections for Macs nearby: sharing this Mac's GPU, and pairing with those that share
    /// theirs. A Mac paired goes into the list of other Macs as `nearby:<its name>`.
    struct NearbySettingsSections: View {
        @Binding var hosts: String
        @State private var sharing = NearbySharing.shared
        @State private var browser: NearbyBrowser?
        @State private var found: [NearbyBrowser.Found] = []
        @State private var pairing: UUID?
        @State private var message: String?

        var body: some View {
            Section {
                Toggle(
                    "Share this Mac’s GPU with Macs nearby",
                    isOn: Binding(get: { sharing.isSharing }, set: { sharing.set($0) }))
                if let problem = sharing.problem {
                    Text(problem).font(.caption).foregroundStyle(.red).fixedSize(
                        horizontal: false, vertical: true)
                }
            } header: {
                Text("This Mac")
            } footer: {
                Text(
                    "While on, Macs nearby can ask to pair; each is allowed once, here, after checking both Macs show the same code. A paired Mac can then run simulations on this Mac’s GPU while BombCAD is open."
                )
            }

            Section {
                if found.isEmpty {
                    Text(
                        "No Mac nearby is sharing its GPU. Turn sharing on in BombCAD’s Settings on that Mac."
                    )
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(found, id: \.advert.id) { mac in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mac.name)
                            Text(detail(mac)).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if isPaired(mac) {
                            Text("Paired").foregroundStyle(.secondary)
                            Button("Forget") { forget(mac) }
                        } else {
                            Button(pairing == mac.advert.id ? "Pairing…" : "Pair…") { pair(mac) }
                                .disabled(
                                    pairing != nil || !mac.advert.compatible
                                        || mac.advert.id == NearbyWorkers.store.me.id)
                        }
                    }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                }
            } header: {
                Text("Macs nearby")
            } footer: {
                Text(
                    "Macs on this network that share their GPU, found automatically. Each is reached over its fastest link: Thunderbolt, then Ethernet, then Wi-Fi."
                )
            }
            .onAppear(perform: startBrowsing)
            .onDisappear {
                browser?.stop()
                browser = nil
            }
        }

        private func detail(_ mac: NearbyBrowser.Found) -> String {
            var seen = Set<String>()
            let links = mac.interfaces.sorted { NearbyWorkers.rank($0) < NearbyWorkers.rank($1) }
                .map(NearbyWorkers.linkName).filter { seen.insert($0).inserted }
            let version =
                mac.advert.compatible
                ? "" : " — needs the same BombCAD as this Mac (it has \(mac.advert.version))"
            return "\(mac.advert.device), over \(links.joined(separator: ", "))\(version)"
        }

        private func isPaired(_ mac: NearbyBrowser.Found) -> Bool {
            NearbyWorkers.store.pairing(mac.advert.id) != nil
        }

        private func startBrowsing() {
            sharing.refresh()
            let browser = NearbyBrowser()
            browser.changed = { found = $0 }
            browser.start()
            self.browser = browser
        }

        private func pair(_ mac: NearbyBrowser.Found) {
            pairing = mac.advert.id
            message = "Allow the request on \(mac.name)…"
            Task { @MainActor in
                do {
                    let pairing = try await NearbyWorkers.pair(with: mac.advert.id) { peer, code in
                        await MainActor.run {
                            let alert = NSAlert()
                            alert.messageText = "Does \(peer.name) show the code \(code)?"
                            alert.informativeText =
                                "Pair only if it does: another Mac could be pretending to be it."
                            alert.addButton(withTitle: "It Matches")
                            alert.addButton(withTitle: "Cancel")
                            return alert.runModal() == .alertFirstButtonReturn
                        }
                    }
                    let host = NearbyWorkers.host(pairing.peer.name)
                    hosts = AppPreferences.text(AppPreferences.hosts(hosts) + [host])
                    message = "Paired with \(pairing.peer.name); it is in the list below as \(host)."
                } catch {
                    message = error.localizedDescription
                }
                self.pairing = nil
                sharing.refresh()
            }
        }

        private func forget(_ mac: NearbyBrowser.Found) {
            if let peer = NearbyWorkers.store.pairing(mac.advert.id)?.peer {
                sharing.forget(peer)
                hosts = AppPreferences.text(
                    AppPreferences.hosts(hosts).filter { $0 != NearbyWorkers.host(peer.name) })
            }
            found = found.map { $0 }
        }
    }
#endif
