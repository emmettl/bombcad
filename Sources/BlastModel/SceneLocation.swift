import Foundation
import simd

/// Where a scene lies on the map (emmettl/bombcad-work#116), kept with a File ▸ New District project
/// (`location.json`) so that a survey's longitudes and latitudes land on its buildings as they were
/// placed. A project saved before has none.
public struct SceneLocation: Codable, Sendable, Equatable {
    /// One mapping onto the scene's metres: `MapBuildingPlacement.position` about this longitude
    /// and latitude (its origin; the cosine is the origin's own), then moved east and north.
    public struct Frame: Codable, Sendable, Equatable {
        public var longitude: Double
        public var latitude: Double
        public var eastM: Double
        public var northM: Double

        public init(corner: SIMD2<Double>, shift: SIMD2<Double> = .zero) {
            longitude = corner.x
            latitude = corner.y
            eastM = shift.x
            northM = shift.y
        }

        public var corner: SIMD2<Double> { SIMD2(longitude, latitude) }

        public func position(_ lonLat: SIMD2<Double>) -> SIMD2<Double> {
            MapBuildingPlacement(origin: corner, resolution: 1).position(lonLat) + SIMD2(eastM, northM)
        }

        var isValid: Bool {
            abs(latitude) < 90 && abs(longitude) <= 180 && eastM.isFinite && northM.isFinite
        }
    }

    /// The buildings in the air: the scene's corner (0, 0).
    public var scene: Frame
    /// The far field's buildings, placed about the whole district's corner and moved into the near
    /// scene's coordinates (`DistrictLayout.hybrid`); nil for a scene without a far field.
    public var far: Frame?

    public init(scene: Frame, far: Frame? = nil) {
        self.scene = scene
        self.far = far
    }

    /// A scene whose corner (0, 0) is the longitude and latitude given.
    public init(corner: SIMD2<Double>) { self.init(scene: Frame(corner: corner)) }

    /// Whether every longitude, latitude and shift is a real place on the map.
    public var isValid: Bool { scene.isValid && (far?.isValid ?? true) }
}

extension DistrictLayout {
    /// The longitude and latitude of the corner (0, 0) of `scene(halfSide:…, offset:)`.
    func corner(halfSide: Float, offset: SIMD2<Float> = .zero) -> SIMD2<Double> {
        SIMD2(
            charge.x
                - Double(halfSide - offset.x) / (ElevationGrid.metresPerDegree * cos(charge.y * .pi / 180)),
            charge.y - Double(halfSide - offset.y) / ElevationGrid.metresPerDegree)
    }

    /// Where `scene(halfSide:…, offset:)` lies on the map.
    public func location(halfSide: Float, offset: SIMD2<Float> = .zero) -> SceneLocation {
        SceneLocation(corner: corner(halfSide: halfSide, offset: offset))
    }

    /// The near and whole squares' half sides `hybrid` lays out: corners a whole number of cells
    /// apart, so that the cells line up.
    func hybridSides(nearHalfSide: Float, halfSide: Float, cellSize: Float) -> (near: Float, whole: Float) {
        let near = (nearHalfSide / cellSize).rounded(.up) * cellSize
        return (near, max((halfSide / cellSize).rounded(.up) * cellSize, near))
    }

    /// Where `hybrid(nearHalfSide:halfSide:cellSize:…)` lies on the map: its far buildings have
    /// their own frame, since the whole district's corner has its own cosine of latitude (metres
    /// apart across a district, where a survey's entries are matched within 15 m).
    public func hybridLocation(nearHalfSide: Float, halfSide: Float, cellSize: Float) -> SceneLocation {
        let (near, whole) = hybridSides(nearHalfSide: nearHalfSide, halfSide: halfSide, cellSize: cellSize)
        return SceneLocation(
            scene: .init(corner: corner(halfSide: near)),
            far: .init(corner: corner(halfSide: whole), shift: SIMD2(repeating: Double(near - whole))))
    }
}
