import CryptoKit
import Foundation
import Security

/// Pairing two Macs for nearby workers (see `NearbyWorkers`): once, over plain TCP, the Mac that
/// will send work (the client) and the Mac that will run it (the server) agree a 256-bit key that
/// their later sessions use for TLS, without a password or SSH.
///
/// Each side makes a fresh X25519 key. The client commits to its public key and nonce (their
/// SHA-256) before seeing the server's, then reveals them, so a Mac in the middle cannot choose its
/// own keys after seeing both to make the two sides' codes agree. Both sides derive the same
/// six-digit code from the shared secret and the whole exchange; the server's user allows it on
/// the server and the client's user confirms on the client that the server shows the same code,
/// so a Mac in the middle, with a different secret on each side, is caught but for one chance in
/// a million. Each side then proves it holds the key (an HMAC over the exchange) before either
/// stores it.
enum NearbyPairing {
    static let codeDigits = 6

    /// A Mac as the other sees it: a lasting identifier and the name it shows.
    struct Peer: Codable, Equatable, Hashable, Sendable {
        var id: UUID
        var name: String
    }

    /// A paired Mac and the key its sessions use.
    struct Pairing: Codable, Equatable, Sendable {
        var peer: Peer
        var key: Data
    }

    enum Message: Codable, Equatable, Sendable {
        /// Client to server: who it is and its commitment.
        case request(Peer, commitment: Data)
        /// Server to client: who it is, its public key and nonce.
        case offer(Peer, publicKey: Data, nonce: Data)
        /// Client to server: its public key and nonce, as committed.
        case reveal(publicKey: Data, nonce: Data)
        /// Either way: its user accepted the code; with the HMAC proving it holds the key.
        case confirm(Data)
        /// Either way: refused, and why.
        case refuse(String)
    }

    /// One side's half of the exchange, and the key and code once both halves are in.
    struct Exchange {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        var publicKey: Data { privateKey.publicKey.rawRepresentation }
        var commitment: Data { Data(SHA256.hash(data: publicKey + nonce)) }

