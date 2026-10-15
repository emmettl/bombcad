import Foundation
import Testing

/// Runs a suite's tests on threads of their own, outside Swift's cooperative pool.
///
/// The solvers wait for the GPU synchronously (`waitUntilCompleted`), as the app and `blastbench`
/// want. On a cooperative thread that wait holds the thread: with the GPU busy, every one of the
/// pool's few threads (one a core) waited on the GPU and the suite's other tests, trivial ones
/// included, could not start until near the end of the run, an hour in. Tests of suites with
/// this trait run on `GPUThreads.executor` instead, as many threads as cores, so as many of them
/// run at once as before, and the cooperative pool stays free for the rest.
///
/// Each test is held to `hangLimit` from when it has its thread, not from when it was started:
/// Swift Testing starts every test at once and its own time limit would count the wait for a
/// thread, which with the GPU busy is most of the run. One that runs longer stops the test run:
/// a test that never returns is never finished, so an issue recorded against it is not reported
/// until the run is stopped (on 15 October two Sod shock-tube tests were recorded hung at two
/// hours and the run went on for three more, the log's buffered output showing nothing after
/// tests that had in fact passed). So the hung test is named on standard error, which is not
/// buffered, and the test process exits with a failure. The watchdog is a dispatch timer,
/// on threads of its own, so that it fires however busy the cooperative pool and these threads.
///
/// No more of these tests start than there are threads: the rest wait to start (on the
/// cooperative pool, holding no thread, and before their limit is counted). Otherwise a test
/// that awaited something, a sleep or a child task, came back to the end of a queue of tests not
/// yet begun, behind the hour of work of a busy GPU, and its limit counted the wait.
struct GPUThreads: SuiteTrait, TestTrait, TestScoping {
    static let threads = max(4, ProcessInfo.processInfo.activeProcessorCount)
    static let executor = DedicatedThreadExecutor(name: "gpu-test", count: threads)
    static let admission = Admission(limit: threads)

    /// Longer than the whole suite has taken under any load measured (71 minutes): at a load
    /// average of 250, heavy tests of a debug build ran for over half an hour on their threads.
    var hangLimit: Duration = .seconds(2 * 60 * 60)
    /// For the tests: called in place of stopping the run, with what would have been said.
    var onHang: (@Sendable (String) -> Void)?

    var isRecursive: Bool { true }

    /// Around each test case only, not the suite as a whole.
    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? { testCase == nil ? nil : self }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        await Self.admission.enter()
        do {
            try await run(Self.describe(test, testCase), function)
        } catch {
            await Self.admission.leave()
            throw error
        }
        await Self.admission.leave()
    }

    /// Runs `function`, the test `name`, on the dedicated threads, stopping the run if it is still
    /// running `hangLimit` after it began there.
    func run(_ name: String, _ function: @Sendable () async throws -> Void) async throws {
        let limit = hangLimit
        let hung = onHang ?? { Self.stop($0) }
        try await withTaskExecutorPreference(Self.executor) {
            // On its thread now: the test runs from here.
            let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            watchdog.schedule(deadline: .now() + limit.timeInterval)
            watchdog.setEventHandler {
                hung("Hung: \(name) still running \(limit) after it got its thread; stopping the test run.")
            }
            watchdog.activate()
            defer { watchdog.cancel() }
            try await function()
        }
    }

    /// The test and where it is, as a hang names it (which of its arguments is not public).
    static func describe(_ test: Test, _ testCase: Test.Case?) -> String {
        let place = "\(test.sourceLocation.fileName):\(test.sourceLocation.line)"
        return
            "\"\(test.displayName ?? test.name)\" (\(place)\(test.isParameterized ? ", one of its argument cases" : ""))"
    }

    /// Says what hung where it is seen at once, and ends the test process with a failure.
    static func stop(_ message: String) -> Never {
        fflush(stdout)
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(EXIT_FAILURE)
    }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

