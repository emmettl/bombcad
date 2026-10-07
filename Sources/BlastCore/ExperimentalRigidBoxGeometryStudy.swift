import Foundation
import simd

/// CPU-only fractional occupancy study. No gas states, contact impulses or app masks are changed.
public enum ExperimentalRigidBoxGeometryStudy {
    public struct Result: Codable, Sendable {
        public let kind: String
        public let cellSize: Double
        public let translation: Double
        public let angle: Double
        public let gap: Double?
        public let solidVolume: Double
        public let centreMaskVolume: Double
        public let wallArea: Double
        public let uniformPressureForce: SIMD3<Double>
        public let uniformPressureTorque: SIMD3<Double>
        public let maximumCellAreaResidual: Double
        public let maximumCellMomentResidual: Double
        public let maximumCellVolumeResidual: Double
        public let groundCellOpenVolumeFraction: Double?
        public let groundCellOpenFaces: [Double]?
        public let computeSeconds: Double
    }

    public static func run() throws -> [Result] {
        var results: [Result] = []
        for h in [0.2, 0.1, 0.05] {
            for rotate in [false, true] {
                for step in 0...12 {
                    let translation = Double(step) * 0.01
                    let angle = rotate ? Double(step) * (5 * .pi / 180) / 12 : 0
                    let body = try RigidBoxBody(
                        mass: 2, size: SIMD3(repeating: 0.8), position: SIMD3(2.095 + translation, 2, 2),
                        orientation: simd_quatd(angle: angle, axis: SIMD3(0, 1, 0)))
                    results.append(
                        measure(
                            body, cellSize: h, kind: rotate ? "translation-rotation" : "translation",
                            translation: translation, angle: angle, gap: nil))
                }
            }
            for gap in [0.0, 0.00001, 0.001, 0.025] {
                let body = try RigidBoxBody(
                    mass: 2, size: SIMD3(repeating: 0.8), position: SIMD3(2, 2, 0.4 + gap))
                results.append(
                    measure(body, cellSize: h, kind: "ground-gap", translation: 0, angle: 0, gap: gap))
            }
        }
        return results
    }

    private static func measure(
        _ body: RigidBoxBody, cellSize h: Double, kind: String, translation: Double, angle: Double,
        gap: Double?
    ) -> Result {
        let started = Date.timeIntervalSinceReferenceDate
        let geometry = FractionalBoxGeometry(body)
        let low = body.corners.reduce(SIMD3<Double>(repeating: .infinity), simd_min)
        let high = body.corners.reduce(SIMD3<Double>(repeating: -.infinity), simd_max)
        // Include both sides of grid-aligned walls. Ground cases include virtual cells below
        // z=0 for full-box surface identities; this is not a physical ground-pressure load.
        let first = SIMD3<Int>((low / h).rounded(.down)) &- 1
        let last = SIMD3<Int>((high / h).rounded(.up)) &+ 1
        var volume = 0.0
        var count = 0
        var wallArea = 0.0
        var areaError = 0.0
        var momentError = 0.0
        var volumeError = 0.0
        var force = SIMD3<Double>.zero
        var torque = SIMD3<Double>.zero
        for k in first.z...last.z {
            for j in first.y...last.y {
                for i in first.x...last.x {
                    let lower = h * SIMD3<Double>(Double(i), Double(j), Double(k))
                    let solid = geometry.solidVolumeFraction(lower: lower, cellSize: h) * h * h * h
                    volume += solid
                    if geometry.contains(lower + SIMD3(repeating: h / 2)) { count += 1 }
                    let origin = lower + SIMD3(repeating: h / 2)
                    var areaBalance = SIMD3<Double>.zero
                    var momentBalance = SIMD3<Double>.zero
                    var measuredVolume = 0.0
                    for face in geometry.openFacePatches(lower: lower, cellSize: h) {
                        let vector = face.area * face.normal
                        areaBalance += vector
                        momentBalance += simd_cross(face.centroid - origin, vector)
                        measuredVolume += simd_dot(face.centroid - origin, vector) / 3
                    }
                    for wall in geometry.wallPatches(lower: lower, cellSize: h) {
                        let vector = wall.area * wall.normal
                        areaBalance -= vector
                        momentBalance -= simd_cross(wall.centroid - origin, vector)
                        measuredVolume -= simd_dot(wall.centroid - origin, vector) / 3
                        wallArea += wall.area
                        force -= 101325 * vector
                        torque -= simd_cross(wall.centroid - body.position, 101325 * vector)
                    }
                    areaError = max(areaError, simd_length(areaBalance))
                    momentError = max(momentError, simd_length(momentBalance))
                    volumeError = max(volumeError, abs(measuredVolume - (h * h * h - solid)))
                }
            }
        }
        // One horizontal cell strictly inside the footprint, touching the domain ground.
        let groundLower = SIMD3<Double>(2 - h, 2 - h, 0)
        return Result(
            kind: kind, cellSize: h, translation: translation, angle: angle, gap: gap,
            solidVolume: volume, centreMaskVolume: Double(count) * h * h * h,
            wallArea: wallArea, uniformPressureForce: force, uniformPressureTorque: torque,
            maximumCellAreaResidual: areaError, maximumCellMomentResidual: momentError,
            maximumCellVolumeResidual: volumeError,
            groundCellOpenVolumeFraction: gap == nil
                ? nil : 1 - geometry.solidVolumeFraction(lower: groundLower, cellSize: h),
            groundCellOpenFaces: gap == nil
                ? nil : geometry.openFaceFractions(lower: groundLower, cellSize: h),
            computeSeconds: Date.timeIntervalSinceReferenceDate - started)
    }
}
