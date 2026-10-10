import Foundation
import simd

/// What the blast did to the ground at one point, and the soil's response under it.
///
/// Over a terrain the point is on its surface, the overpressure is the first cell of air above it
/// (`GroundSlice`), and the soil column runs along the surface's normal there, not straight
/// down: the air presses square on the surface, and a column is a plane wave sent into a
/// half-space from its loaded face, which travels along the face's normal. So on a slope the
/// column's depths, stress, "vertical" velocity and displacement are along that normal into the
/// ground, its layers lie parallel to the surface, and its answer is the level ground's under
/// the same load; `normal` gives the direction to resolve them. On flat ground the normal is
/// vertical and nothing differs.
public struct GroundPointResult: Codable, Sendable, Equatable {
    public var position: SIMD2<Float>
    /// Over a terrain, the surface's height at the point, m, and its upward unit normal there,
    /// the column's axis (out of the ground); nil on flat ground.
    public var elevation: Float?
    public var normal: SIMD3<Float>?
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
    /// The column's only: its peaks from the surface down.
    public var profile: GroundDepthProfile?

    public init(
        position: SIMD2<Float>, covered: Bool, peakOverpressure: Float, impulse: Float, duration: Float,
        arrival: Double?, frontSpeed: Float, regime: GroundShockRegime?, responses: [GroundResponse],
        history: [Float], profile: GroundDepthProfile? = nil
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
        self.profile = profile
    }
}

/// A column's peaks at evenly spaced depths from the surface down to the deepest asked for.
public struct GroundDepthProfile: Codable, Sendable, Equatable {
    /// Metres down.
    public var depths: [Float]
    /// Peak vertical stress, Pa; peak downward velocity, m/s; peak downward displacement and
    /// that left at the last frame, m.
    public var stress: [Float]
    public var velocity: [Float]
    public var displacement: [Float]
    public var residualDisplacement: [Float]

    public init(
        depths: [Float], stress: [Float], velocity: [Float], displacement: [Float],
        residualDisplacement: [Float]
    ) {
        self.depths = depths
        self.stress = stress
        self.velocity = velocity
        self.displacement = displacement
        self.residualDisplacement = residualDisplacement
    }

    /// How many depths a profile gives.
    public static let levels = 25
}

extension GroundPointResult {
    /// The peak downward velocity of the ground's surface, m/s, whatever depths were asked for:
    /// the column's own, or the plane-wave relation's in `soil`.
    public func surfaceVelocity(in soil: GroundSoil) -> Float {
        covered ? 0 : profile?.velocity.first ?? peakOverpressure / soil.impedance
    }
}

extension GroundPointResult {
    /// Where the point is drawn: 5 cm off the ground, along its normal over a terrain.
    public var marker: SIMD3<Float> {
        SIMD3(position.x, position.y, elevation ?? 0) + 0.05 * (normal ?? SIMD3(0, 0, 1))
    }
}

extension GroundShockResult {
    /// The points as dots to draw just above the ground: grey until the blast reaches them, then
    /// coloured by how fast the ground's surface moved, from 1 mm/s to 10 m/s on a log scale.
    /// Points under a block or the structure are left out. Each is a position and a code: kind 3
    /// (see `SceneRenderer.setDots`) plus that value, 0 before the blast arrives.
    public var dots: [SIMD4<Float>] {
        points.compactMap { point in
            guard !point.covered else { return nil }
            let speed = point.surfaceVelocity(in: soil)
            let value = point.arrival == nil ? 0 : min(max(log10(max(speed, 1e-3) / 1e-3) / 4, 0.001), 0.999)
            return SIMD4(point.marker, 3 + value)
        }
    }

    /// Sets each point's place on `terrain`: its height and normal, or none on flat ground.
    public mutating func place(on terrain: Terrain?) {
        let terrain = terrain.flatMap { $0.isFlat ? nil : $0 }
        for n in points.indices {
            points[n].elevation = terrain?.height(at: points[n].position)
            points[n].normal = terrain?.normal(at: points[n].position)
        }
    }
}

