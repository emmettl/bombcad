import BlastCore
import SceneView
import simd

/// Compatibility name for existing BombCAD clients.
public typealias OrbitCamera = SceneView.OrbitCamera

extension OrbitCamera {
    /// A three-quarter view that frames the whole scenario.
    public static func framing(_ scenario: Scenario) -> OrbitCamera {
        if let structure = scenario.structuralObjects.first?.structure {
            // Close in on the structure and the charge rather than the whole domain.
            let bounds = scenario.structuralObjects.dropFirst().reduce(structure.bounds) { bounds, object in
                Box(
                    min: simd_min(bounds.min, object.structure!.bounds.min),
                    max: simd_max(bounds.max, object.structure!.bounds.max))
            }
            let low = simd_min(bounds.min, scenario.charge.position)
            let high = simd_max(bounds.max, scenario.charge.position)
            let centre = (bounds.min + bounds.max) / 2
            return OrbitCamera(
                target: SIMD3(centre.x, centre.y, bounds.max.z * 0.4),
                distance: 1.3 * simd_length(high - low), azimuth: -2.45, elevation: 0.5)
        }
        let size = scenario.domainSize
        return OrbitCamera(
            target: SIMD3(size.x / 2, size.y / 2, size.z * 0.2),
            distance: 1.55 * max(size.x, size.y), azimuth: -2.75, elevation: 0.8)
    }

}
