import CryptoKit
import Darwin
import Foundation
import Network
import Testing

@testable import BombCAD

/// A nearby session's messages on a sealed socket beside its TLS connection
/// (emmettl/bombcad-work#29): the records, the listener, and sessions that use the socket or fall
/// back to the connection. Sharing Macs are in this process, found at their ports, never by
/// Bonjour; nothing waits on a clock.
@Suite("Nearby sessions' sealed sockets", .serialized, .hangLimit)
struct NearbyBulkTests {
    private let keys = NearbyBulk.keys(
        pairingKey: Data(repeating: 3, count: 32), client: UUID(), server: UUID(),
        clientNonce: NearbyBulk.nonce(),
        serverNonce: NearbyBulk.nonce())

    /// Two connected sockets in this process.
    private func pair() throws -> (Int32, Int32) {
        var ends: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else { throw NearbyError.closed }
        for end in ends { Socket.prepare(end) }
        return (ends[0], ends[1])
    }

    /// A client's end and a sharing Mac's end, sealed with `keys`.
    private func sealed() throws -> (client: SealedSocket, server: SealedSocket) {
        let (a, b) = try pair()
        return (
            SealedSocket(a, sending: keys.clientToServer, receiving: keys.serverToClient),
            SealedSocket(b, sending: keys.serverToClient, receiving: keys.clientToServer)
        )
    }

    @Test("Bytes sealed one way open the other, in records, and an ended stream is told from a cut one")
    func roundTrip() async throws {
        let (client, server) = try sealed()
        var bytes = Data(count: 3 * NearbyBulk.recordBytes + 17)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let message = bytes
        // Written on a thread of its own: the socket's buffer holds less than the message.
        let sending = Task.detached {
            try client.send(message)
            try client.sendEnd()
        }
        var received = Data()
        while let chunk = try server.receive() { received.append(chunk) }
        try await sending.value
        #expect(received == message)
        #expect(try server.receive() == nil)

        // Shut without the end record: an error, not the end.
        let (cut, end) = try sealed()
        try cut.send(Data("partial".utf8))
        cut.shutdown()
        #expect(try end.receive() == Data("partial".utf8))
        #expect(throws: NearbyError.self) { _ = try end.receive() }
    }

    /// The raw records `body` writes on a sealed socket, as they cross the wire.
    private func wire(_ body: (SealedSocket) throws -> Void) throws -> Data {
        let (a, b) = try pair()
        let sender = SealedSocket(a, sending: keys.clientToServer, receiving: keys.serverToClient)
        try body(sender)
        sender.shutdown()
        var bytes = Data()
        while let chunk = try Socket.read(b, exactly: 1) { bytes.append(chunk) }
        Darwin.close(b)
        return bytes
    }

    /// What the sharing Mac's end makes of `bytes` arriving, record by record.
    private func opened(_ bytes: Data, receiving key: SymmetricKey? = nil) throws -> [Data] {
        let (a, b) = try pair()
        let receiver = SealedSocket(
            b, sending: keys.serverToClient, receiving: key ?? keys.clientToServer)
        try Socket.write(a, bytes)
        Darwin.shutdown(a, SHUT_WR)
        defer { Darwin.close(a) }
        var records: [Data] = []
        while let record = try receiver.receive() { records.append(record) }
        return records
    }

    @Test("A record changed, replayed, reordered or sealed with another key does not open")
    func tampering() throws {
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        let both = try wire { socket in
            try socket.send(first)
            try socket.send(second)
            try socket.sendEnd()
        }
        #expect(try opened(both) == [first, second])
        // Each record: a 4-byte length, the sealed bytes, the tag.
        let one = 4 + first.count + NearbyBulk.tagBytes
        let two = 4 + second.count + NearbyBulk.tagBytes
        let firstRecord = both.prefix(one)
        let secondRecord = both.dropFirst(one).prefix(two)
        let endRecord = both.dropFirst(one + two)

        var changed = both
        changed[changed.startIndex + 6] ^= 1
        #expect(throws: NearbyError.self) { _ = try opened(changed) }
        // The first record again where the second should be.
        #expect(throws: NearbyError.self) { _ = try opened(firstRecord + firstRecord + endRecord) }
        // The two the other way round.
        #expect(throws: NearbyError.self) { _ = try opened(secondRecord + firstRecord + endRecord) }
        // The first dropped.
        #expect(throws: NearbyError.self) { _ = try opened(secondRecord + endRecord) }
        // The end cut off.
        #expect(throws: NearbyError.self) { _ = try opened(firstRecord + secondRecord) }
        // Another pairing's key, or the other direction's.
        #expect(throws: NearbyError.self) { _ = try opened(both, receiving: SymmetricKey(size: .bits256)) }
        #expect(throws: NearbyError.self) { _ = try opened(both, receiving: keys.serverToClient) }
    }

