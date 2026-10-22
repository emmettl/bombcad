import CryptoKit
import Darwin
import Foundation
import Network

/// A nearby session's messages on a plain socket beside its TLS session (emmettl/bombcad-work#29):
/// Network.framework carried only 4 to 13 MB/s over Wi-Fi to and from the mini, where the kernel's
/// sockets carried 34 to 43 MB/s on the same link, so once a session is set up its worker's messages
/// (the project, frames, the result) go on a TCP socket of its own, and the TLS session carries only
/// the setup: the request and its gate, the answer, and the socket's port and nonces.
///
/// The socket is sealed with keys derived from the pairing: HKDF-SHA256 over the pairing's key,
/// salted with both Macs' identifiers and a fresh 32-byte nonce from each side, exchanged inside the
/// TLS session, gives one AES-256-GCM key each way. Each record is the sealed bytes' length, then
/// the bytes and their tag, the length authenticated with them; its nonce is the record's number
/// that way (never sent), so a record replayed, dropped or reordered fails to open. An empty record
/// ends the stream, so that a connection cut short is told from one finished. The first record each
/// way is a fixed greeting, which proves the other side holds the key before anything else is
/// taken: a stranger connecting to the port first is closed and the wait goes on.
///
/// If the socket cannot be opened (no listener, a firewall, a link it cannot cross), the session
/// falls back to the TLS connection, as before; `BOMBCAD_NEARBY_BULK=off` asks for that, to measure.
enum NearbyBulk {
    static let nonceBytes = 32
    static let tagBytes = 16
    /// Plain bytes in a record at most: frames go as several.
    static let recordBytes = 1 << 20
    static let clientGreeting = Data("BombCAD nearby bulk 1: client".utf8)
    static let serverGreeting = Data("BombCAD nearby bulk 1: server".utf8)

    /// What a session's request offers: the client's nonce, and who it is (the pairing to key by).
    struct Offer: Codable, Equatable, Sendable {
        var client: UUID
        var nonce: Data
    }

    /// What the sharing Mac answers: the port it listens on for this session, and its nonce.
    struct Grant: Codable, Equatable, Sendable {
        var port: UInt16
        var nonce: Data
    }

    /// The client's word, on the TLS session, on whether the socket opened.
    struct Choice: Codable, Equatable, Sendable {
        var socket: Bool
        var reason: String?
    }

    /// One key each way.
    struct Keys: Sendable {
        var clientToServer: SymmetricKey
        var serverToClient: SymmetricKey
    }

    static func nonce() -> Data { Data((0..<nonceBytes).map { _ in UInt8.random(in: .min ... .max) }) }

    static func keys(pairingKey: Data, client: UUID, server: UUID, clientNonce: Data, serverNonce: Data)
        -> Keys
    {
        var salt = Data("BombCAD nearby bulk 1".utf8)
        for part in [Data(client.uuidString.utf8), Data(server.uuidString.utf8), clientNonce, serverNonce] {
            var count = UInt32(part.count).bigEndian
            salt.append(Data(bytes: &count, count: 4))
            salt.append(part)
        }
        let material = SymmetricKey(data: pairingKey)
        func key(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(
                inputKeyMaterial: material, salt: salt, info: Data(info.utf8), outputByteCount: 32)
        }
        return Keys(clientToServer: key("client to server"), serverToClient: key("server to client"))
    }

    /// Whether this Mac offers the socket: unless `BOMBCAD_NEARBY_BULK=off`.
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["BOMBCAD_NEARBY_BULK"]?.lowercased() != "off"
    }

    // MARK: - The client's side

    /// Opens the session's socket to `host` (the TLS session's other end) at the port granted, over
    /// `interface` if given, and checks the sharing Mac's greeting; waits up to `limit` (nil:
    /// however long it takes) to connect and for the greeting.
    static func open(
        to host: NWEndpoint.Host, port: UInt16, interface: NWInterface?, keys: Keys, limit: Duration?
    ) async throws -> SealedSocket {
        try await Task.detached {
            let fd = try Socket.connect(to: host, port: port, interface: interface, limit: limit)
            let socket = SealedSocket(fd, sending: keys.clientToServer, receiving: keys.serverToClient)
            do {
                try socket.setReceiveLimit(limit)
                try socket.send(clientGreeting)
                guard try socket.receive() == serverGreeting else {
                    throw NearbyError.refused("The sharing Mac's socket did not greet.")
                }
                try socket.setReceiveLimit(nil)
                return socket
            } catch {
                socket.shutdown()
                throw error
            }
        }.value
    }
}

