import Foundation
import Testing

@testable import BlastModel

@Suite("A replay paced by its frames' time on the display's refreshes")
struct ReplayPaceTests {
    /// Gaps as uneven as a street run's: 0.02 to 0.89 ms, alternating within a few frames.
    private static let streetGaps = [0.74, 0.02, 0.48, 0.78, 0.09, 0.26, 0.22, 0.89, 0.30, 0.02, 0.66, 0.36]
    private static func times(_ gaps: [Double], repeats: Int) -> [Double] {
        var times = [0.0]
        for _ in 0..<repeats { for gap in gaps { times.append(times.last! + gap / 1000) } }
        return times
    }

    @Test("Plays the frames in as long as a frame each 1/24 s did, at a steady rate")
    func lengthAsBefore() {
        let times = Self.times(Self.streetGaps, repeats: 10)
        let pace = ReplayPace(times: times)
        #expect(abs(pace.wallSeconds - Double(times.count - 1) / 24) < 1e-12)
        #expect(abs(pace.rate - (times.last! - times[0]) / pace.wallSeconds) < 1e-15)
        // Twice the speed, half as long.
        #expect(abs(ReplayPace(times: times, speed: 2).wallSeconds - pace.wallSeconds / 2) < 1e-12)
        // One frame, or frames all at one time: nothing to pace, and no division by zero.
        #expect(ReplayPace(times: [0.1]).rate > 0 && ReplayPace(times: [0.1, 0.1]).wallSeconds == 0)
    }

    @Test("The clock moves by wall time at the rate, no further than a limit or the end; then the tail")
    func clock() {
        let pace = ReplayPace(times: [0, 0.01, 0.02, 0.04], end: 0.54, tailRate: 1)
        // 3 frames' gaps in 3/24 s: 0.04 s simulated in 0.125 s, 0.32 simulated seconds a second.
        #expect(abs(pace.rate - 0.32) < 1e-12)
        #expect(abs(pace.time(after: 0, wall: 0.0625) - 0.02) < 1e-12)
        #expect(pace.time(after: 0, wall: 1, limit: 0.015) == 0.015)
        // Never back: a limit behind the clock holds it.
        #expect(pace.time(after: 0.03, wall: 1, limit: 0.01) == 0.03)
        // Past the last frame at the tail's rate: 0.0625 s wall at 0.32 reaches the last frame
        // after 0.0625 s of it, then 0.0625 s at 1.
        #expect(abs(pace.time(after: 0.02, wall: 0.125) - (0.04 + 0.0625)) < 1e-12)
        #expect(pace.time(after: 0.5, wall: 1) == 0.54)
        #expect(abs(pace.wallSeconds - (0.125 + 0.5)) < 1e-12)
    }

    @Test("The frame shown is the last at or before the clock")
    func lastAtOrBefore() {
        let times = [0.0, 0.001, 0.003, 0.003, 0.0031]
        #expect(ReplayPace.index(at: -1, in: times) == 0)
        #expect(ReplayPace.index(at: 0.0009, in: times) == 0)
        #expect(ReplayPace.index(at: 0.001, in: times) == 1)
        #expect(ReplayPace.index(at: 0.003, in: times) == 3)
        #expect(ReplayPace.index(at: 0.0031 - 1e-13, in: times) == 4)
        #expect(ReplayPace.index(at: 1, in: times) == 4)
        #expect(ReplayPace.index(at: 1, in: []) == 0)
    }

    @Test("A refresh stands for whole refreshes: jitter ignored, a missed one counted, a stall capped")
    func refreshes() {
        let period = 1.0 / 60
        #expect(ReplayPace.refreshSeconds(elapsed: period * 1.2, period: period) == period)
        #expect(ReplayPace.refreshSeconds(elapsed: period * 0.7, period: period) == period)
        #expect(ReplayPace.refreshSeconds(elapsed: period * 0.2, period: period) == period)
        #expect(ReplayPace.refreshSeconds(elapsed: period * 2.1, period: period) == 2 * period)
        #expect(ReplayPace.refreshSeconds(elapsed: 3, period: period) == 4 * period)
    }

    @Test("Uneven frames played by time keep the wave's speed even, where stepping by index did not")
    func evenOverUnevenFrames() {
        let times = Self.times(Self.streetGaps, repeats: 20)
        let pace = ReplayPace(times: times)
        // By index: a frame each 1/24 s, whatever its gap.
        let byIndex = times.enumerated().map { ReplayEvenness.Shown(wall: Double($0) / 24, time: $1) }
        // By time: each 60 Hz refresh, the last frame at or before the clock, shown when it changes.
        var byTime: [ReplayEvenness.Shown] = []
        var clock = pace.start
        var refresh = 0
        while true {
            let n = pace.index(at: clock)
            if byTime.last?.time != times[n] {
                byTime.append(.init(wall: Double(refresh) / 60, time: times[n]))
            }
            if clock >= pace.end { break }
            refresh += 1
            clock = pace.time(
                after: clock, wall: ReplayPace.refreshSeconds(elapsed: 1.0 / 60, period: 1.0 / 60))
        }
        #expect(byTime.map(\.time) == byTime.map(\.time).sorted())
        #expect(abs(Double(refresh) / 60 - pace.wallSeconds) <= 1.0 / 60)
        let before = ReplayEvenness(byIndex)
        let after = ReplayEvenness(byTime)
        // In quarter-second windows the simulated time shown a second swings widely by index,
        // and barely by time (a refresh's worth of rounding at either end).
        #expect(ReplayEvenness.spread(before.perWindow) > 1.5)
        #expect(ReplayEvenness.spread(after.perWindow) < 1.25)
        // A frame by itself: by index each is on screen 1/24 s for gaps 0.02 to 0.89 ms.
        #expect(ReplayEvenness.spread(before.perFrame) > 3)
        #expect(ReplayEvenness.spread(after.perFrame) < ReplayEvenness.spread(before.perFrame))
    }

    @Test("Evenness: wall per simulated second for each frame, simulated per wall in windows")
    func evenness() {
        let shown = (0..<9).map { ReplayEvenness.Shown(wall: Double($0) * 0.125, time: Double($0) * 0.01) }
        let even = ReplayEvenness(shown, window: 0.25)
        #expect(even.perFrame.allSatisfy { abs($0 - 12.5) < 1e-9 })
        #expect(even.perWindow.count == 7 && even.perWindow.allSatisfy { abs($0 - 0.08) < 1e-9 })
        #expect(abs(ReplayEvenness.spread(even.perFrame) - 1) < 1e-12)
    }
}
