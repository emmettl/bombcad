import Foundation
import simd

/// A segment from a receiver toward a point on the fireball: whether it gets there is what a
/// `ThermalVisibility` answers.
public struct ThermalRay: Sendable, Equatable {
    public var origin: SIMD3<Float>
    /// A unit vector.
    public var direction: SIMD3<Float>
    /// How far along `direction` the segment runs, in metres.
    public var length: Float

    public init(origin: SIMD3<Float>, direction: SIMD3<Float>, length: Float) {
        self.origin = origin
        self.direction = direction
        self.length = length
    }

    /// The segment's far end.
    public var end: SIMD3<Float> { origin + length * direction }
}

/// What stands between the receivers and the fireball: the ground, the blocks and the structure's
/// starting outline. Asked about many segments at once, so that an implementation can test them
/// together.
public protocol ThermalVisibility: Sendable {
    /// Whether each ray reaches its end with nothing in the way, one a ray, in order.
    func visible(_ rays: [ThermalRay]) -> [Bool]
}

/// The visibility test on the CPU's cores: each segment against the ground and every box in turn.
public struct CPUThermalVisibility: ThermalVisibility {
    public let occluders: [Box]

    public init(occluders: [Box]) {
        self.occluders = occluders
    }

    public func visible(_ rays: [ThermalRay]) -> [Bool] {
        let chunk = 4096
        return [Bool](unsafeUninitializedCapacity: rays.count) { result, count in
            DispatchQueue.concurrentPerform(iterations: (rays.count + chunk - 1) / chunk) { c in
                for n in c * chunk..<min((c + 1) * chunk, rays.count) {
                    (result.baseAddress! + n).initialize(to: visible(rays[n]))
                }
            }
            count = rays.count
        }
    }

    /// Whether one ray's end is above the ground and no box lies across it.
    public func visible(_ ray: ThermalRay) -> Bool {
        let end = ray.end
        guard end.z >= 0 else { return false }
        return !occluders.contains { Self.blocks($0, from: ray.origin, to: end) }
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
