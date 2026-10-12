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
/// thread, which with the GPU busy is most of the run. One that runs longer is recorded as hung.
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

    var isRecursive: Bool { true }

    /// Around each test case only, not the suite as a whole.
    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? { testCase == nil ? nil : self }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        await Self.admission.enter()
        do {
            try await run(function)
        } catch {
            await Self.admission.leave()
            throw error
        }
        await Self.admission.leave()
    }

    /// Runs `function` on the dedicated threads, recording it as hung if it runs past `hangLimit`.
    func run(_ function: @Sendable () async throws -> Void) async throws {
        let limit = hangLimit
        try await withTaskExecutorPreference(Self.executor) {
            // On its thread now: the test runs from here.
            let watchdog = Task {
                try await Task.sleep(for: limit)
                Issue.record("Hung: still running \(limit) after it got its thread.")
            }
            defer { watchdog.cancel() }
            try await function()
        }
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

    @Test("A test that runs past its limit on its thread is recorded as hung, one within it is not")
    func hangLimit() async throws {
        var short = GPUThreads()
        short.hangLimit = .milliseconds(100)
        await withKnownIssue {
            try await short.run { Self.hold(0.5) }
        }
        // Held on its thread, not waiting for one, however busy the others.
        short.hangLimit = .seconds(30)
        try await short.run { Self.hold(0.05) }
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
