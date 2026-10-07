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
        for x in xs {
            let x2 = x.offset * x.offset
            if x2 > reach2 || stop() { break }
            for y in ys {
                let xy2 = x2 + y.offset * y.offset
                if xy2 > reach2 { break }
                for z in zs {
                    let r2 = xy2 + z.offset * z.offset
                    if r2 > reach2 { break }
                    let order = x.order + y.order + z.order
                    let r = r2.squareRoot()
                    if order > maximumOrder {
                        nearestOmitted = min(nearestOmitted, r)
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
