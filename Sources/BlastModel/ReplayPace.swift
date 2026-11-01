import Foundation

/// How a replay keeps pace with the display: a clock of simulated time that each refresh moves on
/// by the wall time since the last, at a steady rate, and the frame shown is the last recorded at
/// or before it (emmettl/bombcad-work#94).
///
/// A run records its frames unevenly in time (a street run's gaps swing from 0.02 to 0.89 ms
/// within a few frames, a district's early ones from 2 to 10 ms), so stepping a frame a tick made
/// the wave's apparent speed jump by up to 40 times between neighbouring frames. Paced by time,
/// a frame closer to the next than a refresh's worth is passed over, and one far from it held.
///
/// The rate plays the recorded frames in about as long as stepping one each 1/24 s did. After the
/// last frame, a replay that carries on (the Mac's crater tail) runs at `tailRate`.
public struct ReplayPace: Equatable, Sendable {
    /// The frames a second a replay stepped through by index; it now takes as long as that.
    public static let framesPerSecond = 24.0

    /// The frames' simulated times, in order.
    public let times: [Double]
    /// Simulated seconds a wall second, up to the last frame.
    public let rate: Double
    /// Simulated seconds a wall second after it.
    public let tailRate: Double
    /// Where the replay ends: the last frame's time, or later for a tail.
    public let end: Double

    /// `speed` scales the rate: 1 plays the frames in as long as `framesPerSecond` would.
    public init(
        times: [Double], end: Double? = nil, framesPerSecond: Double = Self.framesPerSecond,
        speed: Double = 1, tailRate: Double = 1
    ) {
        self.times = times
        let first = times.first ?? 0
        let last = times.last ?? 0
        let span = last - first
        rate =
            speed
            * (times.count > 1 && span > 0
                ? span / (Double(times.count - 1) / framesPerSecond) : 1 / framesPerSecond)
        self.tailRate = tailRate
        self.end = max(end ?? last, last)
    }

    public var start: Double { times.first ?? 0 }
    /// The last frame's time.
    public var lastFrameTime: Double { times.last ?? 0 }

    /// The wall seconds the whole replay takes.
    public var wallSeconds: Double {
        (lastFrameTime - start) / rate + (end - lastFrameTime) / tailRate
    }

    /// The simulated time `wall` seconds on from `time`: at `rate` up to the last frame, at
    /// `tailRate` after it, and no further than `limit` or the end.
    public func time(after time: Double, wall: Double, limit: Double = .infinity) -> Double {
        let ceiling = min(limit, end)
        guard wall > 0, time < ceiling else { return time }
        var next: Double
        if time < lastFrameTime {
            next = time + wall * rate
            if next > lastFrameTime { next = lastFrameTime + (next - lastFrameTime) / rate * tailRate }
        } else {
            next = time + wall * tailRate
        }
        return min(next, ceiling)
    }

    /// The last frame at or before `time`; the first if it is before them all.
    public func index(at time: Double) -> Int { Self.index(at: time, in: times) }

    /// The last of `times` (in order) at or before `time`, within 1e-12 s; the first if `time` is
    /// before them all.
    public static func index(at time: Double, in times: [Double]) -> Int {
        var low = 0
        var high = times.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if times[middle] <= time + 1e-12 { low = middle } else { high = middle - 1 }
        }
        return max(low, 0)
    }

    /// The wall seconds a refresh stands for, from the `elapsed` seconds since the last one: a
    /// whole number of refreshes of `period`, so that the moment the callback runs, which jitters
    /// by a millisecond or two, does not, while a refresh missed counts; at least one and at most
    /// `most`, so that a stall resumes where it left off rather than leaping on.
    public static func refreshSeconds(elapsed: Double, period: Double, most: Int = 4) -> Double {
        guard period > 0 else { return max(elapsed, 0) }
        let refreshes = min(max((elapsed / period).rounded(), 1), Double(most))
        return refreshes * period
    }
}

/// How evenly a replay showed a run's time: from when each frame came on screen and its time.
public struct ReplayEvenness: Equatable, Sendable {
    /// One frame on screen: the wall second it appeared, and its simulated time.
    public struct Shown: Equatable, Sendable {
        public var wall: Double
        public var time: Double
        public init(wall: Double, time: Double) {
            self.wall = wall
            self.time = time
        }
    }

    /// For each frame shown until the next, the wall seconds it was on screen per simulated
    /// second it stood for (the next one's time less its own), as each was shown in turn.
    public let perFrame: [Double]
    /// The simulated seconds shown a wall second from each frame shown to the first shown at
    /// least `window` seconds after it.
    public let perWindow: [Double]
    public let window: Double

    public init(_ shown: [Shown], window: Double = 0.25) {
        self.window = window
        let pairs = zip(shown, shown.dropFirst()).filter { $1.time > $0.time && $1.wall > $0.wall }
        perFrame = pairs.map { ($1.wall - $0.wall) / ($1.time - $0.time) }
        var windows: [Double] = []
        var j = 0
        for (i, from) in shown.enumerated() {
            // To the first frame shown at least a window later: both ends where a frame came on,
            // so that the frames' own spacing does not count as unevenness.
            j = max(j, i + 1)
            while j < shown.count, shown[j].wall < from.wall + window - 1e-9 { j += 1 }
            guard j < shown.count else { break }
            windows.append((shown[j].time - from.time) / (shown[j].wall - from.wall))
        }
        perWindow = windows
    }

    /// The `q` quantile of `values`, 0 for none.
    public static func quantile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(max(Int((q * Double(sorted.count - 1)).rounded()), 0), sorted.count - 1)]
    }

    /// The spread of `values`: the 90th percentile over the 10th (1 is perfectly even).
    public static func spread(_ values: [Double]) -> Double {
        let low = quantile(values, 0.1)
        return low > 0 ? quantile(values, 0.9) / low : .infinity
    }

    /// As text: the spread of each, and their medians.
    public var summary: String {
        String(
            format:
                "on screen %.0f ms per simulated ms median, spread %.2f× (90th over 10th percentile, %d frames); simulated time shown in %.2f s windows, spread %.2f×",
            Self.quantile(perFrame, 0.5), Self.spread(perFrame), perFrame.count, window,
            Self.spread(perWindow))
    }
}
