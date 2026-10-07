import Foundation

/// Specular reflections in a rectangular room by the image-source method (Allen and Berkley, 1979).
///
/// Along an axis of length `L`, a source at `s` has images at `(1 - 2q) s + 2 n L` for integer `n` and
/// `q` in {0, 1}. Such an image has reflected `|n - q|` times from the wall at 0 and `|n|` times from
/// the wall at `L`. Its reflection order is the total over the three axes.
public struct ImageSourceModel: Sendable {
    public var room: ShoeboxRoom
    public var source: SIMD3<Double>
    public var atmosphere: Atmosphere
    public var airAbsorption: Bool

    public init(room: ShoeboxRoom, source: SIMD3<Double>, atmosphere: Atmosphere, airAbsorption: Bool) {
        self.room = room
        self.source = source
        self.atmosphere = atmosphere
        self.airAbsorption = airAbsorption
    }

    /// Image sources along one axis relative to the receiver, with their per-band reflection gain.
    struct AxisImage {
        var offset: Double
        var order: Int
        var gains: [Double]
    }

    public struct Summary: Equatable, Sendable {
        /// Arrivals passed to the caller.
        public var arrivals = 0
        /// Earliest arrival in seconds omitted only because its order exceeded the limit, if any arrived
        /// within the duration. The response is incomplete from this time.
        public var orderLimitedAfter: Double?
    }

    /// Calls `body` with the delay in seconds, reflection order and per-band pressure gain of each
    /// image arriving at `receiver` within `duration` and up to `maximumOrder` reflections.
    ///
    /// The gain is relative to the free-field pressure 1 m from the source: spherical spreading `1/r`,
    /// the product of the reflection coefficients met on the path and, optionally, air attenuation.
    /// Arrivals are not delivered in time order. Enumeration ends early once `stop` returns true.
    @discardableResult
    public func forEachArrival(
        at receiver: SIMD3<Double>, duration: Double, maximumOrder: Int, includeDirect: Bool = true,
        stop: () -> Bool = { false }, _ body: (_ delay: Double, _ order: Int, _ gains: [Double]) -> Void
    ) -> Summary {
        let c = atmosphere.soundSpeed
        let reach = duration * c
        let reach2 = reach * reach
        let bands = OctaveBands.count
        let xs = axisImages(
            length: room.size.x, source: source.x, receiver: receiver.x, reach: reach,
            low: room.west.reflection, high: room.east.reflection)
        let ys = axisImages(
            length: room.size.y, source: source.y, receiver: receiver.y, reach: reach,
            low: room.south.reflection, high: room.north.reflection)
        let zs = axisImages(
            length: room.size.z, source: source.z, receiver: receiver.z, reach: reach,
            low: room.floor.reflection, high: room.ceiling.reflection)
        let air =
            airAbsorption
            ? OctaveBands.centres.map { atmosphere.amplitudeAttenuationPerMetre(frequency: $0) }
            : Array(repeating: 0, count: bands)
        var summary = Summary()
        var nearestOmitted = Double.infinity
        var gains = [Double](repeating: 0, count: bands)
        // Each list is sorted by distance, not strictly by order, so keep the lowest order from each
        // position onwards: once even that exceeds the limit, nothing further along can be heard, and the
        // first such image is the nearest omitted one.
        let yLeast = Self.suffixMinimumOrder(ys)
        let zLeast = Self.suffixMinimumOrder(zs)
        let z0 = zs.first.map { $0.offset * $0.offset } ?? 0
        let y0 = ys.first.map { $0.offset * $0.offset } ?? 0
        func omit(_ r2: Double) {
            if r2 <= reach2 { nearestOmitted = min(nearestOmitted, r2.squareRoot()) }
        }
        for x in xs {
            let x2 = x.offset * x.offset
            if x2 > reach2 || stop() { break }
            guard x.order + (yLeast.first ?? 0) + (zLeast.first ?? 0) <= maximumOrder else {
                omit(x2 + y0 + z0)
                continue
            }
            for (j, y) in ys.enumerated() {
                let xy2 = x2 + y.offset * y.offset
                if xy2 > reach2 { break }
                if x.order + yLeast[j] + (zLeast.first ?? 0) > maximumOrder {
                    omit(xy2 + z0)
                    break
                }
                for (k, z) in zs.enumerated() {
                    let r2 = xy2 + z.offset * z.offset
                    if r2 > reach2 { break }
                    if x.order + y.order + zLeast[k] > maximumOrder {
                        omit(r2)
                        break
                    }
                    let order = x.order + y.order + z.order
                    let r = r2.squareRoot()
                    if order > maximumOrder {
                        omit(r2)
                        continue
                    }
                    if order == 0 && !includeDirect { continue }
                    let spreading = 1 / r
                    var audible = false
                    for b in 0..<bands {
                        let g = x.gains[b] * y.gains[b] * z.gains[b] * spreading * exp(-air[b] * r)
                        gains[b] = g
                        audible = audible || g > 0
                    }
                    guard audible else { continue }
                    summary.arrivals += 1
                    body(r / c, order, gains)
                }
            }
        }
        if nearestOmitted.isFinite { summary.orderLimitedAfter = nearestOmitted / c }
        return summary
    }

    /// For each position, the lowest reflection order at or after it.
    static func suffixMinimumOrder(_ images: [AxisImage]) -> [Int] {
        var least = images.map(\.order)
        for i in stride(from: least.count - 2, through: 0, by: -1) { least[i] = min(least[i], least[i + 1]) }
        return least
    }

    /// Images along one axis within `reach` of the receiver, sorted by distance.
    func axisImages(
        length: Double, source s: Double, receiver: Double, reach: Double, low: [Double], high: [Double]
    ) -> [AxisImage] {
        let first = Int(((receiver - reach - s) / (2 * length)).rounded(.down)) - 1
        let last = Int(((receiver + reach + s) / (2 * length)).rounded(.up)) + 1
        var images: [AxisImage] = []
        for n in first...last {
            for q in 0...1 {
                let position = Double(1 - 2 * q) * s + 2 * Double(n) * length
                let offset = position - receiver
                guard abs(offset) <= reach else { continue }
                let lowCount = abs(n - q)
                let highCount = abs(n)
                let gains = zip(low, high).map { pow($0, Double(lowCount)) * pow($1, Double(highCount)) }
                images.append(AxisImage(offset: offset, order: lowCount + highCount, gains: gains))
            }
        }
        return images.sorted { abs($0.offset) < abs($1.offset) }
    }
}
