import BlastCore
import DocumentKit
import Foundation
import Network
import Testing

@testable import BombCAD

/// Two ends of a pairing exchange in one process.
private final class QueueChannel: PairingChannel, @unchecked Sendable {
    private let inbox: AsyncStream<NearbyPairing.Message>
    private var iterator: AsyncStream<NearbyPairing.Message>.Iterator
    private let outbox: AsyncStream<NearbyPairing.Message>.Continuation
    /// Changes what this end sends, as a Mac in the middle might.
    var tamper: (NearbyPairing.Message) -> NearbyPairing.Message = { $0 }

    private init(
        inbox: AsyncStream<NearbyPairing.Message>, outbox: AsyncStream<NearbyPairing.Message>.Continuation
    ) {
        self.inbox = inbox
        iterator = inbox.makeAsyncIterator()
        self.outbox = outbox
    }

    static func pair() -> (QueueChannel, QueueChannel) {
        let (a, toA) = AsyncStream<NearbyPairing.Message>.makeStream()
        let (b, toB) = AsyncStream<NearbyPairing.Message>.makeStream()
        return (QueueChannel(inbox: a, outbox: toB), QueueChannel(inbox: b, outbox: toA))
    }

    func send(_ message: NearbyPairing.Message) async throws { outbox.yield(tamper(message)) }

    func receive() async throws -> NearbyPairing.Message {
        guard let message = await iterator.next() else { throw NearbyError.closed }
        return message
    }
}

@Suite("Pairing Macs nearby")
struct NearbyPairingTests {
    private let laptop = NearbyPairing.Peer(id: UUID(), name: "Laptop")
    private let studio = NearbyPairing.Peer(id: UUID(), name: "Studio")

    /// Both sides of one pairing, with what each was shown.
    private func run(
        client: QueueChannel, server: QueueChannel, confirm: Bool = true, allow: Bool = true
    ) async -> (
        client: Result<NearbyPairing.Pairing, Error>, server: Result<NearbyPairing.Pairing, Error>,
        codes: [String]
    ) {
        let codes = Locked<[String]>([])
        async let serverSide = Result {
            try await NearbyPairing.answer(over: server, me: studio) { _, code in
                codes.update { $0.append(code) }
                return allow
            }
        }
        let clientSide = await Result {
            try await NearbyPairing.pair(over: client, me: laptop) { _, code in
                codes.update { $0.append(code) }
                return confirm
            }
        }
        return (clientSide, await serverSide, codes.value)
    }

    @Test("Both Macs show the same code and keep the same key, each knowing the other")
    func agree() async throws {
        let (client, server) = QueueChannel.pair()
        let result = await run(client: client, server: server)
        let kept = try result.client.get()
        let other = try result.server.get()
        #expect(kept.key == other.key && kept.key.count == 32)
        #expect(kept.peer == studio && other.peer == laptop)
        #expect(result.codes.count == 2 && result.codes[0] == result.codes[1] && result.codes[0].count == 6)
        // A second pairing makes a new key.
        let (again, againServer) = QueueChannel.pair()
        #expect(try await run(client: again, server: againServer).client.get().key != kept.key)
    }

    @Test("Declined on either Mac, neither keeps a key")
    func declined() async {
        for (confirm, allow) in [(false, true), (true, false), (false, false)] {
            let (client, server) = QueueChannel.pair()
            let result = await run(client: client, server: server, confirm: confirm, allow: allow)
            #expect((try? result.client.get()) == nil && (try? result.server.get()) == nil)
        }
    }

    @Test("A key revealed other than the one committed to is refused")
    func commitment() async {
        let (client, server) = QueueChannel.pair()
        client.tamper = { message in
            guard case .reveal(_, let nonce) = message else { return message }
            return .reveal(publicKey: NearbyPairing.Exchange().publicKey, nonce: nonce)
        }
        let result = await run(client: client, server: server)
        #expect((try? result.server.get()) == nil && (try? result.client.get()) == nil)
    }

