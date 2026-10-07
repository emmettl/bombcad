import simd

/// Axis-aligned bounds in metres; z is up.
public struct Box: Sendable, Hashable, Codable {
    public var min: SIMD3<Float>
    public var max: SIMD3<Float>

    public init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }

    /// A block with the given footprint, rising from the ground to `height`.
    public init(x: ClosedRange<Float>, y: ClosedRange<Float>, height: Float) {
        self.init(
            min: SIMD3(x.lowerBound, y.lowerBound, 0), max: SIMD3(x.upperBound, y.upperBound, height))
    }

    public func contains(_ point: SIMD3<Float>) -> Bool {
        all(point .>= min) && all(point .< max)
    }

    public var size: SIMD3<Float> {
        get { max - min }
        set { max = min + newValue }
    }
}
