import Foundation
import simd

/// Where a consumer's particles are after its last frame, for the producer to choose the next
/// frames' air from.
public struct ConsumerReport: Codable, Sendable, Equatable {
    /// The last frame consumed, -1 before the first.
    public var frame: Int
    /// The airborne particles' bounds, nil once all have landed.
    public var low: SIMD3<Float>?
    public var high: SIMD3<Float>?
    /// The fastest an airborne particle, or the air carrying a tracer, may be moving.
    public var speed: Float
    public var airborne: Int

    public init(frame: Int, low: SIMD3<Float>?, high: SIMD3<Float>?, speed: Float, airborne: Int) {
        self.frame = frame
        self.low = low
        self.high = high
        self.speed = speed
        self.airborne = airborne
    }

    /// The air to send for `frame`: the particles' bounds grown by as far as they can travel
    /// from the frame reported to the one after `frame`, and a cell, within the domain; and the
    /// stride that keeps it to `cap` samples.
    public func region(
        for frame: Int, interval: Double, domain: SIMD3<Float>, cellSize: Float, cap: Int = 1 << 20
    ) -> (box: Box, stride: Int) {
        guard let low, let high else {
            return (Box(min: .zero, max: SIMD3(repeating: cellSize)), 1)
        }
        let frames = Float(max(frame - self.frame, 0) + 1)
        let margin = speed * frames * Float(interval) + cellSize
        let box = Box(min: simd_max(low - margin, .zero), max: simd_min(high + margin, domain))
        let cells = simd_max(box.size / cellSize, SIMD3(repeating: 1))
        let count = Double(cells.x) * Double(cells.y) * Double(cells.z)
        return (box, max(1, Int(cbrt(count / Double(cap)).rounded(.up))))
    }
}

/// What a fragment consumer found.
public struct FragmentResult: Codable, Sendable, Equatable {
    public var launchSpeed: Float
    public var masses: [Float]
    public var impacts: [FragmentImpact]
    public var airborne: Int
    /// Particles' positions at every frame, fragments first, then tracers.
    public var frames: [[SIMD3<Float>]]
    public var fragmentCount: Int
    public var frameInterval: Double
    /// Samples the air given did not cover: the region asked for was too small.
    public var misses: Int

    public init(
        launchSpeed: Float, masses: [Float], impacts: [FragmentImpact], airborne: Int,
        frames: [[SIMD3<Float>]],
        fragmentCount: Int, frameInterval: Double, misses: Int
    ) {
        self.launchSpeed = launchSpeed
        self.masses = masses
        self.impacts = impacts
        self.airborne = airborne
        self.frames = frames
        self.fragmentCount = fragmentCount
        self.frameInterval = frameInterval
        self.misses = misses
    }

    public var summary: String {
        let energy = impacts.map(\.energy).max() ?? 0
        let surfaces = Dictionary(grouping: impacts, by: \.surface).mapValues(\.count)
            .sorted { $0.key < $1.key }.map { "\($0.value) on \($0.key)" }.joined(separator: ", ")
        return String(
            format: "%d fragments at %.0f m/s: %d landed (%@), highest impact energy %.0f J",
            fragmentCount, launchSpeed, impacts.count, surfaces.isEmpty ? "none" : surfaces, energy)
            + (misses > 0 ? "; \(misses) samples fell outside the air sent" : "")
    }
}

/// Flies a `FragmentCloud` frame by frame through the air a producer sends: frame 0 at time zero,
/// then each later one. Pure CPU work, the same wherever it runs.
public struct FragmentConsumer: Sendable {
    public private(set) var cloud: FragmentCloud
    public private(set) var frames: [[SIMD3<Float>]] = []
    public private(set) var frame = -1
    private var last: AirSlice?
    /// The air's speed a tracer may ride, for the regions asked for.
    private let tracerSpeed: Float

    public init(spec: FragmentSpec, scene: FragmentScene) {
        cloud = FragmentCloud(spec: spec, scene: scene)
        tracerSpeed = spec.tracers > 0 ? 500 : 0
    }

    public mutating func consume(_ slice: AirSlice) {
        if let last { cloud.advance(from: last, to: slice) }
        last = slice
        frame += 1
        frames.append(cloud.particles.map(\.position))
    }

    public var report: ConsumerReport {
        let region = cloud.region(ahead: 0, slowest: tracerSpeed)
        return ConsumerReport(
            frame: frame, low: region?.box.min, high: region?.box.max,
            speed: max(region?.speed ?? 0, cloud.launchSpeed), airborne: cloud.airborne)
    }

    public func result(frameInterval: Double) -> FragmentResult {
        FragmentResult(
            launchSpeed: cloud.launchSpeed, masses: cloud.particles.prefix(cloud.fragmentCount).map(\.mass),
            impacts: cloud.impacts, airborne: cloud.airborne, frames: frames,
            fragmentCount: cloud.fragmentCount,
            frameInterval: frameInterval, misses: cloud.misses)
    }
}
