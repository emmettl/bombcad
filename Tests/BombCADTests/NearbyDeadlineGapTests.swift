import Foundation
import Network
import Testing

@testable import BombCAD

/// A Mac on this one's loopback that takes connections and never reads from them; with `saying`,
/// it sends those bytes first and then falls silent.
private final class SilentMac: @unchecked Sendable {
    let listener: NWListener
    let endpoint: NWEndpoint
    private let held: Locked<[NWConnection]>

    init(saying first: Data? = nil) async throws {
        let listener = try NWListener(using: NearbyWorkers.pairingParameters())
        let held = Locked<[NWConnection]>([])
        let queue = DispatchQueue(label: "dev.bombcad.tests.silent-mac")
        listener.newConnectionHandler = { connection in
            held.update { $0.append(connection) }
            connection.start(queue: queue)
            if let first { connection.send(content: first, completion: .idempotent) }
        }
        let port = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<NWEndpoint.Port, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port, once.claim() { continuation.resume(returning: port) }
                case .failed(let error): if once.claim() { continuation.resume(throwing: error) }
                case .cancelled: if once.claim() { continuation.resume(throwing: NearbyError.closed) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        self.held = held
        endpoint = .hostPort(host: "127.0.0.1", port: port)
    }

    func stop() {
        listener.cancel()
        for connection in held.value { connection.cancel() }
    }
}

/// The reason `body` gave up for, when it failed with `NearbyError.timedOut`, and how long it took
/// (which only a deadline's never coming early bounds: a loaded Mac can take any time longer); any
/// other outcome is recorded as an issue and gives no reason.
private func timedOut(_ body: () async throws -> Void) async -> (reason: String?, took: Duration) {
    let start = ContinuousClock.now
    do {
        try await body()
        Issue.record("Finished without timing out.")
    } catch let error as NearbyError {
        if case .timedOut(let reason) = error {
            // What the user is shown is the reason itself.
            #expect(error.localizedDescription == reason)
            return (reason, ContinuousClock.now - start)
        }
        Issue.record("Failed otherwise: \(error)")
    } catch {
        Issue.record("Failed otherwise: \(error)")
    }
    return (nil, ContinuousClock.now - start)
}

/// The deadlines `ConnectionChannel` puts on each step of a connection to another Mac (commit
/// 038932f), on the paths `NearbyWorkerTests.stalls` leaves out. That test checks only that a
/// stalled handshake and a silent receive fail with `NearbyError.timedOut`; these check that the
/// error names the Mac, that a stalled send runs out too, that a step finished in time leaves no
/// timer behind to drop the connection later, that an error before the deadline is passed on as it
/// is, and that the pairing waits on the code check through the step that has the long deadline.
/// Each shortens the deadline through the `within:` argument the steps take, or the channel's
/// `limits`, so each takes seconds. None bounds how long a step takes past its deadline, nor needs
/// a step to finish within one: under a full parallel run a whole test process can stall for a
/// minute; a deadline that never comes is the hang limit's to catch.
@Suite("Nearby connection deadlines not otherwise reached", .hangLimit)
struct NearbyDeadlineGapTests {
    /// The limits as the app ships them, and as its messages say them. `stalls` passes its own
    /// limit of one second to every step, so nothing else looks at these values; a slip to
    /// milliseconds or hours would pass every other test.
    @Test("The deadlines are a minute to connect, a minute a message and 5 minutes for a code check")
    func limits() {
        #expect(NearbyWorkers.connectLimit == .seconds(60))
        #expect(NearbyWorkers.messageLimit == .seconds(60))
        #expect(NearbyWorkers.checkLimit == .seconds(300))
        // The wording follows the test process's locale (here "1 minute" and "5 minutes"), so only
        // the numbers are checked, and that the minutes are said in minutes, not as seconds.
        let minute = ConnectionChannel.describe(NearbyWorkers.connectLimit)
        #expect(minute.contains("1") && !minute.contains("60"), "\(minute)")
        #expect(ConnectionChannel.describe(NearbyWorkers.messageLimit) == minute)
        let check = ConnectionChannel.describe(NearbyWorkers.checkLimit)
        #expect(check.contains("5") && !check.contains("300"))
        // A channel takes these unless given others (as the tests give `.none`).
        #expect(
            NearbyWorkers.Limits.app
                == .init(
                    connect: .seconds(60), message: .seconds(60), check: .seconds(300), hello: .seconds(60)))
        #expect(NearbyWorkers.Limits.none == .init(connect: nil, message: nil, check: nil, hello: nil))
    }

