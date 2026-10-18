import BlastCore
import Foundation
import Metal
import Network

/// Workers on Macs nearby, found by Bonjour and reached directly over TCP rather than SSH: a Mac
/// shares its GPU (`NearbyServer`, `BombCAD serve` or the app's setting), advertising a pairing
/// service and a session service on the local network; another Mac pairs with it once
/// (`NearbyPairing`), keeping a key, and then names it `nearby:<its name>` wherever an SSH host is
/// taken (sweeps, the models fed alongside a run, `watch`). A session is TLS with the pairing's key
/// (pre-shared, TLS 1.2), then the same messages a worker reads over SSH, to a `BombCAD worker`
/// the sharing Mac starts for it. Of the links a Mac is seen on, the fastest is taken: the
/// Thunderbolt bridge, then wired Ethernet, then Wi-Fi.
enum NearbyWorkers {
    static let sessionService = "_bombcad._tcp"
    static let pairingService = "_bombcad-pair._tcp"
    static let hostPrefix = "nearby:"

    /// Finds the sharing Mac `id` offering `service`, waiting up to a time: by Bonjour, or in tests
    /// the address a server in the same process listens on.
    typealias Resolve =
        @MainActor (_ id: UUID, _ service: String, _ within: Duration) async throws -> NearbyBrowser.Found

    static func isNearby(_ host: String) -> Bool { host.hasPrefix(hostPrefix) }
    static func host(_ name: String) -> String { hostPrefix + name }
    static func name(of host: String) -> String { String(host.dropFirst(hostPrefix.count)) }

    /// Where this Mac keeps its pairings: a file named by `BOMBCAD_NEARBY_STORE`, or the Keychain.
    nonisolated(unsafe) static var store: PairingStore = {
        if let path = ProcessInfo.processInfo.environment["BOMBCAD_NEARBY_STORE"],
            let store = try? FilePairingStore(url: URL(filePath: path))
        {
            return store
        }
        return KeychainPairingStore()
    }()

    /// What a sharing Mac says of itself in its services' TXT records.
    struct Advert: Equatable, Sendable {
        var id: UUID
        var version: String
        var protocolVersion: Int
        var solverVersion: String
        var device: String

        static func mine(_ id: UUID) -> Advert {
            Advert(
                id: id,
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                    ?? "development",
                protocolVersion: SweepWorkerHello.protocolVersion,
                solverVersion: SavedSimulationRun.solverVersion,
                device: MTLDeviceName.current)
        }

        var record: NWTXTRecord {
            NWTXTRecord([
                "id": id.uuidString, "version": version, "protocol": String(protocolVersion),
                "solver": solverVersion, "device": device,
            ])
        }

        init(id: UUID, version: String, protocolVersion: Int, solverVersion: String, device: String) {
            self.id = id
            self.version = version
            self.protocolVersion = protocolVersion
            self.solverVersion = solverVersion
            self.device = device
        }

        init?(_ record: NWTXTRecord) {
            guard let text = record["id"], let id = UUID(uuidString: text) else { return nil }
            self.init(
                id: id, version: record["version"] ?? "?",
                protocolVersion: Int(record["protocol"] ?? "") ?? 0,
                solverVersion: record["solver"] ?? "", device: record["device"] ?? "")
        }

        /// Whether this Mac's BombCAD can send work to it.
        var compatible: Bool {
            protocolVersion == SweepWorkerHello.protocolVersion
                && solverVersion == SavedSimulationRun.solverVersion
        }
    }

    // MARK: - Links

    /// How fast a link to another Mac is likely to be, lowest best: the Thunderbolt bridge, wired
    /// Ethernet with an IPv4 address, Wi-Fi, then anything else (link-local interfaces among them,
    /// which can be as slow as Wi-Fi).
    static func rank(name: String, type: NWInterface.InterfaceType, hasIPv4: Bool) -> Int {
        if name.hasPrefix("bridge") { return 0 }
        switch type {
        case .wiredEthernet where hasIPv4: return 1
        case .wifi: return 2
        default: return 3
        }
    }

    static func rank(_ interface: NWInterface) -> Int {
        rank(name: interface.name, type: interface.type, hasIPv4: ipv4Interfaces().contains(interface.name))
    }