/// Lets `limit` callers in at once and the rest in turn, first come first served.
actor Admission {
    let limit: Int
    private var inside = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func enter() async {
        if inside < limit {
            inside += 1
            return
        }
        // The one leaving hands its place on.
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty {
            inside -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

extension Trait where Self == GPUThreads {
    /// The suite's tests wait on the GPU: run them off the cooperative pool (`GPUThreads`).
    static var gpuThreads: Self { GPUThreads() }
}

/// A fixed number of threads, each running the jobs it is given one at a time, first come first
/// served. Blocking one blocks only it.
final class DedicatedThreadExecutor: TaskExecutor, @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [UnownedJob] = []

    init(name: String, count: Int) {
        for n in 0..<count {
            let thread = Thread { [unowned self] in run() }
            thread.name = "\(name)-\(n)"
            // As a main thread's, for the deep frames of debug builds.
            thread.stackSize = 8 << 20
            thread.start()
        }
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    private func run() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }
}

@Suite("Tests that wait on the GPU run off the cooperative pool", .gpuThreads)
struct GPUThreadsTests {
    @Test("A synchronous test of such a suite runs on one of the dedicated threads")
    func synchronousTest() {
        #expect(Thread.current.name?.hasPrefix("gpu-test-") == true, "\(Thread.current.name ?? "unnamed")")
    }

    @Test("And blocking there leaves the cooperative pool free", arguments: 0..<4)
    func blocking(_ n: Int) {
        Thread.sleep(forTimeInterval: 0.05)
        #expect(Thread.current.name?.hasPrefix("gpu-test-") == true)
    }

    @Test("A test still running past its limit is caught however busy the threads, one within it is not")
    func hangLimit() async throws {
        var short = GPUThreads()
        short.hangLimit = .milliseconds(100)
        // Every dedicated thread but the one the test holds held too, as when tests hang or the GPU
        // is busy, and the cooperative pool's threads as well, for longer than the watchdog may
        // take: it must still fire while the test spins on its thread. The test holds its thread
        // until it does, up to two minutes.
        let holders = (1..<GPUThreads.threads).map { _ in
            Task(executorPreference: GPUThreads.executor) { Self.hold(8) }
        }
        let pool = (0..<ProcessInfo.processInfo.activeProcessorCount).map { _ in
            Task.detached { Self.hold(8) }
        }
        try await Task.sleep(for: .milliseconds(200))
        let said = Message()
        short.onHang = { said.set($0) }
        let began = Message()
        try await short.run("\"spinning\"") {
            began.set("")
            while said.value == nil && Date().timeIntervalSince(began.time ?? .now) < 120 { Self.hold(0.01) }
        }
        #expect(
            said.value
                == "Hung: \"spinning\" still running 0.1 seconds after it got its thread; stopping the test run."
        )
        let waited = (said.time ?? .distantFuture).timeIntervalSince(began.time ?? .distantPast)
        #expect(waited < 4, "The watchdog waited \(waited) s, for a busy thread.")
        for task in holders + pool { await task.value }
        // Held on its thread, not waiting for one, however busy the others: not caught.
        let late = Message()
        short.onHang = { late.set($0) }
        short.hangLimit = .seconds(30)
        try await short.run("within") { Self.hold(0.05) }
        #expect(late.value == nil)
    }

    @Test("A hang names the test, where it is, and whether it takes arguments", arguments: [3])
    func naming(_ n: Int) throws {
        let test = try #require(Test.current)
        let line = test.sourceLocation.line
        #expect(
            GPUThreads.describe(test, Test.Case.current)
                == "\"A hang names the test, where it is, and whether it takes arguments\" "
                + "(GPUThreads.swift:\(line), one of its argument cases)")
    }

    /// Holds the thread, as a test waiting on the GPU does.
    private static func hold(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    @Test("No more tests start than there are threads; the others wait their turn")
    func admission() async {
        let gate = Admission(limit: 2)
        await gate.enter()
        await gate.enter()
        let third = Task { await gate.enter() }
        try? await Task.sleep(for: .milliseconds(50))
        // Still waiting: leaving hands it the place.
        await gate.leave()
        await third.value
        await gate.leave()
        await gate.leave()
        // All places free again.
        await gate.enter()
        await gate.enter()
        await gate.leave()
        await gate.leave()
    }
}

/// A message set from any thread, and when.
private final class Message: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?
    private var date: Date?
    var value: String? { lock.withLock { text } }
    var time: Date? { lock.withLock { date } }
    func set(_ message: String) {
        lock.withLock {
            text = message
            date = Date()
        }
    }
}