    /// A TLS handshake the other Mac never answers runs out with `NearbyError.timedOut` naming the
    /// Mac the channel was made for, and the connection is cancelled rather than left open.
    /// `stalls` reaches this step but checks only the error's case, not its name nor the
    /// connection's state.
    @Test("A handshake that stalls fails naming the Mac, and the connection is dropped")
    func handshakeNamesTheMac() async throws {
        let silent = try await SilentMac()
        defer { silent.stop() }
        let channel = ConnectionChannel(
            NWConnection(
                to: silent.endpoint,
                using: NearbyWorkers.sessionParameters(keys: [("nobody", Data(repeating: 7, count: 32))])),
            peer: "Silent Studio")
        defer { channel.connection.cancel() }
        let limit = Duration.seconds(1)
        let (reason, took) = await timedOut { try await channel.start(within: limit) }
        let said = try #require(reason)
        #expect(said.contains("Silent Studio") && said.contains("connecting"))
        // Never before the limit (1.07 s on the Studio on 19 October 2026, but a loaded Mac can
        // take any time longer).
        #expect(took >= limit)
        // The channel's own wait ends on the connection's cancellation, so it is cancelled by now.
        if case .cancelled = channel.connection.state {
        } else {
            Issue.record("The stalled connection was left \(channel.connection.state).")
        }
    }

    /// A connection that opens and then hears nothing runs out on the next frame, naming the Mac
    /// and saying it stopped answering, not that it did not connect. `stalls` reaches this step
    /// with the default name and checks only the error's case.
    @Test("A Mac that stops answering mid-exchange fails naming it")
    func silenceNamesTheMac() async throws {
        let silent = try await SilentMac()
        defer { silent.stop() }
        // Connecting has no deadline: only the receive's is under test.
        let channel = ConnectionChannel(
            NWConnection(to: silent.endpoint, using: NearbyWorkers.pairingParameters()), peer: "Quiet Mini",
            limits: .none)
        defer { channel.connection.cancel() }
        try await channel.start()
        let limit = Duration.seconds(1)
        let (reason, took) = await timedOut { _ = try await channel.receiveFrame(within: limit) }
        let said = try #require(reason)
        #expect(said.contains("Quiet Mini") && said.contains("stopped answering"))
        // Never before the limit (measured 1.06 s).
        #expect(took >= limit)
    }

    /// A send the other Mac never takes in, once the socket buffers on both sides are full, runs
    /// out with `NearbyError.timedOut` naming the Mac and saying it stopped taking messages. No
    /// other test sends to a Mac that does not read, so `sendFrame`'s deadline is reached nowhere
    /// else.
    @Test("A Mac that stops taking messages fails naming it")
    func stalledSendNamesTheMac() async throws {
        let silent = try await SilentMac()
        defer { silent.stop() }
        let channel = ConnectionChannel(
            NWConnection(to: silent.endpoint, using: NearbyWorkers.pairingParameters()), peer: "Full Studio",
            limits: .none)
        defer { channel.connection.cancel() }
        try await channel.start()
        // 64 MB is far more than loopback's send and receive buffers together hold (a few MB on
        // macOS), so the send is still unprocessed when the limit comes: on the Studio it ran out
        // at 1.06 s. If Network.framework ever reports the content processed before the kernel
        // takes it, this finishes without timing out and the test says so.
        let frame = Data(count: 64 << 20)
        let limit = Duration.seconds(1)
        let (reason, took) = await timedOut { try await channel.sendFrame(frame, within: limit) }
        let said = try #require(reason)
        #expect(said.contains("Full Studio") && said.contains("stopped taking messages"))
        // Never before the limit (measured 1.06 s).
        #expect(took >= limit)
    }

    /// Each step's timer is cancelled when the step finishes in time (`within`'s `timer.cancel()`).
    /// Were it not, the connect timer would fire later and cancel a connection already in use: the
    /// next step would then fail with the connection's own error rather than a time-out, or a
    /// session would drop mid-run. No other test runs a finished step's timer. The timer is kept
    /// rather than set going, and run by hand once the step is done, as its limit passing would:
    /// on a loaded Mac a step can take longer than any limit short enough to wait out (one took past
    /// 300 ms over loopback on the CI mini, 19 October 2026).
    @Test("A step finished in time leaves no timer behind to drop the connection later")
    func finishedStepLeavesNoTimer() async throws {
        let silent = try await SilentMac()
        defer { silent.stop() }
        let channel = ConnectionChannel(
            NWConnection(to: silent.endpoint, using: NearbyWorkers.pairingParameters()), peer: "Studio")
        defer { channel.connection.cancel() }
        let real = channel.arm
        let timers = Locked<[DispatchWorkItem]>([])
        channel.arm = { _, timer in timers.update { $0.append(timer) } }
        try await channel.start(within: .seconds(5))
        channel.arm = real
        // The limit passes, after the step.
        let connectTimer = try #require(timers.value.first)
        #expect(timers.value.count == 1 && connectTimer.isCancelled)
        connectTimer.perform()
        if case .ready = channel.connection.state {
        } else {
            Issue.record("The connection was \(channel.connection.state) after its connect limit passed.")
        }
        // Its own deadline, not the connection's having been cancelled under it.
        let (reason, _) = await timedOut { _ = try await channel.receiveFrame(within: .milliseconds(500)) }
        let said = try #require(reason)
        #expect(said.contains("Studio") && said.contains("stopped answering"))
    }