    /// The link's name as a person would say it.
    static func linkName(_ interface: NWInterface) -> String {
        if interface.name.hasPrefix("bridge") { return "Thunderbolt" }
        switch interface.type {
        case .wifi: return "Wi-Fi"
        case .wiredEthernet: return "Ethernet"
        case .loopback: return "this Mac"
        default: return interface.name
        }
    }

    /// The interfaces with an IPv4 address.
    static func ipv4Interfaces() -> Set<String> {
        var names = Set<String>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return names }
        defer { freeifaddrs(list) }
        var entry: UnsafeMutablePointer<ifaddrs>? = first
        while let current = entry {
            if current.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET) {
                names.insert(String(cString: current.pointee.ifa_name))
            }
            entry = current.pointee.ifa_next
        }
        return names
    }

    // MARK: - Parameters

    /// TLS with pre-shared keys, each under its identity; a sharing Mac lists every Mac paired with
    /// it, a sending Mac only its own key for that Mac.
    static func sessionParameters(keys: [(identity: String, key: Data)]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for (identity, key) in keys {
            let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
            let identityData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(
                options, keyData as __DispatchData, identityData as __DispatchData)
        }
        sec_protocol_options_append_tls_ciphersuite(
            options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }

    static func pairingParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    // MARK: - Sending work

    /// What a session asks for before its worker starts, and the answer.
    struct SessionRequest: Codable, Sendable {
        var gate: RemoteGate?
    }

    struct SessionAnswer: Codable, Sendable {
        var accepted: Bool
        var reason: String?
    }

    /// A worker on the paired Mac `host` names (`nearby:<name>`), over the fastest link it is seen
    /// on. With `gate`, that Mac first decides whether it should take work now, as an SSH worker
    /// does. Waits up to `discovery` for the Mac to be found.
    @MainActor
    static func connect(
        host: String, gate: RemoteGate? = nil, store: PairingStore = NearbyWorkers.store,
        discovery: Duration = .seconds(10), resolve: Resolve = NearbyBrowser.find
    ) async throws -> SweepWorkerClient {
        let name = name(of: host)
        guard let pairing = store.pairing(named: name) else {
            throw NearbyError.refused(
                "\(name) is not paired with this Mac. Pair it in Settings, or with BombCAD pair.")
        }
        let found = try await resolve(pairing.peer.id, sessionService, discovery)
        guard found.advert.compatible else {
            throw NearbyError.refused(
                "\(name) runs BombCAD \(found.advert.version), which cannot take work from this version.")
        }
        let parameters = sessionParameters(keys: [(store.me.id.uuidString, pairing.key)])
        if let link = found.bestInterface { parameters.requiredInterface = link }
        let connection = NWConnection(to: found.endpoint, using: parameters)
        let channel = ConnectionChannel(connection)
        try await channel.start()
        do {
            try await channel.sendFrame(JSONEncoder().encode(SessionRequest(gate: gate)))
            let answer = try JSONDecoder().decode(SessionAnswer.self, from: try await channel.receiveFrame())
            guard answer.accepted else {
                throw NearbyError.refused(
                    "\(name) is not taking work now: \(answer.reason ?? "no reason given").")
            }
        } catch {
            connection.cancel()
            throw error
        }
        let toWorker = Pipe()
        let fromWorker = Pipe()
        StreamBridge.attach(
            connection, sending: toWorker.fileHandleForReading, receiving: fromWorker.fileHandleForWriting)
        let link = found.bestInterface.map(linkName) ?? "the network"
        let client = SweepWorkerClient(
            name: "\(name) over \(link)", input: fromWorker.fileHandleForReading,
            output: toWorker.fileHandleForWriting
        ) {
            try? toWorker.fileHandleForWriting.close()
            connection.cancel()
        }
        do {
            _ = try await client.start()
        } catch {
            client.close()
            throw error
        }
        return client
    }

    /// Pairs with the sharing Mac `id`, found on the network; `confirm` is shown the code and
    /// returns whether that Mac shows the same. Keeps the pairing in `store`.
    @MainActor
    static func pair(
        with id: UUID, store: PairingStore = NearbyWorkers.store, discovery: Duration = .seconds(10),
        resolve: Resolve = NearbyBrowser.find,
        confirm: @escaping @Sendable (NearbyPairing.Peer, String) async -> Bool
    ) async throws -> NearbyPairing.Pairing {
        let found = try await resolve(id, pairingService, discovery)
        let parameters = pairingParameters()
        if let link = found.bestInterface { parameters.requiredInterface = link }
        let connection = NWConnection(to: found.endpoint, using: parameters)
        let channel = ConnectionChannel(connection)
        try await channel.start()
        defer { connection.cancel() }
        let pairing = try await NearbyPairing.pair(over: channel, me: store.me, confirm: confirm)
        try store.keep(pairing)
        return pairing
    }
}