    @Test("A Mac in the middle, pairing with each side on its own, gets codes that differ")
    func middle() async throws {
        // The laptop pairs with the middle, which pairs with the studio: two exchanges, two secrets.
        let (laptopEnd, middleFromLaptop) = QueueChannel.pair()
        let (middleToStudio, studioEnd) = QueueChannel.pair()
        let middle = NearbyPairing.Peer(id: studio.id, name: "Studio")
        let codes = Locked<[String: String]>([:])
        async let laptopSide = Result {
            try await NearbyPairing.pair(over: laptopEnd, me: laptop) { _, code in
                codes.update { $0["laptop"] = code }
                return codes.value["laptop"] == codes.value["studio"]
            }
        }
        async let studioSide = Result {
            try await NearbyPairing.answer(over: studioEnd, me: studio) { _, code in
                codes.update { $0["studio"] = code }
                return true
            }
        }
        async let fromLaptop = Result {
            try await NearbyPairing.answer(over: middleFromLaptop, me: middle) { _, _ in true }
        }
        async let toStudio = Result {
            try await NearbyPairing.pair(over: middleToStudio, me: laptop) { _, _ in true }
        }
        _ = await (fromLaptop, toStudio, studioSide)
        _ = await laptopSide
        #expect(codes.value["laptop"] != nil && codes.value["laptop"] != codes.value["studio"])
    }

    @Test("Links rank Thunderbolt, then wired with an address, then Wi-Fi, then the rest")
    func links() {
        #expect(NearbyWorkers.rank(name: "bridge0", type: .wiredEthernet, hasIPv4: true) == 0)
        #expect(NearbyWorkers.rank(name: "en0", type: .wiredEthernet, hasIPv4: true) == 1)
        #expect(NearbyWorkers.rank(name: "en1", type: .wifi, hasIPv4: true) == 2)
        #expect(NearbyWorkers.rank(name: "en15", type: .wiredEthernet, hasIPv4: false) == 3)
        #expect(NearbyWorkers.rank(name: "anri1", type: .other, hasIPv4: false) == 3)
    }

    @Test("A file of pairings is its owner's alone, and keeps this Mac's identity")
    func fileStore() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "nearby-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try FilePairingStore(url: url, name: "Here")
        try store.keep(.init(peer: studio, key: Data(repeating: 1, count: 32)))
        let again = try FilePairingStore(url: url, name: "Here")
        #expect(again.me == store.me && again.pairing(named: "Studio")?.key == Data(repeating: 1, count: 32))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try again.forget(studio.id)
        #expect(try FilePairingStore(url: url).pairings().isEmpty)
    }
}