/// A TCP connection's bytes sealed record by record (see `NearbyBulk`). `send` and `receive` block;
/// each may be called from one thread at a time, the two from different threads.
final class SealedSocket: @unchecked Sendable {
    let descriptor: Int32
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let sendLock = NSLock()
    private let receiveLock = NSLock()
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private var ended = false
    private let closing = OnceFlag()

    init(_ descriptor: Int32, sending: SymmetricKey, receiving: SymmetricKey) {
        self.descriptor = descriptor
        sendKey = sending
        receiveKey = receiving
    }

    deinit { Darwin.close(descriptor) }

    private static func nonce(_ number: UInt64) throws -> AES.GCM.Nonce {
        var big = number.bigEndian
        return try AES.GCM.Nonce(data: Data(count: 4) + Data(bytes: &big, count: 8))
    }

    /// Sends `data`, in records of at most `NearbyBulk.recordBytes`; nothing for no bytes.
    func send(_ data: Data) throws {
        try sendLock.withLock {
            var offset = data.startIndex
            while offset < data.endIndex {
                let end = min(offset + NearbyBulk.recordBytes, data.endIndex)
                try seal(data[offset..<end])
                offset = end
            }
        }
    }

    /// Ends the stream: the empty record, then this side's half of the connection.
    func sendEnd() throws {
        try sendLock.withLock {
            try seal(Data())
            Darwin.shutdown(descriptor, SHUT_WR)
        }
    }

    private func seal(_ plain: Data) throws {
        var length = UInt32(plain.count + NearbyBulk.tagBytes).bigEndian
        let header = Data(bytes: &length, count: 4)
        let box = try AES.GCM.seal(plain, using: sendKey, nonce: Self.nonce(sent), authenticating: header)
        sent += 1
        try Socket.write(descriptor, header + box.ciphertext + box.tag)
    }

    /// The next record's bytes, or nil once the stream has ended as it should; throws if it was
    /// cut short or a record does not open.
    func receive() throws -> Data? {
        try receiveLock.withLock {
            if ended { return nil }
            guard let header = try Socket.read(descriptor, exactly: 4) else {
                throw NearbyError.refused("The socket closed without ending its stream.")
            }
            let count = Int(header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard count >= NearbyBulk.tagBytes, count <= NearbyBulk.recordBytes + NearbyBulk.tagBytes else {
                throw NearbyError.refused("A sealed record of \(count) bytes cannot be right.")
            }
            guard let body = try Socket.read(descriptor, exactly: count) else {
                throw NearbyError.refused("A sealed record was cut short.")
            }
            let split = body.startIndex + count - NearbyBulk.tagBytes
            let box = try AES.GCM.SealedBox(
                nonce: Self.nonce(received), ciphertext: body[body.startIndex..<split], tag: body[split...])
            let plain: Data
            do {
                plain = try AES.GCM.open(box, using: receiveKey, authenticating: header)
            } catch {
                throw NearbyError.refused(
                    "A sealed record did not open: not from the paired Mac, or changed.")
            }
            received += 1
            if plain.isEmpty {
                ended = true
                return nil
            }
            return plain
        }
    }

    /// Gives up waiting for a record after `limit` (nil: waits however long it takes).
    func setReceiveLimit(_ limit: Duration?) throws {
        var time = timeval()
        if let limit {
            let (seconds, attoseconds) = limit.components
            time.tv_sec = Int(seconds)
            time.tv_usec = Int32(attoseconds / 1_000_000_000_000)
        }
        guard
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size)) == 0
        else { throw Socket.error("set a receive limit") }
    }

    /// Ends the connection both ways, waking a thread waiting in `send` or `receive`.
    func shutdown() {
        guard closing.claim() else { return }
        Darwin.shutdown(descriptor, SHUT_RDWR)
    }
}

/// The sharing Mac's listening socket for one session, which takes the first connection to greet
/// with the session's key.
final class BulkListener: @unchecked Sendable {
    private let descriptor: Int32
    let port: UInt16
    private let cancelled = Locked(false)