    @Test("Keys differ by pairing, by nonce and by direction")
    func keyDerivation() {
        let client = UUID()
        let server = UUID()
        let (one, two) = (NearbyBulk.nonce(), NearbyBulk.nonce())
        func raw(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
        let a = NearbyBulk.keys(
            pairingKey: Data(repeating: 1, count: 32), client: client, server: server, clientNonce: one,
            serverNonce: two)
        let same = NearbyBulk.keys(
            pairingKey: Data(repeating: 1, count: 32), client: client, server: server, clientNonce: one,
            serverNonce: two)
        let otherPairing = NearbyBulk.keys(
            pairingKey: Data(repeating: 2, count: 32), client: client, server: server, clientNonce: one,
            serverNonce: two)
        let otherSession = NearbyBulk.keys(
            pairingKey: Data(repeating: 1, count: 32), client: client, server: server, clientNonce: two,
            serverNonce: one)
        #expect(raw(a.clientToServer) == raw(same.clientToServer))
        #expect(raw(a.clientToServer) != raw(a.serverToClient))
        #expect(raw(a.clientToServer) != raw(otherPairing.clientToServer))
        #expect(raw(a.clientToServer) != raw(otherSession.clientToServer))
    }

    @Test("The listener closes strangers and takes the session's client, however they come")
    func listener() async throws {
        let listener = try BulkListener(on: .ipv4(.loopback))
        defer { listener.cancel() }
        let accepting = Task { try await listener.accept(keys: keys, limit: nil) }
        // One that connects and never speaks, one that sends rubbish, and one with another key.
        let silent = try Socket.connect(to: .ipv4(.loopback), port: listener.port, interface: nil, limit: nil)
        defer { Darwin.close(silent) }
        let rubbish = try Socket.connect(
            to: .ipv4(.loopback), port: listener.port, interface: nil, limit: nil)
        try Socket.write(rubbish, Data([0, 0, 0, 20]) + Data(repeating: 0xAB, count: 20))
        let other = NearbyBulk.keys(
            pairingKey: Data(repeating: 4, count: 32), client: UUID(), server: UUID(),
            clientNonce: NearbyBulk.nonce(),
            serverNonce: NearbyBulk.nonce())
        await #expect(throws: (any Error).self) {
            _ = try await NearbyBulk.open(
                to: .ipv4(.loopback), port: listener.port, interface: nil, keys: other, limit: nil)
        }
        // The rubbish was closed, not answered.
        #expect(try Socket.read(rubbish, exactly: 1) == nil)
        Darwin.close(rubbish)
        // The client, past the silent one.
        let client = try await NearbyBulk.open(
            to: .ipv4(.loopback), port: listener.port, interface: nil, keys: keys, limit: nil)
        let server = try await accepting.value
        try client.send(Data("frame".utf8))
        #expect(try server.receive() == Data("frame".utf8))
        try server.send(Data("ack".utf8))
        #expect(try client.receive() == Data("ack".utf8))
    }

    // MARK: - Sessions

    /// A sharing Mac in this process, its sessions' workers in-process, and a Mac paired with it.
    @MainActor private struct Sharing {
        let server: NearbyServer
        let serverStore = MemoryPairingStore(name: "Bulk server \(UUID().uuidString.prefix(8))")
        let clientStore = MemoryPairingStore(name: "Bulk client")

        init() throws {
            let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            try clientStore.keep(.init(peer: serverStore.me, key: key))
            try serverStore.keep(.init(peer: clientStore.me, key: key))
            server = NearbyServer(store: serverStore) { _, _ in
                false
            } startWorker: { input, output, _ in
                Task { @MainActor in
                    await SweepWorker.serve(input: input, output: output)
                    try? output.close()
                }
            }
            server.limits = .none
            try server.start()
        }

        func connect(_ transport: NearbyWorkers.Transport) async throws -> SweepWorkerClient {
            let server = server
            let store = serverStore
            return try await NearbyWorkers.connect(
                host: NearbyWorkers.host(serverStore.me.name), store: clientStore, discovery: .seconds(600),
                resolve: { id, service, _ in
                    let port = try await server.port(of: service)
                    return NearbyBrowser.Found(
                        name: store.me.name, advert: .mine(id),
                        endpoint: .hostPort(host: "127.0.0.1", port: port),
                        interfaces: [])
                }, limits: .none, transport: transport)
        }
    }

    /// A probe each way crosses the session whole.
    @MainActor private func probe(_ client: SweepWorkerClient) async throws {
        _ = try await client.probe(sending: 3_000_000, receiving: 0)
        _ = try await client.probe(sending: 0, receiving: 3_000_000)
        #expect(!client.isClosed)
    }

    @Test("A session's messages go on its sealed socket, and as before on its connection if asked")
    @MainActor func sessions() async throws {
        let sharing = try Sharing()
        defer { sharing.server.stop() }
        let sealed = try await sharing.connect(.automatic)
        #expect(sealed.transport == "a sealed socket")
        try await probe(sealed)
        sealed.close()
        let plain = try await sharing.connect(.connection)
        #expect(plain.transport == "the TLS connection")
        try await probe(plain)
        plain.close()
        while sharing.server.sessionCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("A socket that cannot be opened, on either Mac, leaves the session on its connection")
    @MainActor func fallBack() async throws {
        let sharing = try Sharing()
        defer { sharing.server.stop() }
        // The client's side fails to open it.
        let failed = try await sharing.connect(.failingSocket)
        #expect(failed.transport.hasPrefix("the TLS connection (the socket failed"))
        try await probe(failed)
        failed.close()
        // The sharing Mac offers none.
        sharing.server.socketsAllowed = false
        let refused = try await sharing.connect(.automatic)
        #expect(refused.transport == "the TLS connection")
        try await probe(refused)
        refused.close()
        while sharing.server.sessionCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
    }
}
