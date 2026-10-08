import Testing
import simd

@testable import BlastCore

@Suite("Shared spatial query adapters")
struct SpatialQueryAdapterTests {
    let unit = Box(min: .zero, max: SIMD3(repeating: 1))

    @Test("Picking keeps the historical strict parallel threshold")
    func pickingTolerance() {
        let threshold: Float = 1e-8
        for sign: Float in [-1, 1] {
            for magnitude in [threshold.nextDown, threshold, threshold.nextUp] {
                let start: Float = sign > 0 ? -magnitude / 2 : 1 + magnitude / 2
                // The positive near-zero coordinate retains the tiny start offset in Float.
                // The negative case uses a metre-scale ray along x and the tiny y component.
                let origin: SIMD3<Float> = sign > 0 ? [start, 0.5, 0.5] : [-1, 1, 0.5]
                let direction: SIMD3<Float> = sign > 0 ? [magnitude, 0, 0] : [1, -magnitude, 0]
                let result = ScenePicking.distance(to: unit, origin: origin, direction: direction)
                if sign > 0 {
                    #expect(result == (magnitude < threshold ? nil : 0.5))
                } else {
                    #expect(result == 1)
                }
            }
        }
        #expect(ScenePicking.distance(to: unit, origin: [0.5, 0.5, 0.5], direction: .zero) == nil)
    }

    @Test("Fragment segments retain fractions, endpoint contact and stationary contact")
    func segment() {
        #expect(FragmentCloud.entry([-1, 0.5, 0.5], [3, 0.5, 0.5], unit) == 0.25)
        #expect(FragmentCloud.entry([-1, 0.5, 0.5], [-0.01, 0.5, 0.5], unit) == nil)
        #expect(FragmentCloud.entry([-1, 0.5, 0.5], [0, 0.5, 0.5], unit) == 1)
        #expect(FragmentCloud.entry([0.5, 0.5, 0.5], [0.5, 0.5, 0.5], unit) == 0)
        #expect(FragmentCloud.entry([1, 0.5, 0.5], [1, 0.5, 0.5], unit) == 0)
        #expect(FragmentCloud.entry([2, 0.5, 0.5], [2, 0.5, 0.5], unit) == nil)
    }

    @Test("Fragment segments keep their own strict parallel threshold")
    func segmentTolerance() {
        let threshold: Float = 1e-12
        for magnitude in [threshold.nextDown, threshold, threshold.nextUp] {
            let start = SIMD3<Float>(-magnitude / 2, 0.5, 0.5)
            let end = SIMD3<Float>(magnitude / 2, 0.5, 0.5)
            #expect(FragmentCloud.entry(start, end, unit) == (magnitude < threshold ? nil : 0.5))
        }
    }

    @Test("Picking preserves closed boundaries and nearest forward distance")
    func picking() {
        #expect(ScenePicking.distance(to: unit, origin: [-1, 1, 1], direction: [2, 0, 0]) == 0.5)
        #expect(ScenePicking.distance(to: unit, origin: [0.5, 0.5, 0.5], direction: [1, 1, 1]) == 0)
        #expect(ScenePicking.distance(to: unit, origin: [2, 0.5, 0.5], direction: [1, 0, 0]) == nil)
        #expect(ScenePicking.distance(to: unit, origin: [.nan, 0.5, 0.5], direction: [1, 0, 0]) == nil)
    }
}