/// The GPU's name, for adverts.
enum MTLDeviceName {
    static var current: String { MTLCreateSystemDefaultDevice()?.name ?? "No Metal device" }
}

/// A flag set once, from any thread.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    /// Whether this call set it.
    func claim() -> Bool {
        lock.withLock {
            defer { set = true }
            return !set
        }
    }

}

/// A value read and written from any thread.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// MARK: - Finding Macs

/// The Macs sharing their GPU nearby, as Bonjour finds them on every link, one entry a Mac.
@MainActor
final class NearbyBrowser {
    struct Found: Equatable, Sendable {
        var name: String
        var advert: NearbyWorkers.Advert
        var endpoint: NWEndpoint
        var interfaces: [NWInterface]

        /// The fastest link it is seen on, or with `BOMBCAD_NEARBY_LINK` (thunderbolt, ethernet or
        /// wifi) that link, for measuring one against another.
        var bestInterface: NWInterface? {
            if let wanted = ProcessInfo.processInfo.environment["BOMBCAD_NEARBY_LINK"]?.lowercased() {
                return interfaces.filter {
                    NearbyWorkers.linkName($0).lowercased().replacingOccurrences(of: "-", with: "") == wanted
                }
                .min { NearbyWorkers.rank($0) < NearbyWorkers.rank($1) }
            }
            return interfaces.min { NearbyWorkers.rank($0) < NearbyWorkers.rank($1) }
        }

        static func == (a: Found, b: Found) -> Bool {
            a.name == b.name && a.advert == b.advert && a.endpoint == b.endpoint
                && a.interfaces.map(\.name) == b.interfaces.map(\.name)
        }
    }

    private let browser: NWBrowser
    private(set) var found: [Found] = []
    /// Told whenever the list changes.
    var changed: ([Found]) -> Void = { _ in }

    init(service: String = NearbyWorkers.pairingService) {
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: service, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Found? in
                guard case .service(let name, _, _, _) = result.endpoint,
                    case .bonjour(let record) = result.metadata, let advert = NearbyWorkers.Advert(record)
                else { return nil }
                return Found(
                    name: name, advert: advert, endpoint: result.endpoint, interfaces: result.interfaces)
            }
            .sorted { $0.name < $1.name }
            Task { @MainActor in
                self?.found = found
                self?.changed(found)
            }
        }
    }

    func start() { browser.start(queue: .main) }
    func stop() { browser.cancel() }

    /// The Mac `id`, once found, or an error after `within`.
    static func find(_ id: UUID, _ service: String, _ within: Duration) async throws -> Found {
        let browser = NearbyBrowser(service: service)
        defer { browser.stop() }
        let name = store(id)
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            browser.changed = { found in
                if let match = found.first(where: { $0.advert.id == id }), once.claim() {
                    continuation.resume(returning: match)
                }
            }
            browser.start()
            Task { @MainActor in
                try? await Task.sleep(for: within)
                if once.claim() { continuation.resume(throwing: NearbyError.notFound(name)) }
            }
        }
    }

    private static func store(_ id: UUID) -> String {
        NearbyWorkers.store.pairing(id)?.peer.name ?? "That Mac"
    }
}

// MARK: - Connections