    /// A step that fails before its deadline fails with its own error, not a time-out (`within`'s
    /// first `catch`, when the body claims the flag before the timer): here a frame announced as
    /// larger than a megabyte. The other Nearby tests fail before any deadline only through the
    /// pairing and session logic, which none checks for its error's case, and none sends a frame
    /// too large.
    @Test("An error before the deadline is passed on as it is, not as a time-out")
    func earlyErrorIsNotATimeOut() async throws {
        var count = UInt32(2 << 20).bigEndian
        let silent = try await SilentMac(saying: Data(bytes: &count, count: 4))
        defer { silent.stop() }
        let channel = ConnectionChannel(
            NWConnection(to: silent.endpoint, using: NearbyWorkers.pairingParameters()), peer: "Studio",
            limits: .none)
        defer { channel.connection.cancel() }
        try await channel.start()
        // The header arrives over loopback in milliseconds (measured 0.6 ms); an hour, so that no
        // stall of a loaded Mac lets the deadline come first. The error being `refused`, not
        // `timedOut`, is what shows it came before the deadline.
        let limit = Duration.seconds(3600)
        do {
            _ = try await channel.receiveFrame(within: limit)
            Issue.record("A frame too large was taken.")
        } catch NearbyError.refused(let reason) {
            #expect(reason.contains("too large"))
        } catch {
            Issue.record("Failed otherwise: \(error)")
        }
        // The timer was cancelled with the step: the connection is not dropped at the limit.
        if case .cancelled = channel.connection.state {
            Issue.record("The connection was cancelled although no deadline passed.")
        }
    }

    /// The client waits for the server's confirmation after its user has confirmed the code, and
    /// the server waits for the client's proof while its own user decides; each of those waits
    /// goes through `receiveAfterCheck`, the step a real connection gives five minutes, and a
    /// time-out there reaches the caller unchanged, naming the other Mac. The pairing tests' queue
    /// channel takes the protocol's default `receiveAfterCheck`, which is `receive`, so they cannot
    /// tell which step a side waits through; this channel runs out only on that step.
    @Test(
        "Pairing waits on the code check through its own deadline, on both sides", arguments: [true, false])
    func pairingWaitsThroughTheCheck(clientRunsOut: Bool) async throws {
        let laptop = NearbyPairing.Peer(id: UUID(), name: "Laptop")
        let studio = NearbyPairing.Peer(id: UUID(), name: "Studio")
        let (client, server) = CheckingChannel.pair()
        let ranOut = NearbyError.timedOut(
            "The code was not checked on \(clientRunsOut ? studio.name : laptop.name) within 5 minutes.")
        if clientRunsOut { client.checkRunsOut = ranOut } else { server.checkRunsOut = ranOut }
        async let serverSide = Result {
            try await NearbyPairing.answer(over: server, me: studio) { _, _ in true }
        }
        let clientSide = await Result {
            try await NearbyPairing.pair(over: client, me: laptop) { _, _ in true }
        }
        let answered = await serverSide
        if clientRunsOut {
            #expect(throws: ranOut) { try clientSide.get() }
            // The server had the client's proof before the client's wait ran out, but the client was
            // gone by the time it could keep the key, so it kept nothing either
            // (emmettl/bombcad-work#76).
            #expect(throws: NearbyError.self) { try answered.get() }
        } else {
            #expect(throws: ranOut) { try answered.get() }
            // The server's end closed with its time-out, so the client is not left waiting.
            #expect(throws: NearbyError.closed) { try clientSide.get() }
        }
    }