    /// Listens on `local`, the address the session's TLS connection came in on (any address if
    /// nil), on a port of its own.
    init(on local: NWEndpoint.Host?) throws {
        (descriptor, port) = try Socket.listen(on: local)
    }

    deinit { Darwin.close(descriptor) }

    /// Stops listening: `accept` throws.
    func cancel() { cancelled.value = true }

    /// The first connection that greets with `keys`' client key, its greeting answered; one that
    /// does not is closed. Each connection is heard on a thread of its own, so that one that never
    /// speaks holds up no other, and has `limit` (a minute if nil) to greet; the wait itself ends
    /// only with `cancel`.
    func accept(keys: NearbyBulk.Keys, limit: Duration?) async throws -> SealedSocket {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            Thread { [self] in
                while !cancelled.value {
                    var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    guard poll(&poller, 1, 100) > 0 else { continue }
                    let fd = Darwin.accept(descriptor, nil, nil)
                    guard fd >= 0 else { continue }
                    Socket.prepare(fd)
                    Thread {
                        let socket = SealedSocket(
                            fd, sending: keys.serverToClient, receiving: keys.clientToServer)
                        do {
                            try socket.setReceiveLimit(limit ?? .seconds(60))
                            guard try socket.receive() == NearbyBulk.clientGreeting else {
                                throw NearbyError.refused("Not the session's greeting.")
                            }
                            try socket.setReceiveLimit(nil)
                            guard once.claim() else { throw NearbyError.closed }
                            self.cancel()
                            do {
                                try socket.send(NearbyBulk.serverGreeting)
                                continuation.resume(returning: socket)
                            } catch {
                                socket.shutdown()
                                continuation.resume(throwing: error)
                            }
                        } catch {
                            // Not the session's client (someone else, or a stray connection), or
                            // after it.
                            socket.shutdown()
                        }
                    }.start()
                }
                if once.claim() { continuation.resume(throwing: NearbyError.closed) }
            }.start()
        }
    }
}

/// Plain BSD sockets, as Network.framework's are slow over Wi-Fi from the mini.
enum Socket {
    static func error(_ what: String) -> NearbyError {
        NearbyError.refused("Could not \(what): \(String(cString: strerror(errno))).")
    }

