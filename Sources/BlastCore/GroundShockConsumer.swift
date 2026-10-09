import Foundation
import simd

/// What the blast did to the ground at one point, and the soil's response under it.
public struct GroundPointResult: Codable, Sendable, Equatable {
    public var position: SIMD2<Float>
    /// Whether a block or the structure stood on the point at every frame, leaving no open
    /// ground for the air to press on; such a point has no response.
    public var covered: Bool
    /// Peak overpressure, Pa, and positive impulse, Pa·s, on the ground, kept every time step.
    public var peakOverpressure: Float
    public var impulse: Float
    /// The triangular pulse's duration with that peak and impulse, s.
    public var duration: Float
    /// The first frame at which the peak had passed the arrival threshold, s: up to a frame late.
    public var arrival: Double?
    /// The air front's speed over the ground, m/s, by Rankine–Hugoniot from the peak.
    public var frontSpeed: Float
    /// How that front compares with the soil's wave speed; nil where no blast arrived.
    public var regime: GroundShockRegime?
    /// The response at each depth asked for.
    public var responses: [GroundResponse]
    /// The overpressure on the ground at every frame, Pa.
    public var history: [Float]

    public init(
        position: SIMD2<Float>, covered: Bool, peakOverpressure: Float, impulse: Float, duration: Float,
        arrival: Double?, frontSpeed: Float, regime: GroundShockRegime?, responses: [GroundResponse],
        history: [Float]
    ) {
        self.position = position
        self.covered = covered
        self.peakOverpressure = peakOverpressure
        self.impulse = impulse
        self.duration = duration
        self.arrival = arrival
        self.frontSpeed = frontSpeed
        self.regime = regime
        self.responses = responses
        self.history = history
    }
}

/// What a ground shock consumer found.
public struct GroundShockResult: Codable, Sendable, Equatable {
    public var soil: GroundSoil
    public var depths: [Float]
    public var frameInterval: Double
    public var frames: Int
    public var points: [GroundPointResult]
    /// The ground's air sent, bytes, and the wall-clock time the run spent cutting it out and
    /// consuming it, s.
    public var airBytes: Int
    public var seconds: Double

    public init(
        soil: GroundSoil, depths: [Float], frameInterval: Double, frames: Int, points: [GroundPointResult],
        airBytes: Int = 0, seconds: Double = 0
    ) {
        self.soil = soil
        self.depths = depths
        self.frameInterval = frameInterval
        self.frames = frames
        self.points = points
        self.airBytes = airBytes
        self.seconds = seconds
    }

    public var summary: String {
        let open = points.filter { !$0.covered }
        let covered = points.count - open.count
        let transseismic = open.filter { $0.regime == .transseismic }.count
        let outrunning = open.filter { $0.regime == .outrunning }.count
        var text = String(
            format: "Ground shock at %d points, soil %.0f kg/m³ at %.0f m/s", points.count, soil.density,
            soil.waveSpeed)
        if let top = open.max(by: {
            ($0.responses.first?.verticalVelocity ?? 0) < ($1.responses.first?.verticalVelocity ?? 0)
        }), let response = top.responses.first {
            text += String(
                format: ": fastest %.0f mm/s down at %.1f m depth under (%.1f, %.1f), %.0f kPa on the ground",
                response.verticalVelocity * 1000, response.depth, top.position.x, top.position.y,
                top.peakOverpressure / 1000)
        }
        if transseismic > 0 { text += "; no horizontal estimate at \(transseismic) where the front nears c" }
        if outrunning > 0 { text += "; outrun by the ground's wave at \(outrunning)" }
        if covered > 0 { text += "; \(covered) under a block or the structure" }
        text += String(
            format: "; %.1f MB of ground air in %d frames, %.3f s", Double(airBytes) / 1e6, frames, seconds)
        return text
    }
}

/// Estimates the ground's shaking frame by frame from the air a producer sends: the bottom layer
/// of cells under the points, frame 0 at time zero, then each later one. Pure CPU work, and
/// little of it: a sample a point a frame.
public struct GroundShockConsumer: Sendable {
    public let spec: GroundShockSpec
    public let points: [SIMD2<Float>]
    public private(set) var frame = -1
    /// Bytes of air consumed so far.
    public private(set) var bytes = 0
    private var histories: [[Float]]
    private var latest: [GroundSlice.Sample?]
    /// The highest overpressure each point has seen: the solver's peak, or a frame's value where
    /// higher, as in the blast laid down at time zero, before the solver's first step.
    private var peaks: [Float]
    private var arrivals: [Double?]
    private var air = (density: Float(1.225), pressure: Float(101_325), gamma: Float(1.4))

    public init(spec: GroundShockSpec) {
        self.spec = spec
        points = spec.allPoints
        histories = Array(repeating: [], count: points.count)
        latest = Array(repeating: nil, count: points.count)
        peaks = Array(repeating: 0, count: points.count)
        arrivals = Array(repeating: nil, count: points.count)
    }

    /// The rectangle of ground to send, (x, y) in metres: the points' bounds and a cell round them.
    public func region(cellSize: Float) -> (low: SIMD2<Float>, high: SIMD2<Float>) {
        let low = points.dropFirst().reduce(points[0], simd_min)
        let high = points.dropFirst().reduce(points[0], simd_max)
        return (low - cellSize, high + cellSize)
    }

    public mutating func consume(_ slice: GroundSlice) {
        frame += 1
        bytes += 4 * slice.values.count
        air = (slice.ambientDensity, slice.ambientPressure, slice.gamma)
        for n in points.indices {
            let sample = slice.sample(points[n])
            histories[n].append(sample?.overpressure ?? 0)
            guard let sample else { continue }
            latest[n] = sample
            peaks[n] = max(peaks[n], sample.peak, sample.overpressure)
            if arrivals[n] == nil, peaks[n] >= spec.arrivalThreshold { arrivals[n] = slice.time }
        }
    }

    public func result(frameInterval: Double) -> GroundShockResult {
        let points = self.points.indices.map { n in
            let sample = latest[n]
            let peak = peaks[n]
            let impulse = max(sample?.impulse ?? 0, 0)
            let speed = AirInducedGroundShock.frontSpeed(
                overpressure: peak, ambientPressure: air.pressure, ambientDensity: air.density,
                gamma: air.gamma)
            return GroundPointResult(
                position: self.points[n], covered: sample == nil, peakOverpressure: peak, impulse: impulse,
                duration: AirInducedGroundShock.duration(peak: peak, impulse: impulse), arrival: arrivals[n],
                frontSpeed: speed,
                regime: peak > 0 ? GroundShockRegime(frontSpeed: speed, soil: spec.soil) : nil,
                responses: spec.depths.map { depth in
                    AirInducedGroundShock.response(
                        peak: peak, impulse: impulse, arrival: arrivals[n], depth: depth, soil: spec.soil,
                        frontSpeed: speed)
                }, history: histories[n])
        }
        return GroundShockResult(
            soil: spec.soil, depths: spec.depths, frameInterval: frameInterval, frames: frame + 1,
            points: points, airBytes: bytes)
    }
}