/// A connection as length-prefixed frames, for pairing and a session's first exchange.
final class ConnectionChannel: PairingChannel, @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.bombcad.nearby.connection")

    init(_ connection: NWConnection) { self.connection = connection }

    /// Starts the connection and waits until it is ready, or fails.
    func start() async throws {
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: NearbyError.closed) }
                case .waiting(let error):
                    // Not reachable now: no use waiting, as TCP would, for the network to change.
                    if once.claim() {
                        connection.cancel()
                        continuation.resume(throwing: error)
                    }
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func sendFrame(_ data: Data) async throws {
        var count = UInt32(data.count).bigEndian
        let frame = Data(bytes: &count, count: 4) + data
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: frame,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    func receiveFrame() async throws -> Data {
        let header = try await receive(exactly: 4)
        let count = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard count <= 1 << 20 else { throw NearbyError.refused("A message of \(count) bytes is too large.") }
        return count == 0 ? Data() : try await receive(exactly: count)
    }

    private func receive(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) {
                data, _, complete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(
                        throwing: complete ? NearbyError.closed : NearbyError.refused("Short read."))
                }
            }
        }
    }

    func send(_ message: NearbyPairing.Message) async throws {
        try await sendFrame(JSONEncoder().encode(message))
    }

    func receive() async throws -> NearbyPairing.Message {
        try JSONDecoder().decode(NearbyPairing.Message.self, from: try await receiveFrame())
    }
}

/// Carries bytes between a ready connection and a pair of file handles: what `sending` yields goes
/// out, what arrives is written to `receiving`; either side ending ends both.
enum StreamBridge {
    static func attach(_ connection: NWConnection, sending: FileHandle, receiving: FileHandle) {
        // Out: a thread reading the pipe, each chunk sent before the next is read.
        let outbound = Thread {
            let sent = DispatchSemaphore(value: 0)
            let failed = Locked(false)
            while true {
                let chunk = sending.availableData
                if chunk.isEmpty {
                    connection.send(
                        content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent
                    )
                    return
                }
                connection.send(
                    content: chunk,
                    completion: .contentProcessed { error in
                        if error != nil { failed.value = true }
                        sent.signal()
                    })
                sent.wait()
                if failed.value { return }
            }
        }
        outbound.start()
        // In: each receive written out before the next is asked for.
        let writer = DispatchQueue(label: "dev.bombcad.nearby.bridge")
        @Sendable func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
                data, _, complete, error in
                writer.async {
                    if let data, !data.isEmpty {
                        do { try receiving.write(contentsOf: data) } catch {
                            connection.cancel()
                            return
                        }
                    }
                    if complete || error != nil {
                        try? receiving.close()
                        connection.cancel()
                    } else {
                        receive()
                    }
                }
            }
        }
        receive()
    }
}

// MARK: - Sharing this Mac

/// This Mac sharing its GPU: a pairing service, which asks `allow` whether a Mac may pair and
/// keeps the pairing, and a session service, TLS with the paired Macs' keys, which starts a worker
/// for each session (`startWorker`: a `BombCAD worker` process by default) after checking any
/// gate the session asks for.
@MainActor
final class NearbyServer {
    /// A worker for a session: reads `input`, writes `output`, and closes `output` when it ends.
    typealias StartWorker =
        @MainActor (_ input: FileHandle, _ output: FileHandle, _ gate: RemoteGate?) throws -> Void

    private let store: PairingStore
    private let name: String
    private let allow: @Sendable (NearbyPairing.Peer, String) async -> Bool
    private let startWorker: StartWorker
    private var pairingListener: NWListener?
    private var sessionListener: NWListener?
    private let queue = DispatchQueue(label: "dev.bombcad.nearby.server")
    /// Told what happens, for a log.
    var log: (String) -> Void = { _ in }
    /// Told when a Mac pairs, for a list on screen.
    var paired: (NearbyPairing.Peer) -> Void = { _ in }

    init(
        store: PairingStore = NearbyWorkers.store, name: String? = nil,
        allow: @escaping @Sendable (NearbyPairing.Peer, String) async -> Bool,
        startWorker: @escaping StartWorker = NearbyServer.workerProcess
    ) {
        self.store = store
        self.name = name ?? store.me.name
        self.allow = allow
        self.startWorker = startWorker
    }

    var isRunning: Bool { pairingListener != nil }