extension GroundShockSpec {
    /// The rectangle of ground to send, (x, y) in metres: the points' bounds and a cell round them.
    public func region(cellSize: Float) -> (low: SIMD2<Float>, high: SIMD2<Float>) {
        let points = allPoints
        let low = points.dropFirst().reduce(points[0], simd_min)
        let high = points.dropFirst().reduce(points[0], simd_max)
        return (low - cellSize, high + cellSize)
    }

    /// The points as grey dots, before a run reaches them, on `terrain` if there is one.
    public func dots(on terrain: Terrain? = nil) -> [SIMD4<Float>] {
        allPoints.map { point in
            let normal = terrain?.normal(at: point) ?? SIMD3(0, 0, 1)
            return SIMD4(SIMD3(point.x, point.y, terrain?.height(at: point) ?? 0) + 0.05 * normal, 3)
        }
    }
}

/// What a ground shock consumer found.
public struct GroundShockResult: Codable, Sendable, Equatable {
    public var soil: GroundSoil
    /// The model used, and the column's soil; nil in results from before the column, the estimate.
    public var model: GroundShockModel?
    public var profile: SoilProfile?
    /// Each frame's time, s, for the histories; nil in a kept run, which has none.
    public var frameTimes: [Double]?
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
        airBytes: Int = 0, seconds: Double = 0, model: GroundShockModel? = nil, profile: SoilProfile? = nil,
        frameTimes: [Double]? = nil
    ) {
        self.frameTimes = frameTimes
        self.soil = soil
        self.model = model
        self.profile = profile
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
        var text: String
        if model == .column, let profile {
            text = String(
                format: "Ground shock at %d points, a column of %d layer%@ from %.0f kg/m³ at %.0f m/s",
                points.count, profile.layers.count, profile.layers.count == 1 ? "" : "s",
                profile.surface.density, profile.surface.waveSpeed)
        } else {
            text = String(
                format: "Ground shock at %d points, soil %.0f kg/m³ at %.0f m/s", points.count, soil.density,
                soil.waveSpeed)
        }
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
    private var times: [Double] = []
    private var latest: [GroundSlice.Sample?]
    /// The highest overpressure each point has seen: the solver's peak, or a frame's value where
    /// higher, as in the blast laid down at time zero, before the solver's first step.
    private var peaks: [Float]
    private var arrivals: [Double?]
    private var air = (density: Float(1.225), pressure: Float(101_325), gamma: Float(1.4))
    /// The column's: each point's load rebuilt between frames, its soil column, and the
    /// downward velocity at each depth at each frame.
    private var loads: [GroundLoad] = []
    private var columns: [SoilColumn] = []
    private var motions: [[[Float]]] = []

    /// The fewest of the column's steps a shock rises over.
    public static let riseSteps = 12.0

    public init(spec: GroundShockSpec) {
        self.spec = spec
        points = spec.allPoints
        histories = Array(repeating: [], count: points.count)
        latest = Array(repeating: nil, count: points.count)
        peaks = Array(repeating: 0, count: points.count)
        arrivals = Array(repeating: nil, count: points.count)
        if spec.model == .column {
            let column = SoilColumn(
                profile: spec.columnProfile, depth: spec.depths.max() ?? 0,
                arrivalThreshold: spec.arrivalThreshold)
            loads = Array(repeating: GroundLoad(), count: points.count)
            columns = Array(repeating: column, count: points.count)
            motions = Array(repeating: Array(repeating: [], count: spec.depths.count), count: points.count)
        }
    }

    /// The rectangle of ground to send, (x, y) in metres: the points' bounds and a cell round them.
    public func region(cellSize: Float) -> (low: SIMD2<Float>, high: SIMD2<Float>) {
        spec.region(cellSize: cellSize)
    }

    public mutating func consume(_ slice: GroundSlice) {
        frame += 1
        times.append(slice.time)
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
        guard !columns.isEmpty else { return }
        for n in points.indices {
            // Nothing for a point never yet open; one under a block or the structure for a frame
            // carries nothing then.
            guard let sample = latest[n] else { continue }
            // A shock rises over the time its front takes to cross a cell, and over no fewer than
            // a dozen of the column's steps: faster, and the surface's node rings, up to two
            // fifths too fast in soil that unloads stiffly.
            let speed = AirInducedGroundShock.frontSpeed(
                overpressure: peaks[n], ambientPressure: air.pressure, ambientDensity: air.density,
                gamma: air.gamma)
            let rise = max(Double(slice.cellSize / speed), Self.riseSteps * columns[n].timeStep)
            loads[n].append(
                time: slice.time, overpressure: histories[n].last ?? 0, peak: peaks[n],
                impulse: max(sample.impulse, 0), rise: rise)
            columns[n].advance(to: slice.time, load: loads[n])
            loads[n].forget(before: columns[n].time - columns[n].timeStep)
            let velocity = columns[n].velocities
            if motions[n][0].count < histories[n].count - 1 {
                // Still before it was first open.
                for d in spec.depths.indices {
                    motions[n][d] += Array(repeating: 0, count: histories[n].count - 1 - motions[n][d].count)
                }
            }
            for (d, depth) in spec.depths.enumerated() {
                motions[n][d].append(Float(columns[n].atNodes(velocity, depth: Double(depth))))
            }
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
            var result = GroundPointResult(
                position: self.points[n], covered: sample == nil, peakOverpressure: peak, impulse: impulse,
                duration: AirInducedGroundShock.duration(peak: peak, impulse: impulse), arrival: arrivals[n],
                frontSpeed: speed,
                regime: peak > 0 ? GroundShockRegime(frontSpeed: speed, soil: spec.surfaceSoil) : nil,
                responses: spec.depths.map { depth in
                    AirInducedGroundShock.response(
                        peak: peak, impulse: impulse, arrival: arrivals[n], depth: depth, soil: spec.soil,
                        frontSpeed: speed)
                }, history: histories[n])
            if !columns.isEmpty, sample != nil {
                columnResponse(n, frontSpeed: speed, into: &result)
            }
            return result
        }
        return GroundShockResult(
            soil: spec.soil, depths: spec.depths, frameInterval: frameInterval, frames: frame + 1,
            points: points, airBytes: bytes, model: spec.model,
            profile: spec.model == .column ? spec.columnProfile : nil, frameTimes: times)
    }

    /// The column's peaks at the depths asked for and down its profile.
    private func columnResponse(_ n: Int, frontSpeed: Float, into result: inout GroundPointResult) {
        let column = columns[n]
        let (stress, velocity, displacement, now) = (
            column.peakStress, column.peakVelocity, column.peakDisplacement, column.displacements
        )
        let arrivals = column.arrivals
        let surface = max(column.peakLoad, 0)
        func at(_ depth: Float) -> (stress: Float, velocity: Float, displacement: Float, residual: Float) {
            let z = Double(depth)
            return (
                Float(column.atElements(stress, depth: z, surface: surface)),
                Float(column.atNodes(velocity, depth: z)), Float(column.atNodes(displacement, depth: z)),
                Float(column.atNodes(now, depth: z))
            )
        }
        result.responses = spec.depths.enumerated().map { d, depth in
            let peak = at(depth)
            // The wave's arrival at the element nearest the depth; on the ground, the blast's.
            var arrival = self.arrivals[n]
            if depth > 0 {
                let mids = column.elementDepths
                let nearest = mids.indices.min {
                    abs(mids[$0] - Double(depth)) < abs(mids[$1] - Double(depth))
                }
                arrival = nearest.flatMap { arrivals[$0] >= 0 ? arrivals[$0] : nil }
            }
            let horizontal = spec.columnProfile.waveSpeed(at: depth).flatMap {
                AirInducedGroundShock.horizontalVelocity(
                    vertical: peak.velocity, waveSpeed: $0, frontSpeed: frontSpeed)
            }
            return GroundResponse(
                depth: depth, stress: peak.stress, verticalVelocity: peak.velocity,
                verticalDisplacement: peak.displacement, horizontalVelocity: horizontal, arrival: arrival,
                residualDisplacement: peak.residual, history: motions[n][d])
        }
        let deepest = spec.depths.max() ?? 0
        let levels = (0..<GroundDepthProfile.levels).map {
            deepest * Float($0) / Float(GroundDepthProfile.levels - 1)
        }
        let peaks = levels.map(at)
        result.profile = GroundDepthProfile(
            depths: levels, stress: peaks.map(\.stress), velocity: peaks.map(\.velocity),
            displacement: peaks.map(\.displacement), residualDisplacement: peaks.map(\.residual))
    }
}