    /// emmettl/bombcad-work#76: the sharing Mac's user allows the pairing only after the other Mac
    /// has stopped waiting for them (five minutes on a real connection, here a check made to run
    /// out). Before, the sharing Mac kept the key as it sent its proof and said it was paired, with
    /// a Mac that had kept nothing. Now neither keeps it; and both do when the user is in time.
    @Test("Allowed after the other Mac gave up, neither Mac keeps the pairing; in time, both do")
    func allowedTooLate() async throws {
        let laptop = NearbyPairing.Peer(id: UUID(), name: "Laptop")
        let studio = NearbyPairing.Peer(id: UUID(), name: "Studio")
        for late in [true, false] {
            let (client, server) = CheckingChannel.pair()
            if late {
                client.checkRunsOut = .timedOut("The code was not checked on Studio within 5 minutes.")
            }
            let serverStore = MemoryPairingStore(name: studio.name, id: studio.id)
            let clientStore = MemoryPairingStore(name: laptop.name, id: laptop.id)
            // The user allows it only once the client's side has finished, given up or not.
            let (gaveUp, clientDone) = AsyncStream<Void>.makeStream()
            async let serverSide = Result {
                try await NearbyPairing.answer(
                    over: server, me: studio,
                    allow: { _, _ in
                        if late {
                            var done = gaveUp.makeAsyncIterator()
                            _ = await done.next()
                        }
                        return true
                    },
                    keep: { try serverStore.keep($0) }, forget: { try? serverStore.forget($0.peer.id) })
            }
            let clientSide = await Result {
                let pairing = try await NearbyPairing.pair(over: client, me: laptop) { _, _ in true }
                try clientStore.keep(pairing)
                return pairing
            }
            clientDone.yield()
            clientDone.finish()
            let answered = await serverSide
            if late {
                #expect((try? clientSide.get()) == nil && (try? answered.get()) == nil)
                #expect(serverStore.pairings().isEmpty && clientStore.pairings().isEmpty)
            } else {
                let kept = try clientSide.get()
                #expect(try answered.get().key == kept.key)
                #expect(serverStore.pairing(laptop.id)?.key == kept.key)
                #expect(clientStore.pairing(studio.id)?.key == kept.key)
            }
        }
    }

    /// A code never checked on the other Mac runs out with its own message, naming the Mac and the
    /// check rather than a silent link: the five-minute check on a real connection, shortened
    /// through the channel's `limits` (the `PairingChannel` requirement takes no limit).
    @Test("A code not checked in time says so, naming the Mac")
    func checkNamesTheMac() async throws {
        let silent = try await SilentMac()
        defer { silent.stop() }
        let limit = Duration.seconds(1)
        let channel = ConnectionChannel(
            NWConnection(to: silent.endpoint, using: NearbyWorkers.pairingParameters()), peer: "Studio",
            limits: .init(connect: nil, message: nil, check: limit, hello: nil))
        defer { channel.connection.cancel() }
        try await channel.start()
        let (reason, took) = await timedOut { _ = try await channel.receiveAfterCheck() }
        let said = try #require(reason)
        #expect(said.contains("Studio") && said.contains("code was not checked"))
        // Never before the limit.
        #expect(took >= limit)
    }
}

/// Two ends of a pairing exchange in one process, as `NearbyPairingTests`' queue channel, but with
/// a `receiveAfterCheck` of its own that can be made to run out.
private final class CheckingChannel: PairingChannel, @unchecked Sendable {
    private var iterator: AsyncStream<NearbyPairing.Message>.Iterator
    private let outbox: AsyncStream<NearbyPairing.Message>.Continuation
    /// Thrown in place of the message after the code check, as a check that runs out would; this
    /// end then closes, as the real channel cancels its connection.
    var checkRunsOut: NearbyError?

    private init(
        inbox: AsyncStream<NearbyPairing.Message>, outbox: AsyncStream<NearbyPairing.Message>.Continuation
    ) {
        iterator = inbox.makeAsyncIterator()
        self.outbox = outbox
    }

    static func pair() -> (CheckingChannel, CheckingChannel) {
        let (a, toA) = AsyncStream<NearbyPairing.Message>.makeStream()
        let (b, toB) = AsyncStream<NearbyPairing.Message>.makeStream()
        return (CheckingChannel(inbox: a, outbox: toB), CheckingChannel(inbox: b, outbox: toA))
    }

    func send(_ message: NearbyPairing.Message) async throws { outbox.yield(message) }

    func receive() async throws -> NearbyPairing.Message {
        guard let message = await iterator.next() else { throw NearbyError.closed }
        return message
    }

    func receiveAfterCheck() async throws -> NearbyPairing.Message {
        if let checkRunsOut {
            outbox.finish()
            throw checkRunsOut
        }
        return try await receive()
    }
}