    /// No SIGPIPE for writing to a connection the other side closed, and no Nagle delay.
    static func prepare(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func place<Address>(_ address: Address, in storage: inout sockaddr_storage) {
        withUnsafeMutableBytes(of: &storage) { target in
            withUnsafeBytes(of: address) { target.copyMemory(from: $0) }
        }
    }

    /// `host` and `port` as a socket address.
    static func address(_ host: NWEndpoint.Host?, port: UInt16) throws -> (sockaddr_storage, socklen_t) {
        var storage = sockaddr_storage()
        switch host {
        case .ipv4(let address):
            var socket = sockaddr_in()
            socket.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            socket.sin_family = sa_family_t(AF_INET)
            socket.sin_port = port.bigEndian
            withUnsafeMutableBytes(of: &socket.sin_addr) { $0.copyBytes(from: address.rawValue) }
            place(socket, in: &storage)
            return (storage, socklen_t(MemoryLayout<sockaddr_in>.size))
        case .ipv6(let address):
            var socket = sockaddr_in6()
            socket.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            socket.sin6_family = sa_family_t(AF_INET6)
            socket.sin6_port = port.bigEndian
            withUnsafeMutableBytes(of: &socket.sin6_addr) { $0.copyBytes(from: address.rawValue) }
            socket.sin6_scope_id = address.interface.map { if_nametoindex($0.name) } ?? 0
            place(socket, in: &storage)
            return (storage, socklen_t(MemoryLayout<sockaddr_in6>.size))
        case .name(let name, _):
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            hints.ai_flags = AI_NUMERICSERV
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(name, String(port), &hints, &list) == 0, let first = list,
                let found = first.pointee.ai_addr
            else {
                throw NearbyError.refused("Could not find the address of \(name).")
            }
            defer { freeaddrinfo(list) }
            let length = first.pointee.ai_addrlen
            withUnsafeMutableBytes(of: &storage) {
                $0.copyMemory(from: UnsafeRawBufferPointer(start: found, count: Int(length)))
            }
            return (storage, length)
        case nil:
            var socket = sockaddr_in6()
            socket.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            socket.sin6_family = sa_family_t(AF_INET6)
            socket.sin6_port = port.bigEndian
            socket.sin6_addr = in6addr_any
            place(socket, in: &storage)
            return (storage, socklen_t(MemoryLayout<sockaddr_in6>.size))
        @unknown default:
            throw NearbyError.refused("Cannot reach that kind of address.")
        }
    }

    /// A listening socket on `host` (any address, IPv4 and IPv6, if nil), and its port.
    static func listen(on host: NWEndpoint.Host?) throws -> (Int32, UInt16) {
        var (storage, length) = try address(host, port: 0)
        let fd = Darwin.socket(Int32(storage.ss_family), SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw error("open a socket") }
        var on: Int32 = 1
        var off: Int32 = 0
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        if storage.ss_family == sa_family_t(AF_INET6), host == nil {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        }
        let bound = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            let failure = error("listen for a session's socket")
            Darwin.close(fd)
            throw failure
        }
        var local = sockaddr_storage()
        var localLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &localLength) }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw error("find a socket's port")
        }
        let port = withUnsafeBytes(of: local) { raw -> UInt16 in
            // The port sits at the same offset in IPv4's and IPv6's addresses.
            UInt16(bigEndian: raw.load(fromByteOffset: 2, as: UInt16.self))
        }
        return (fd, port)
    }

    /// A connected socket to `host` at `port`, over `interface` if given, within `limit`.
    static func connect(to host: NWEndpoint.Host, port: UInt16, interface: NWInterface?, limit: Duration?)
        throws -> Int32
    {
        var (storage, length) = try address(host, port: port)
        let fd = Darwin.socket(Int32(storage.ss_family), SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw error("open a socket") }
        prepare(fd)
        if let interface, interface.type != .loopback {
            // The link the TLS session took, not whichever the routing table prefers.
            var index = if_nametoindex(interface.name)
            if index != 0 {
                if storage.ss_family == sa_family_t(AF_INET6) {
                    setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
                } else {
                    setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
                }
            }
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let started = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        if started != 0 {
            guard errno == EINPROGRESS else {
                let failure = error("connect to the sharing Mac's socket")
                Darwin.close(fd)
                throw failure
            }
            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let milliseconds =
                limit.map { limit -> Int32 in
                    let (seconds, attoseconds) = limit.components
                    return Int32(clamping: seconds * 1000 + attoseconds / 1_000_000_000_000_000)
                } ?? -1
            var ready: Int32
            repeat { ready = poll(&poller, 1, milliseconds) } while ready < 0 && errno == EINTR
            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size)
            guard ready > 0, failure == 0 else {
                Darwin.close(fd)
                if ready == 0 { throw NearbyError.timedOut("The sharing Mac's socket did not answer.") }
                errno = failure
                throw error("connect to the sharing Mac's socket")
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }

    static func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw error("send on the session's socket")
                }
                offset += written
            }
        }
    }

    /// Exactly `count` bytes, or nil if the connection ends before any.
    static func read(_ fd: Int32, exactly count: Int) throws -> Data? {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            while offset < count {
                let got = Darwin.read(fd, raw.baseAddress! + offset, count - offset)
                if got < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN { throw NearbyError.timedOut("The session's socket went quiet.") }
                    throw error("receive on the session's socket")
                }
                if got == 0 {
                    if offset == 0 { return }
                    throw NearbyError.refused("The session's socket closed part-way through a record.")
                }
                offset += got
            }
        }
        return offset == 0 && count > 0 ? nil : data
    }
}

/// Carries bytes between a sealed socket and a pair of file handles, as `StreamBridge` does for a
/// connection: what `sending` yields goes out, what arrives is written to `receiving`; either side
/// ending ends both.
enum SealedBridge {
    static func attach(_ socket: SealedSocket, sending: FileHandle, receiving: FileHandle) {
        Thread {
            while true {
                let chunk = sending.availableData
                if chunk.isEmpty {
                    try? socket.sendEnd()
                    return
                }
                do { try socket.send(chunk) } catch {
                    socket.shutdown()
                    return
                }
            }
        }.start()
        Thread {
            while true {
                do {
                    guard let data = try socket.receive() else { break }
                    try receiving.write(contentsOf: data)
                } catch {
                    break
                }
            }
            try? receiving.close()
            socket.shutdown()
        }.start()
    }
}