        /// The key and code the exchange comes to, from the client's and server's sides' parts.
        static func derive(
            _ privateKey: Curve25519.KeyAgreement.PrivateKey, other: Data, client: Peer, server: Peer,
            clientKey: Data, clientNonce: Data, serverKey: Data, serverNonce: Data
        ) throws -> (key: SymmetricKey, code: String, transcript: Data) {
            let secret = try privateKey.sharedSecretFromKeyAgreement(
                with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: other))
            var transcript = Data("BombCAD nearby pairing 1".utf8)
            for part in [
                Data(client.id.uuidString.utf8), Data(server.id.uuidString.utf8), clientKey, clientNonce,
                serverKey,
                serverNonce,
            ] {
                var count = UInt32(part.count).bigEndian
                transcript.append(Data(bytes: &count, count: 4))
                transcript.append(part)
            }
            let key = secret.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: transcript, sharedInfo: Data("session key".utf8),
                outputByteCount: 32)
            let codeBytes = secret.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: transcript, sharedInfo: Data("code".utf8), outputByteCount: 8
            ).withUnsafeBytes { Data($0) }
            let number = codeBytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000
            return (key, String(format: "%06llu", number), transcript)
        }

        static func proof(_ key: SymmetricKey, _ role: String, _ transcript: Data) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(role.utf8) + transcript, using: key))
        }

        static func check(_ proof: Data, _ key: SymmetricKey, _ role: String, _ transcript: Data) -> Bool {
            HMAC<SHA256>.isValidAuthenticationCode(
                proof, authenticating: Data(role.utf8) + transcript, using: key)
        }
    }

    /// The client's side: asks `server` to pair; `confirm` is shown the code and returns whether the
    /// server shows the same. Returns the pairing to keep.
    static func pair(
        over channel: PairingChannel, me: Peer, confirm: @escaping @Sendable (Peer, String) async -> Bool
    ) async throws -> Pairing {
        let exchange = Exchange()
        try await channel.send(.request(me, commitment: exchange.commitment))
        guard case .offer(let server, let serverKey, let serverNonce) = try await channel.receive() else {
            throw NearbyError.refused("The other Mac did not offer to pair.")
        }
        try await channel.send(.reveal(publicKey: exchange.publicKey, nonce: exchange.nonce))
        let (key, code, transcript) = try Exchange.derive(
            exchange.privateKey, other: serverKey, client: me, server: server, clientKey: exchange.publicKey,
            clientNonce: exchange.nonce, serverKey: serverKey, serverNonce: serverNonce)
        guard await confirm(server, code) else {
            try? await channel.send(.refuse("The code was not confirmed on \(me.name)."))
            throw NearbyError.refused("Pairing cancelled.")
        }
        try await channel.send(.confirm(Exchange.proof(key, "client", transcript)))
        // Sent once the server's user has allowed it too.
        switch try await channel.receiveAfterCheck() {
        case .confirm(let proof) where Exchange.check(proof, key, "server", transcript):
            return Pairing(peer: server, key: key.withUnsafeBytes { Data($0) })
        case .refuse(let reason): throw NearbyError.refused(reason)
        default: throw NearbyError.refused("\(server.name) did not prove it holds the key.")
        }
    }

    /// The server's side: answers a request to pair; `allow` is shown who asks and the code, and
    /// returns whether this Mac's user allows it. Returns the pairing.
    ///
    /// `keep` is given the pairing before the client is told it holds, so that a session the client
    /// opens straight after finds the key in use.
    static func answer(
        over channel: PairingChannel, me: Peer, allow: @escaping @Sendable (Peer, String) async -> Bool,
        keep: @Sendable (Pairing) async throws -> Void = { _ in }
    ) async throws -> Pairing {
        guard case .request(let client, let commitment) = try await channel.receive() else {
            throw NearbyError.refused("Not a request to pair.")
        }
        let exchange = Exchange()
        try await channel.send(.offer(me, publicKey: exchange.publicKey, nonce: exchange.nonce))
        guard case .reveal(let clientKey, let clientNonce) = try await channel.receive() else {
            throw NearbyError.refused("\(client.name) did not reveal its key.")
        }
        guard Data(SHA256.hash(data: clientKey + clientNonce)) == commitment else {
            try? await channel.send(.refuse("The key revealed is not the one committed to."))
            throw NearbyError.refused("\(client.name) revealed a key other than the one it committed to.")
        }
        let (key, code, transcript) = try Exchange.derive(
            exchange.privateKey, other: clientKey, client: client, server: me, clientKey: clientKey,
            clientNonce: clientNonce, serverKey: exchange.publicKey, serverNonce: exchange.nonce)
        // Both the user here and the client's proof, in either order.
        async let allowed = allow(client, code)
        let reply = try await channel.receiveAfterCheck()
        guard await allowed else {
            try? await channel.send(.refuse("Not allowed on \(me.name)."))
            throw NearbyError.refused("Pairing with \(client.name) not allowed.")
        }
        guard case .confirm(let proof) = reply, Exchange.check(proof, key, "client", transcript) else {
            if case .refuse(let reason) = reply { throw NearbyError.refused(reason) }
            throw NearbyError.refused("\(client.name) did not prove it holds the key.")
        }
        let pairing = Pairing(peer: client, key: key.withUnsafeBytes { Data($0) })
        try await keep(pairing)
        try await channel.send(.confirm(Exchange.proof(key, "server", transcript)))
        return pairing
    }
}

enum NearbyError: LocalizedError, Equatable {
    case refused(String)
    case notFound(String)
    case closed
    /// The other Mac, or the link to it, stopped answering.
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .refused(let reason), .timedOut(let reason): reason
        case .notFound(let name): "\(name) is not on the network, or not sharing its GPU."
        case .closed: "The connection closed."
        }
    }
}

/// Where pairing messages travel: a connection, or a pair of queues in tests.
protocol PairingChannel: Sendable {
    func send(_ message: NearbyPairing.Message) async throws
    func receive() async throws -> NearbyPairing.Message
    /// The next message, which the other Mac sends only once its user has checked the code, so
    /// may take as long as a person does.
    func receiveAfterCheck() async throws -> NearbyPairing.Message
}

extension PairingChannel {
    func receiveAfterCheck() async throws -> NearbyPairing.Message { try await receive() }
}

/// The Macs this one has paired with, and its own lasting identity. Kept in the Keychain, or, for
/// a Mac worked headless over SSH (where the login Keychain is often locked), a file only its owner
/// can read; in memory for tests.
protocol PairingStore: AnyObject, Sendable {
    var me: NearbyPairing.Peer { get }
    func pairings() -> [NearbyPairing.Pairing]
    func keep(_ pairing: NearbyPairing.Pairing) throws
    func forget(_ id: UUID) throws
}