    func start() throws {
        let advert = NearbyWorkers.Advert.mine(store.me.id)
        let pairing = try NWListener(using: NearbyWorkers.pairingParameters())
        pairing.service = NWListener.Service(
            name: name, type: NearbyWorkers.pairingService, txtRecord: advert.record)
        pairing.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.answerPairing(connection) }
        }
        pairing.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor in self?.log("Pairing service failed: \(error)") }
            }
        }
        pairing.start(queue: queue)
        pairingListener = pairing
        try restartSessions()
    }

    func stop() {
        pairingListener?.cancel()
        sessionListener?.cancel()
        pairingListener = nil
        sessionListener = nil
    }

    /// The port `service` listens on, once it is ready.
    func port(of service: String) async throws -> NWEndpoint.Port {
        guard let listener = service == NearbyWorkers.pairingService ? pairingListener : sessionListener
        else {
            throw NearbyError.closed
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            let previous = listener.stateUpdateHandler
            listener.stateUpdateHandler = { state in
                previous?(state)
                switch state {
                case .ready:
                    if once.claim(), let port = listener.port { continuation.resume(returning: port) }
                case .failed(let error): if once.claim() { continuation.resume(throwing: error) }
                case .cancelled: if once.claim() { continuation.resume(throwing: NearbyError.closed) }
                default: break
                }
            }
            // Ready before the handler was set.
            if listener.state == .ready, let port = listener.port, once.claim() {
                continuation.resume(returning: port)
            }
        }
    }

    /// A new session listener with every paired Mac's key; sessions already open carry on.
    func restartSessions() throws {
        var keys = store.pairings().map { ($0.peer.id.uuidString, $0.key) }
        // TLS needs a key to start with: one nobody holds until a Mac pairs.
        if keys.isEmpty { keys = [("none", Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))] }
        let listener = try NWListener(using: NearbyWorkers.sessionParameters(keys: keys))
        listener.service = NWListener.Service(
            name: name, type: NearbyWorkers.sessionService,
            txtRecord: NearbyWorkers.Advert.mine(store.me.id).record)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.serveSession(connection) }
        }
        listener.start(queue: queue)
        sessionListener?.cancel()
        sessionListener = listener
    }

    /// Forgets a paired Mac: its key no longer opens a session.
    func forget(_ id: UUID) throws {
        try store.forget(id)
        try restartSessions()
    }

    private func answerPairing(_ connection: NWConnection) {
        let channel = ConnectionChannel(connection)
        Task { @MainActor in
            defer { connection.cancel() }
            do {
                try await channel.start()
                let pairing = try await NearbyPairing.answer(over: channel, me: store.me, allow: allow)
                try store.keep(pairing)
                try restartSessions()
                log("Paired with \(pairing.peer.name).")
                paired(pairing.peer)
            } catch {
                log("Pairing failed: \(error.localizedDescription)")
            }
        }
    }

    private func serveSession(_ connection: NWConnection) {
        let channel = ConnectionChannel(connection)
        Task { @MainActor in
            do {
                try await channel.start()
                let request = try JSONDecoder().decode(
                    NearbyWorkers.SessionRequest.self, from: try await channel.receiveFrame())
                if let reason = request.gate?.refusal() {
                    try await channel.sendFrame(
                        JSONEncoder().encode(NearbyWorkers.SessionAnswer(accepted: false, reason: reason)))
                    connection.cancel()
                    return
                }
                let toWorker = Pipe()
                let fromWorker = Pipe()
                try startWorker(toWorker.fileHandleForReading, fromWorker.fileHandleForWriting, request.gate)
                try await channel.sendFrame(JSONEncoder().encode(NearbyWorkers.SessionAnswer(accepted: true)))
                StreamBridge.attach(
                    connection, sending: fromWorker.fileHandleForReading,
                    receiving: toWorker.fileHandleForWriting)
                log("Session started.")
            } catch {
                log("Session refused: \(error.localizedDescription)")
                connection.cancel()
            }
        }
    }

    /// A `BombCAD worker` process of this executable, as an SSH session starts one.
    static func workerProcess(_ input: FileHandle, _ output: FileHandle, _ gate: RemoteGate?) throws {
        guard let executable = Bundle.main.executableURL else {
            throw NearbyError.refused("Cannot find BombCAD's own executable.")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["worker"] + (gate.map { ["--gate", $0.argument] } ?? [])
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        // The process holds its own copies; the output's end reaches the session when it exits.
        try? input.close()
        try? output.close()
    }
}
