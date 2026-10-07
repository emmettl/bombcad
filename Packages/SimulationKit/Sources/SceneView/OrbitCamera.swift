import Foundation
import SceneModel
import simd

/// Camera orbiting a target point; z is up.
public struct OrbitCamera: Sendable, Hashable {
    public var target: SIMD3<Float>
    public var distance: Float
    /// Angle around the vertical axis in radians.
    public var azimuth: Float
    /// Angle above the horizon in radians.
    public var elevation: Float
    /// Vertical field of view in radians.
    public var fieldOfView: Float = 0.75

    public init(target: SIMD3<Float>, distance: Float, azimuth: Float, elevation: Float) {
        self.target = target
        self.distance = distance
        self.azimuth = azimuth
        self.elevation = elevation
    }

    /// A three-quarter view framing axis-aligned bounds, including translated scenes.
    public static func framing(_ bounds: Box) -> OrbitCamera {
        OrbitCamera(
            target: (bounds.min + bounds.max) / 2,
            distance: max(3, 1.3 * simd_length(bounds.size)),
            azimuth: -2.45, elevation: 0.5)
    }

    public var eye: SIMD3<Float> {
        let horizontal = cos(elevation)
        return target + distance * SIMD3(horizontal * cos(azimuth), horizontal * sin(azimuth), sin(elevation))
    }

    /// The ray through a point of the view, given in normalised device coordinates (x right and
    /// y up, both from -1 to 1).
    public func ray(ndc: SIMD2<Float>, aspectRatio: Float) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)
    {
        let origin = eye
        let forward = simd_normalize(target - origin)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 0, 1)))
        let up = simd_cross(right, forward)
        let halfHeight = tan(fieldOfView / 2)
        let direction = forward + right * (ndc.x * halfHeight * aspectRatio) + up * (ndc.y * halfHeight)
        return (origin, simd_normalize(direction))
    }

    /// Where that ray meets the ground plane z = 0, if it does.
    public func groundPoint(ndc: SIMD2<Float>, aspectRatio: Float) -> SIMD3<Float>? {
        let (origin, direction) = ray(ndc: ndc, aspectRatio: aspectRatio)
        guard direction.z < -1e-6 else { return nil }
        return origin - direction * (origin.z / direction.z)
    }

    public mutating func orbit(deltaAzimuth: Float, deltaElevation: Float) {
        azimuth += deltaAzimuth
        elevation = min(max(elevation + deltaElevation, 0.03), 1.55)
    }

    public mutating func zoom(by factor: Float) {
        distance = min(max(distance * factor, 3), 600)
    }

    /// Slides the target parallel to the ground, in view-relative directions.
    public mutating func pan(right: Float, forward: Float) {
        let ahead = SIMD3(-cos(azimuth), -sin(azimuth), 0)
        let side = SIMD3(-ahead.y, ahead.x, 0)
        target += (side * -right + ahead * forward) * distance
    }
}
