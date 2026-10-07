import Foundation

/// Turns the scattered energy envelope into a dense pattern of reflections.
///
/// Each histogram bin becomes several impulses at random times with random signs, sharing the bin's
/// energy in every band, so they add incoherently to that energy. They go through the same renderer as
/// the image sources, so both parts share one gain convention. The density follows the reflection
/// density of a room, `4 pi c³ t² / V` per second, between 2,000 and 20,000 per second: sparse enough
/// to cost little, dense enough not to sound grainy.
enum DiffuseTail {
    /// Bins are smoothed over this many on each side at least, to reduce the ray tracer's noise; later,
    /// over 2% of the time since emission, as a real decay is smooth over such spans.
    static let smoothing = 2

    /// Adds the envelope `energy[band][bin]` to `renderer` and returns its energy summed over `bands`.
    static func render(
        _ energy: [[Double]], into renderer: inout BandRenderer, roomVolume: Double, soundSpeed: Double,
        seed: UInt64, bands: ClosedRange<Int>
    ) -> Double {
        guard let bins = energy.first?.count, bins > 0 else { return 0 }
        let smoothed = energy.map { smooth($0) }
        var random = SplitMix(seed: seed)
        let width = DiffuseRayTracer.binWidth
        var gains = [Double](repeating: 0, count: energy.count)
        var total = 0.0
        for bin in 0..<bins {
            guard smoothed.contains(where: { $0[bin] > 0 }) else { continue }
            let t = (Double(bin) + 0.5) * width
            let density = min(max(4 * Double.pi * pow(soundSpeed, 3) * t * t / roomVolume, 2_000), 20_000)
            let count = max(1, Int((density * width).rounded()))
            for b in bands { total += smoothed[b][bin] }
            for _ in 0..<count {
                let sign: Double = random.next() & 1 == 0 ? 1 : -1
                for b in 0..<energy.count {
                    gains[b] = sign * (smoothed[b][bin] / Double(count)).squareRoot()
                }
                renderer.add(delay: (Double(bin) + random.nextUnit()) * width, gains: gains)
            }
        }
        return total
    }

    /// Moving average whose half-width grows with time, over fewer bins at the ends.
    static func smooth(_ values: [Double]) -> [Double] {
        return values.indices.map { i in
            let span = max(smoothing, Int(0.02 * Double(i)))
            let range = max(0, i - span)...min(values.count - 1, i + span)
            return values[range].reduce(0, +) / Double(range.count)
        }
    }
}
