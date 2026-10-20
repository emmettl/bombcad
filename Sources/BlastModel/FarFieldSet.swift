import Foundation
import simd

/// A district's buildings beyond its near field: kept beside a project whose air reaches only the
/// near field, never voxelised, and judged after the run by the far field carried from it
/// (`HybridFarField`; docs/hybrid-far-field.md). Their geometry is in the near scene's coordinates,
/// most of it outside its domain.
public struct FarFieldSet: Codable, Sendable, Equatable {
    /// Where the near field hands over, m from the charge in plan.
    public var handoverM: Float
    /// A far building: its envelope, by the id and name it has in the district.
    public struct Building: Codable, Sendable, Hashable {
        public var id: UUID
        public var name: String
        public var envelope: BuildingEnvelope

        public init(id: UUID, name: String, envelope: BuildingEnvelope) {
            self.id = id
            self.name = name
            self.envelope = envelope
        }
    }

    /// The far buildings, each with its construction.
    public var buildings: [Building]
    public var constructions: [EnvelopeConstruction]
    /// The whole district's ground, in the near scene's coordinates (its origin below and left of
    /// the near domain's), for the far field's lines over the ground; nil for flat ground.
    public var terrain: Terrain?
    /// How far beyond the hand-over the near run's trend with distance is carried, as a multiple of
    /// it (`HybridFarField.trendReach`); nil all the way.
    public var trendReach: Double?
    /// How the match fades past the reach (`HybridFarField.trendDamping`); nil holds it.
    public var trendDamping: Double?

    public init(
        handoverM: Float, buildings: [Building], constructions: [EnvelopeConstruction], terrain: Terrain?,
        trendReach: Double? = nil
    ) {
        self.handoverM = handoverM
        self.buildings = buildings
        self.constructions = constructions
        self.terrain = terrain
        self.trendReach = trendReach
    }

    /// The trend's reach File ▸ New District sets (`trendReach`): carried to 1.5 times the hand-over,
    /// held from there. On Beirut at 0.2 kt that lifted the shares of sides broken at 1.5–2.5 km
    /// toward the full run's (docs/hybrid-far-field.md).
    public static let trendReachDefault = 1.5

    /// About how long judging the far set takes on this Mac's cores, s: about 2.5 ms a building
    /// (Beirut's 11,100 in about 25 s on the Studio).
    public var judgeSeconds: Double { Double(buildings.count) * 2.5e-3 }

    /// The far buildings' blocks.
    public var blockCount: Int { buildings.reduce(0) { $0 + $1.envelope.blocks.count } }

    public func construction(for id: UUID) -> EnvelopeConstruction {
        constructions.first { $0.objectID == id } ?? .assumed(objectID: id)
    }

    public func validate() throws {
        guard handoverM.isFinite, handoverM > 0, Set(buildings.map(\.id)).count == buildings.count,
            trendReach.map({ $0.isFinite && $0 >= 1 }) ?? true,
            trendDamping.map({ $0.isFinite && $0 > 0 }) ?? true, blockCount <= Scenario.maximumRigidBoxes
        else { throw SceneObjectError.invalidOwnership }
    }

    /// The near scene with the far buildings beside it, for the far field's features (its lines over
    /// the ground and the buildings in their way): the whole district's ground and buildings, the
    /// domain grown to hold them. Not for the air.
    public func combined(with near: Scenario) throws -> Scenario {
        var scene = near
        for building in buildings {
            try scene.addEnvelopeObject(building.envelope, name: building.name, id: building.id)
        }
        scene.envelopeConstructions = (scene.envelopeConstructions ?? []) + constructions
        if let terrain { scene.terrain = terrain }
        return scene
    }
}

extension DistrictLayout {
    /// The district split at a hand-over `handoverM` from the charge: the near scene, a square of
    /// half side `nearHalfSide` (the hand-over and its open faces' clearance), as `scene` lays it out,
    /// for the air; and every building within `radius` it does not place, even in part, with the whole
    /// district's ground, as the far set beside it. Both on the same cells, the far set moved into
    /// the near scene's coordinates, so that each building lies where the full layout puts it.
    public func hybrid(
        handoverM: Float, nearHalfSide: Float, radius: Float, halfSide: Float, cellSize: Float,
        name: String? = nil, footprintCells: Float? = nil
    ) throws -> (near: Scenario, far: FarFieldSet, report: MapBuildingReport) {
        // Corners a whole number of cells apart, so that the cells line up.
        let near = (nearHalfSide / cellSize).rounded(.up) * cellSize
        let whole = max((halfSide / cellSize).rounded(.up) * cellSize, near)
        let (nearScene, report) = try scene(
            halfSide: near, cellSize: cellSize, name: name, footprintCells: footprintCells)
        let (full, wholeReport) = try scene(
            halfSide: whole, cellSize: cellSize, radius: radius, height: nearScene.domainSize.z,
            footprintCells: footprintCells)
        let shift = SIMD3<Float>(near - whole, near - whole, 0)
        // A far building is one the near scene did not place, even in part.
        let inNear = Set(report.placed.map(\.id))
        let far = Set(wholeReport.placed.filter { !inNear.contains($0.id) }.map(\.objectID))
        var buildings: [FarFieldSet.Building] = []
        var constructions: [EnvelopeConstruction] = []
        for object in full.envelopeObjects where far.contains(object.id) {
            guard let envelope = object.envelope else { continue }
            let moved = try envelope.translated(by: shift)
            buildings.append(FarFieldSet.Building(id: object.id, name: object.name, envelope: moved))
            constructions.append(full.envelopeConstruction(for: object.id))
        }
        var terrain = full.terrain
        terrain?.origin += SIMD2(shift.x, shift.y)
        return (
            nearScene,
            FarFieldSet(
                handoverM: handoverM, buildings: buildings, constructions: constructions, terrain: terrain),
            report
        )
    }
}