extension PairingStore {
    func pairing(_ id: UUID) -> NearbyPairing.Pairing? { pairings().first { $0.peer.id == id } }
    func pairing(named name: String) -> NearbyPairing.Pairing? { pairings().first { $0.peer.name == name } }
}

/// This Mac's name as other Macs show it.
func nearbyMachineName() -> String {
    Host.current().localizedName ?? ProcessInfo.processInfo.hostName
}

final class MemoryPairingStore: PairingStore, @unchecked Sendable {
    let me: NearbyPairing.Peer
    private let lock = NSLock()
    private var kept: [UUID: NearbyPairing.Pairing] = [:]

    init(name: String = "Test Mac", id: UUID = UUID()) { me = .init(id: id, name: name) }

    func pairings() -> [NearbyPairing.Pairing] {
        lock.withLock { kept.values.sorted { $0.peer.name < $1.peer.name } }
    }
    func keep(_ pairing: NearbyPairing.Pairing) throws { lock.withLock { kept[pairing.peer.id] = pairing } }
    func forget(_ id: UUID) throws { _ = lock.withLock { kept.removeValue(forKey: id) } }
}

/// A JSON file of this Mac's identity and pairings, readable by its owner alone.
final class FilePairingStore: PairingStore, @unchecked Sendable {
    private struct Contents: Codable {
        var me: NearbyPairing.Peer
        var pairings: [NearbyPairing.Pairing] = []
    }

    private let url: URL
    private let lock = NSLock()
    private var contents: Contents
    var me: NearbyPairing.Peer { lock.withLock { contents.me } }

    init(url: URL, name: String = nearbyMachineName()) throws {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            contents = try JSONDecoder().decode(Contents.self, from: data)
            contents.me.name = name
        } else {
            contents = Contents(me: .init(id: UUID(), name: name))
            try save()
        }
    }

    func pairings() -> [NearbyPairing.Pairing] { lock.withLock { contents.pairings } }

    func keep(_ pairing: NearbyPairing.Pairing) throws {
        try lock.withLock {
            contents.pairings.removeAll { $0.peer.id == pairing.peer.id }
            contents.pairings.append(pairing)
            try save()
        }
    }

    func forget(_ id: UUID) throws {
        try lock.withLock {
            contents.pairings.removeAll { $0.peer.id == id }
            try save()
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(contents)
        // Not `.completeFileProtection`: a locked Mac refuses to create files in that class, and a
        // worker is usually locked while it serves.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// This Mac's identity in the user's defaults and each pairing's key in the login Keychain, as a
/// generic password under the service `dev.bombcad.nearby`, its account the other Mac's
/// identifier.
final class KeychainPairingStore: PairingStore, @unchecked Sendable {
    private static let service = "dev.bombcad.nearby"
    private static let identityKey = "nearby.identity"
    private static let peersKey = "nearby.pairedPeers"
    private let defaults: UserDefaults
    let me: NearbyPairing.Peer

    init(defaults: UserDefaults = .standard, name: String = nearbyMachineName()) {
        self.defaults = defaults
        if let text = defaults.string(forKey: Self.identityKey), let id = UUID(uuidString: text) {
            me = .init(id: id, name: name)
        } else {
            let id = UUID()
            defaults.set(id.uuidString, forKey: Self.identityKey)
            me = .init(id: id, name: name)
        }
    }

    private var peers: [NearbyPairing.Peer] {
        get {
            (defaults.data(forKey: Self.peersKey)).flatMap {
                try? JSONDecoder().decode([NearbyPairing.Peer].self, from: $0)
            } ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.peersKey) }
    }

    func pairings() -> [NearbyPairing.Pairing] {
        peers.compactMap { peer in
            var item: CFTypeRef?
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                kSecAttrAccount as String: peer.id.uuidString, kSecReturnData as String: true,
            ]
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let key = item as? Data
            else { return nil }
            return .init(peer: peer, key: key)
        }
    }

    func keep(_ pairing: NearbyPairing.Pairing) throws {
        try? forget(pairing.peer.id)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
            kSecAttrAccount as String: pairing.peer.id.uuidString,
            kSecAttrLabel as String: "BombCAD: \(pairing.peer.name)",
            kSecValueData as String: pairing.key,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NearbyError.refused("The pairing could not be kept in the Keychain (\(status)).")
        }
        peers = peers.filter { $0.id != pairing.peer.id } + [pairing.peer]
    }

    func forget(_ id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
        peers = peers.filter { $0.id != id }
    }
}
