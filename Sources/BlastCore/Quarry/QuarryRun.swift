import BlastModel
import Foundation
import Metal

/// One firing of a quarry face, simulated on its own thread into a pose cache that fills as it
/// goes, so the event can be watched while it is computed and scrubbed over what is done. The
/// solver is not bit-reproducible, so what is shown is this one run, stored as it is simulated, not
/// a second simulation. Illustrative, like the rest of the quarry (emmettl/bombcad-work#126).
public final class QuarryRun: @unchecked Sendable {
    public let firings: [QuarryFiring]
    public let frames: Int
    /// Frames stored before the event is worth showing: enough that playback starts a little
    /// behind the solver rather than at its heels.
    public let lead: Int
    /// When the run was asked for.
    public let requested: Date

    private let lock = NSLock()
    private var storedCache: QuarryPoseCache?
    private var cancelledFlag = false
    private var done = false
    private var failed: String?
    private var startedAt: Date?
    private var finishedAt: Date?
    private var leadAt: Date?
    private var waiting: [@Sendable () -> Void] = []
    private var finishing: [@Sendable () -> Void] = []
    private var gpuSeconds: [Double] = []

    /// Starts simulating `face` fired by `firings`, `frames` frames at `frameRate` with `substeps`
    /// solver steps each, on a thread of its own. Returns at once.
    public init(
        device: MTLDevice, face: QuarryFace, launch: QuarryLaunch = QuarryLaunch(), firings: [QuarryFiring],
        frames: Int, frameRate: Float, substeps: Int, buffers: Int = 1, lead: Int = 9
    ) {
        self.firings = firings
        self.frames = frames
        self.lead = max(1, min(lead, frames))
        requested = Date()
        Thread.detachNewThread { [self] in
            Thread.current.qualityOfService = .userInitiated
            Thread.current.name = "Quarry run"
            // Pooled, a frame at a time inside: MTLBuffer.contents() and each command buffer
            // autorelease, and this thread's own pool drains only when it ends.
            autoreleasepool {
                simulate(
                    device: device, face: face, launch: launch, frameRate: frameRate, substeps: substeps,
                    buffers: buffers)
            }
        }
    }

    private func simulate(
        device: MTLDevice, face: QuarryFace, launch: QuarryLaunch, frameRate: Float, substeps: Int,
        buffers: Int
    ) {
        do {
            let simulation = try QuarrySimulation(
                device: device, face: face, launch: launch, firings: firings,
                dt: 1 / (frameRate * Float(substeps)))
            let count = 2 * simulation.bodyCount
            let pointer = simulation.pose.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
            let cache = QuarryPoseCache(
                rest: Array(UnsafeBufferPointer(start: pointer, count: count)),
                still: face.blocks.map(\.skin),
                frames: frames, low: face.low, high: face.high)
            cache.store(frame: 0, pose: pointer)
            lock.withLock {
                storedCache = cache
                startedAt = Date()
            }
            reachedLead(cache)
            for f in 1..<frames {
                if cancelled { break }
                let gpu = autoreleasepool { simulation.advance(substeps: substeps, buffers: buffers) }
                cache.store(frame: f, pose: pointer)
                lock.withLock { gpuSeconds.append(gpu) }
                reachedLead(cache)
            }
            lock.withLock {
                done = true
                finishedAt = Date()
            }
        } catch {
            lock.withLock {
                failed = "\(error)"
                done = true
            }
        }
        // Anyone still waiting is told; they find the run failed or cancelled.
        let handlers = lock.withLock {
            let h = waiting + finishing
            waiting = []
            finishing = []
            return h
        }
        for handler in handlers { handler() }
    }

    private func reachedLead(_ cache: QuarryPoseCache) {
        guard cache.available >= lead || cache.isComplete else { return }
        let handlers = lock.withLock { () -> [@Sendable () -> Void] in
            if leadAt == nil { leadAt = Date() }
            let h = waiting
            waiting = []
            return h
        }
        for handler in handlers { handler() }
    }

    /// Calls `handler` (on the run's thread, or at once on this one) when the lead is stored, or
    /// when the run ends without it.
    public func whenStartable(_ handler: @escaping @Sendable () -> Void) {
        let now = lock.withLock { () -> Bool in
            if leadAt != nil || done { return true }
            waiting.append(handler)
            return false
        }
        if now { handler() }
    }

    /// Calls `handler` (on the run's thread, or at once on this one) when the run ends: done,
    /// cancelled or failed.
    public func whenFinished(_ handler: @escaping @Sendable () -> Void) {
        let now = lock.withLock { () -> Bool in
            if done { return true }
            finishing.append(handler)
            return false
        }
        if now { handler() }
    }

    /// The poses stored so far, once the solver is built.
    public var cache: QuarryPoseCache? { lock.withLock { storedCache } }
    /// Whether the lead is stored (or the whole event, if shorter).
    public var isStartable: Bool { lock.withLock { leadAt != nil } }
    /// Still computing frames.
    public var isSimulating: Bool { lock.withLock { !done && !cancelledFlag } }
    public var failure: String? { lock.withLock { failed } }
    public var cancelled: Bool { lock.withLock { cancelledFlag } }

    /// Stops the solver after the frame it is on; what is stored stays.
    public func cancel() { lock.withLock { cancelledFlag = true } }

    /// Seconds from the request to the lead stored, and to the last frame (nil until then).
    public var secondsToStart: Double? { lock.withLock { leadAt?.timeIntervalSince(requested) } }
    public var secondsToFinish: Double? {
        lock.withLock { finishedAt.map { $0.timeIntervalSince(requested) } }
    }
    /// Seconds from the request to the solver's first frame stored: building the solver.
    public var secondsToBuild: Double? { lock.withLock { startedAt?.timeIntervalSince(requested) } }
    /// The GPU time of each frame simulated (s).
    public var frameGPUSeconds: [Double] { lock.withLock { gpuSeconds } }
}
