import Foundation
import simd

/// A segment from a receiver toward a point on the fireball: whether it gets there is what a
/// `ThermalVisibility` answers.
public struct ThermalRay: Sendable, Equatable {
    // Seven floats with no padding, as the GPU reads them: a frame has half a million.
    private var originX, originY, originZ: Float
    private var directionX, directionY, directionZ: Float
    /// How far along `direction` the segment runs, in metres.
    public var length: Float

    public init(origin: SIMD3<Float>, direction: SIMD3<Float>, length: Float) {
        (originX, originY, originZ) = (origin.x, origin.y, origin.z)
        (directionX, directionY, directionZ) = (direction.x, direction.y, direction.z)
        self.length = length
    }

    public var origin: SIMD3<Float> {
        get { SIMD3(originX, originY, originZ) }
        set { (originX, originY, originZ) = (newValue.x, newValue.y, newValue.z) }
    }

    /// A unit vector.
    public var direction: SIMD3<Float> {
        get { SIMD3(directionX, directionY, directionZ) }
        set { (directionX, directionY, directionZ) = (newValue.x, newValue.y, newValue.z) }
    }

    /// The segment's far end.
    public var end: SIMD3<Float> { origin + length * direction }
}

/// What stands between the receivers and the fireball: the ground (the terrain, where there is
/// one), the blocks and the structure's starting outline. Asked about many segments at once, so that an implementation can test them
/// together.
public protocol ThermalVisibility: Sendable {
    /// Whether each ray reaches its end with nothing in the way, one a ray, in order.
    func visible(_ rays: [ThermalRay]) -> [Bool]
}

/// The visibility test on the CPU's cores: each segment against the ground, every box in turn and
/// the terrain's cells under it.
public struct CPUThermalVisibility: ThermalVisibility {
    public let occluders: [Box]
    /// Nil for flat ground.
    public let terrain: TerrainSight?

    public init(occluders: [Box], terrain: Terrain? = nil) {
        self.occluders = occluders
        self.terrain = TerrainSight(terrain)
    }

    public func visible(_ rays: [ThermalRay]) -> [Bool] {
        visible(rays, until: { false })!
    }

    /// As `visible(_:)`, but given up, returning nil, once `stop` says so; it is asked between
    /// chunks of a few thousand rays.
    func visible(_ rays: [ThermalRay], until stop: () -> Bool) -> [Bool]? {
        let chunk = 4096
        let chunks = (rays.count + chunk - 1) / chunk
        var stopped = false
        let result = [Bool](unsafeUninitializedCapacity: rays.count) { result, count in
            // Every element is written, stopped or not, so the array is always whole.
            let stopping = Flag()
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let range = c * chunk..<min((c + 1) * chunk, rays.count)
                if stopping.isSet || stop() {
                    stopping.set()
                    for n in range { (result.baseAddress! + n).initialize(to: false) }
                    return
                }
                for n in range { (result.baseAddress! + n).initialize(to: visible(rays[n])) }
            }
            stopped = stopping.isSet
            count = rays.count
        }
        return stopped ? nil : result
    }

    /// Whether one ray's end is above the ground, no box lies across it and it does not pass
    /// under the terrain.
    public func visible(_ ray: ThermalRay) -> Bool {
        let end = ray.end
        guard end.z >= 0 else { return false }
        if occluders.contains(where: { Self.blocks($0, from: ray.origin, to: end) }) { return false }
        return !(terrain?.blocks(from: ray.origin, to: end) ?? false)
    }

    /// Whether `box` lies across the segment from `start` to `end`; an end inside it counts.
    static func blocks(_ box: Box, from start: SIMD3<Float>, to end: SIMD3<Float>) -> Bool {
        let delta = end - start
        var low: Float = 0
        var high: Float = 1
        for axis in 0..<3 {
            if abs(delta[axis]) < 1e-12 {
                if start[axis] < box.min[axis] || start[axis] > box.max[axis] { return false }
                continue
            }
            var a = (box.min[axis] - start[axis]) / delta[axis]
            var b = (box.max[axis] - start[axis]) / delta[axis]
            if a > b { swap(&a, &b) }
            low = max(low, a)
            high = min(high, b)
            if low > high { return false }
        }
        return true
    }
}

/// A flag set once, from any thread.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
}