@MainActor @Suite("Workers on Macs nearby", .serialized, .hangLimit)
struct NearbyWorkerTests {
    private func document() -> ProjectDocument {
        var scene = Scenario(
            name: "Nearby", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0.01, position: SIMD3(2, 2, 1)))
        scene.gauges = [Gauge("Near", at: SIMD3(2.5, 2, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.004
        return document
    }

    /// Finding the server waits on no clock: the resolver below answers at once. The connections
    /// themselves fail in their own time if they stall (`NearbyWorkers.connectLimit`), and each
    /// test has a network limit well short of the suite's hang limit.
    private let discovery = Duration.seconds(600)

    /// The server found where it listens on this Mac, without Bonjour, whose answers a test's
    /// process may not be allowed.
    private func resolver(_ server: NearbyServer, _ store: MemoryPairingStore) -> NearbyWorkers.Resolve {
        { id, service, _ in
            guard id == store.me.id else { throw NearbyError.notFound("That Mac") }
            let port = try await server.port(of: service)
            return NearbyBrowser.Found(
                name: store.me.name, advert: .mine(id), endpoint: .hostPort(host: "127.0.0.1", port: port),
                interfaces: [])
        }
    }

    /// A sharing Mac in this process, under a name of its own, its sessions served in-process; the
    /// codes it shows come in order.
    private func server(allow: Bool = true) throws -> (NearbyServer, MemoryPairingStore, AsyncStream<String>)
    {
        let store = MemoryPairingStore(name: "Test server \(UUID().uuidString.prefix(8))")
        let (shown, show) = AsyncStream<String>.makeStream()
        let server = NearbyServer(store: store) { _, code in
            show.yield(code)
            return allow
        } startWorker: { input, output, _ in
            Task { @MainActor in
                await SweepWorker.serve(input: input, output: output)
                try? output.close()
            }
        }
        try server.start()
        return (server, store, shown)
    }

    // The hang limit, not the network one: this test also runs a case on the GPU here and on the
    // "worker", which under a loaded Studio (load 100–130, 19 October 2026) took past three minutes.
    // A stalled connection still fails within the app's own deadlines (a minute a step).
    @Test("A Mac paired over the network runs a case to the same answer", .hangLimit)
    func session() async throws {
        let (server, serverStore, shown) = try server()
        defer { server.stop() }
        let clientStore = MemoryPairingStore(name: "Test client")
        let pairing = try await NearbyWorkers.pair(
            with: serverStore.me.id, store: clientStore, discovery: discovery,
            resolve: resolver(server, serverStore)
        ) { _, code in
            // As the user reads the server's code.
            var codes = shown.makeAsyncIterator()
            return await codes.next() == code
        }
        #expect(pairing.peer == serverStore.me && serverStore.pairing(clientStore.me.id)?.key == pairing.key)

        // The server restarted its sessions with the new key before it confirmed.
        let host = NearbyWorkers.host(serverStore.me.name)
        let worker = try await NearbyWorkers.connect(
            host: host, store: clientStore, discovery: discovery, resolve: resolver(server, serverStore))
        let inputs = SimulationInputs(scenario: document().scenario, settings: document().runSettings!)
        let item = try ParameterSweepPlan(prefix: "Case", parameter: .chargeMass([0.02])).prepare(
            from: inputs)[0]
        let run = try await worker.run(item)
        let (local, localServer) = localWorker()
        _ = try await local.start()
        let here = try await local.run(item)
        #expect(run.gauges == here.gauges && run.stepCount == here.stepCount)
        worker.close()
        local.close()
        await localServer.value
    }

    @Test("An unpaired Mac, or one with the wrong key, is refused; a busy one says why", .networkLimit)
    func refusals() async throws {
        let (server, serverStore, _) = try server()
        defer { server.stop() }
        let host = NearbyWorkers.host(serverStore.me.name)
        let stranger = MemoryPairingStore(name: "Stranger")
        await #expect(throws: NearbyError.self) {
            _ = try await NearbyWorkers.connect(
                host: host, store: stranger, discovery: discovery, resolve: resolver(server, serverStore))
        }

        // A key the server never agreed: TLS fails before any worker starts.
        try stranger.keep(.init(peer: serverStore.me, key: Data(repeating: 9, count: 32)))
        await #expect(throws: (any Error).self) {
            let worker = try await NearbyWorkers.connect(
                host: host, store: stranger, discovery: discovery, resolve: resolver(server, serverStore))
            worker.close()
        }

        // Paired properly, but its gate refuses: no load is low enough.
        let friend = MemoryPairingStore(name: "Friend")
        let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        try friend.keep(.init(peer: serverStore.me, key: key))
        try serverStore.keep(.init(peer: friend.me, key: key))
        try server.restartSessions()
        // Quiet all day.
        let busy = RemoteGate(
            runners: [], quietUTC: ["00:00-12:00", "12:00-00:00"], maxLoadPerCore: 100, what: "a test")
        do {
            let worker = try await NearbyWorkers.connect(
                host: host, gate: busy, store: friend, discovery: discovery,
                resolve: resolver(server, serverStore))
            worker.close()
            Issue.record("A gate in its quiet window took work.")
        } catch {
            #expect(error.localizedDescription.contains("not taking work"))
        }
        let worker = try await NearbyWorkers.connect(
            host: host, store: friend, discovery: discovery, resolve: resolver(server, serverStore))
        #expect(worker.hello?.protocolVersion == SweepWorkerHello.protocolVersion)
        worker.close()
    }

    @Test("A handshake or a message that stalls fails in time instead of waiting for ever", .networkLimit)
    func stalls() async throws {
        // Takes connections and never says a word.
        let listener = try NWListener(using: NearbyWorkers.pairingParameters())
        let held = Locked<[NWConnection]>([])
        listener.newConnectionHandler = { connection in
            held.update { $0.append(connection) }
            connection.start(queue: .main)
        }
        let port = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<NWEndpoint.Port, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port, once.claim() { continuation.resume(returning: port) }
                case .failed(let error): if once.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: .main)
        }
        defer {
            listener.cancel()
            for connection in held.value { connection.cancel() }
        }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let limit = Duration.seconds(1)

        /// Whether `body` failed for lack of an answer, and soon after `limit`.
        func timesOut(_ body: () async throws -> Void) async -> Bool {
            let start = ContinuousClock.now
            do {
                try await body()
                return false
            } catch NearbyError.timedOut {
                return ContinuousClock.now - start < limit * 20
            } catch {
                Issue.record("Failed otherwise: \(error)")
                return false
            }
        }

        // TCP connects, but the TLS handshake never hears back.
        let tls = ConnectionChannel(
            NWConnection(
                to: endpoint,
                using: NearbyWorkers.sessionParameters(keys: [("nobody", Data(repeating: 7, count: 32))])),
            peer: "Silent")
        #expect(await timesOut { try await tls.start(within: limit) })
        // Connected, then nothing.
        let plain = ConnectionChannel(NWConnection(to: endpoint, using: NearbyWorkers.pairingParameters()))
        defer { plain.connection.cancel() }
        try await plain.start()
        #expect(await timesOut { _ = try await plain.receiveFrame(within: limit) })
    }
}
