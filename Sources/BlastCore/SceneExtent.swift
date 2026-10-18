import Foundation
import simd

/// Why a domain could not be resized.
public struct SceneExtentError: LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
}

// The domain's extent: what it must hold, how high its open top should be, and an open scene
// fitted to its charge (see docs/large-scenes.md).
extension Scenario {
    /// The box holding everything in the scene besides the air, the main charge, the gauges and
    /// the terrain: blocks, envelopes, rigid imports, structures, vent panels, the gas cloud,
    /// freestanding objects and any further charges; nil when there is none of these.
    public var contentBounds: Box? {
        var boxes = rigidBoxes + structuralObjects.compactMap { $0.structure?.bounds }
        boxes += (ventPanels ?? []).map(\.box)
        if let deflagration { boxes.append(deflagration.region) }
        for object in rigidObjects ?? [] {
            if case .box(let size) = object.shape {
                let half = Float(simd_length(size) / 2)
                let centre = SIMD3<Float>(object.position)
                boxes.append(Box(min: centre - half, max: centre + half))
            }
        }
        for car in rigidCars ?? [] {
            // Half a car's length round its position, whichever way it faces.
            let centre = SIMD3<Float>(car.position)
            boxes.append(Box(min: centre - 2.5, max: centre + 2.5))
        }
        boxes += (additionalCharges ?? []).map { Box(min: $0.position, max: $0.position) }
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) {
            Box(min: simd_min($0.min, $1.min), max: simd_max($0.max, $1.max))
        }
    }

    /// The height the domain's open top should reach above the charge for gauges as far as
    /// `range` along the ground: 1.5 √(range W^(1/3)). Lower, a little of each wave the top
    /// reflects reaches them within their positive phase and their impulse reads high.
    public func headroom(forRange range: Float) -> Float {
        1.5 * (max(range, 0) * cbrt(max(charge.mass, 0))).squareRoot()
    }

    /// The farthest the domain's floor reaches from the charge, to its farthest corner.
    public var farthestGroundRange: Float {
        let c = SIMD2(charge.position.x, charge.position.y)
        let far = simd_max(c, SIMD2(domainSize.x, domainSize.y) - c)
        return simd_length(far)
    }

    /// The domain's height that `headroom(forRange:)` asks for the farthest the floor reaches,
    /// above the ground under the charge, and never below the terrain's highest point with a
    /// fifth to spare or what the scene holds.
    public var suggestedHeight: Float {
        let ground = terrain?.height(at: charge.position) ?? 0
        var height = ground + headroom(forRange: farthestGroundRange)
        if let terrain { height = max(height, 1.2 * terrain.highest) }
        if let content = contentBounds { height = max(height, content.max.z + 1) }
        return max(height, charge.position.z + 1)
    }

    /// The clearance, in m/kg^(1/3), that a scene with a structure wants between each open face
    /// and both the charge and the structure. Far-field faces take a wave as meeting them square on;
    /// a blast grazing a side or the top meets still air beyond it, which releases about half its
    /// pressure there and sends a rarefaction back in. On Tyndall's CLT building (14.5 kg at
    /// 22.9 m, docs/air-blast-model.md "Open faces near a structure") that rarefaction deepened the
    /// front's negative phase and drove the wall's second swing to 29 mm. With every face at least 4.1
    /// m/kg^(1/3) from the charge and the building, the domain gave 18 mm, as one with the faces
    /// twice as far out did. With the top 1.7 from it the peak came out right, but the front's pressure was
    /// still 2.5 kPa (RMS) off. The positive phase is the same in all: peaks and impulses alone need
    /// far less.
    public static let structureFaceClearance: Float = 4

    /// For a scene with a structure, each open face nearer than `structureFaceClearance` to the
    /// charge or to a structure, with its clearance in m/kg^(1/3), the nearest first: the faces whose
    /// reflections may reach the structure's late response. A face beyond a structure as seen from
    /// the charge counts from the charge alone: Tyndall's, 1.4 m/kg^(1/3) behind the building in
    /// every run, did not move its front's response. Empty without a structure.
    public var tightOpenFaces: [(name: String, clearance: Float)] {
        openFaceClearances.filter { $0.clearance < Self.structureFaceClearance }
            .map { ($0.name, $0.clearance) }.sorted { $0.clearance < $1.clearance }
    }

    /// Each open face with its axis, whether it is the high one, and its clearance in m/kg^(1/3)
    /// from the charge and the structures beside it (`tightOpenFaces`). Empty without a structure.
    private var openFaceClearances: [(name: String, axis: Int, high: Bool, clearance: Float)] {
        let structures = structuralObjects.compactMap { $0.structure?.bounds }
        guard !structures.isEmpty, charge.mass > 0 else { return [] }
        let scale = cbrt(charge.mass)
        let faces: [(BoundaryFaces, String, Int, Bool)] = [
            (.xMin, "west (x = 0)", 0, false), (.xMax, "east", 0, true), (.yMin, "south (y = 0)", 1, false),
            (.yMax, "north", 1, true), (.zMin, "floor", 2, false), (.zMax, "top", 2, true),
        ]
        var clearances: [(name: String, axis: Int, high: Bool, clearance: Float)] = []
        for (face, name, axis, high) in faces where !reflectiveFaces.contains(face) {
            func distance(_ x: Float) -> Float { high ? domainSize[axis] - x : x }
            let fromCharge = distance(charge.position[axis])
            // Structures between the charge and the face shelter it; those beside or beyond count.
            let beside = structures.filter { box in
                !(high ? box.min[axis] > charge.position[axis] : box.max[axis] < charge.position[axis])
            }
            let nearest =
                ([fromCharge] + beside.flatMap { [distance($0.min[axis]), distance($0.max[axis])] }).min()!
            clearances.append((name, axis, high, max(nearest, 0) / scale))
        }
        return clearances
    }

    /// How far (m) each open face must move out for `tightOpenFaces` to be empty, each rounded up
    /// to a multiple of `step`: `low` below the origin on each axis, which means moving the
    /// scene by it, and `high` beyond the far side. Benchmarks built in tight domains use it to
    /// check their comparisons against a domain that meets the rule (`--roomy`).
    public func openFaceRoom(step: Float) -> (low: SIMD3<Float>, high: SIMD3<Float>) {
        let wanted = Self.structureFaceClearance * cbrt(max(charge.mass, 0))
        var low = SIMD3<Float>.zero
        var high = SIMD3<Float>.zero
        for face in openFaceClearances where face.clearance < Self.structureFaceClearance {
            let short = wanted - face.clearance * cbrt(charge.mass)
            let room = (short / step).rounded(.up) * step
            if face.high { high[face.axis] = room } else { low[face.axis] = room }
        }
        return (low, high)
    }

    /// A line saying which open faces are too near (`tightOpenFaces`), or nil.
    public var tightFacesNote: String? {
        let tight = tightOpenFaces
        guard !tight.isEmpty else { return nil }
        let list = tight.map { String(format: "%@ %.1f", $0.name, $0.clearance) }.joined(separator: ", ")
        return String(
            format:
                "Open faces near the charge or the structure (m/kg^(1/3)): %@. Their reflections can move the structure's response after the positive phase; keep each at least %.0f m/kg^(1/3) (%.0f m) away.",
            list, Self.structureFaceClearance, Self.structureFaceClearance * cbrt(charge.mass))
    }

    /// Resizes the domain from its origin, everything staying where it is. Throws if the scene's
    /// contents, its charge or its terrain would not fit; gauges left outside are removed, and
    /// their names returned.
    @discardableResult
    public mutating func resizeDomain(to size: SIMD3<Float>) throws -> [String] {
        guard (0..<3).allSatisfy({ size[$0].isFinite && size[$0] >= 1 }) else {
            throw SceneExtentError(message: "Each side of the domain must be at least a metre.")
        }
        if let content = contentBounds, any(content.max .> size) {
            throw SceneExtentError(
                message: String(
                    format: "The scene's contents reach %.0f × %.0f × %.0f m; the domain must hold them.",
                    content.max.x, content.max.y, content.max.z))
        }
        guard all(charge.position .< size) else {
            throw SceneExtentError(message: "The charge would lie outside the domain. Move it first.")
        }
        if let terrain, terrain.highest >= size.z {
            throw SceneExtentError(
                message: String(
                    format: "The terrain rises to %.0f m; the domain must be taller.", terrain.highest))
        }
        let removed = gauges.filter { any($0.position .>= size) }.map(\.name)
        gauges.removeAll { any($0.position .>= size) }
        domainSize = size
        return removed
    }

    /// For an open scene, with nothing in it but its charge, gauges and terrain: a square domain
    /// reaching `scaledReach` m/kg^(1/3) of the charge from it every way along the ground (5%
    /// more), as high as `suggestedHeight` asks, the charge moved to its middle at the same height
    /// above the ground and the gauges moved with it at their heights above the ground (those left
    /// outside removed).
    public mutating func fitOpenScene(scaledReach: Float) throws {
        guard contentBounds == nil else {
            throw SceneExtentError(
                message:
                    "Only an open scene, with nothing in it but the charge, gauges and terrain, is fitted to its charge."
            )
        }
        guard scaledReach.isFinite, scaledReach > 0, charge.mass > 0 else {
            throw SceneExtentError(message: "The reach and the charge must be positive.")
        }
        let reach = 1.05 * scaledReach * cbrt(charge.mass)
        let old = charge.position
        let above = old.z - (terrain?.height(at: old) ?? 0)
        let centre = SIMD2<Float>(reach, reach)
        var moved = SIMD3(centre.x, centre.y, 0)
        moved.z = (terrain?.height(at: centre) ?? 0) + above
        let shift = moved - old
        for n in gauges.indices {
            let from = gauges[n].position
            let to = SIMD2(from.x + shift.x, from.y + shift.y)
            let height = from.z - (terrain?.height(at: from) ?? 0)
            gauges[n].position = SIMD3(to.x, to.y, (terrain?.height(at: to) ?? 0) + height)
        }
        charge.position = moved
        domainSize = SIMD3(2 * reach, 2 * reach, max(domainSize.z, 1))
        domainSize.z = suggestedHeight
        gauges.removeAll { any($0.position .< 0) || any($0.position .>= domainSize) }
    }
}

extension Box {
    /// The box moved by `offset`.
    func moved(by offset: SIMD3<Float>) -> Box { Box(min: min + offset, max: max + offset) }
}
