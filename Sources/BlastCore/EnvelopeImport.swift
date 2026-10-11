import Foundation
import simd

/// Where a stationary envelope came from, when it was not drawn in BombCAD: what its standing
/// rests on.
public struct EnvelopeSource: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        /// An IFC import's sampled elements, windows and doors cut as openings.
        case ifc
        /// An OBJ or STL import's sampled boxes.
        case mesh
        /// A footprint from map data, extruded to a height from its tags.
        case map
    }
    public var objectID: UUID
    public var kind: Kind
    /// The file, the element counts or the height's source, as the import's note gives them.
    public var detail: String

    public init(objectID: UUID, kind: Kind, detail: String) {
        self.objectID = objectID
        self.kind = kind
        self.detail = detail
    }
}

extension Scenario {
    /// The envelopes made from imports or map data, of `kind`, still in the scene.
    public func envelopeSources(_ kind: EnvelopeSource.Kind) -> [EnvelopeSource] {
        let present = Set(envelopeObjects.map(\.id))
        return (envelopeSources ?? []).filter { $0.kind == kind && present.contains($0.objectID) }
    }
}

/// What became of an imported model made into a stationary envelope.
public struct EnvelopeConversionReport: Sendable, Equatable {
    public var name: String
    /// Rigid boxes kept as the envelope's solids, and the openings cut from them.
    public var solids: Int
    public var openings: Int
    /// The envelope's fragments once the openings are cut.
    public var fragments: Int
    /// IFC classes kept as solid, with how many elements of each.
    public var solidClasses: [String: Int]
    /// Window and door elements made openings.
    public var openingElements: Int

    /// One line for the layout's import notes.
    public var note: String {
        let classes = solidClasses.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }
            .joined(separator: ", ")
        return
            "\(name): exposure-only envelope from its import, \(solids) solids"
            + (classes.isEmpty ? "" : " (\(classes))")
            + ", \(openingElements) windows and doors as \(openings) openings, \(fragments) fragments. "
            + "Element identities, materials and the source link are not kept."
    }
}

extension ImportedModel {
    /// IFC classes that become openings of an envelope rather than solids.
    public static let openingClasses: Set<String> = [
        "IfcWindow", "IfcWindowStandardCase", "IfcDoor", "IfcDoorStandardCase",
    ]

    /// This rigid, attached import as a stationary envelope: its sampled boxes as solids, except
    /// the cells of windows and doors, whose placed bounds become openings cut from every solid
    /// they cross. An OBJ or STL import has no elements, so no openings.
    ///
    /// `openings` adds boxes, in scene coordinates, to cut as well: the bounds of windows and doors
    /// the import left out (their meshes open, so not imported as solids; see `sceneBox`).
    public func buildingEnvelope(openings extra: [Box] = []) throws -> (
        envelope: BuildingEnvelope, report: EnvelopeConversionReport
    ) {
        guard isAttached, behavior == .rigid, !preview.boxes.isEmpty else {
            throw ImportedMesh.ImportError.invalid(
                "Only an attached rigid import can become an exposure-only envelope.")
        }
        var solids = preview.boxes
        var openings: [Box] = []
        var classes: [String: Int] = [:]
        var openingElements = 0
        if let elements = try transformedSource().buildingElements {
            guard let owners = preview.boxPartIDs, owners.count == preview.boxes.count else {
                throw ImportedMesh.ImportError.invalid(
                    "Refresh \(name)'s preview before making it an envelope: its boxes have no elements.")
            }
            let openingParts = Set(
                elements.filter { Self.openingClasses.contains($0.ifcClass) }.map(\.partID))
            solids = zip(preview.boxes, owners).filter { !openingParts.contains($0.1) }.map(\.0)
            let kept = Set(owners).subtracting(openingParts)
            for element in elements {
                if Self.openingClasses.contains(element.ifcClass) {
                    openingElements += 1
                    openings.append(Box(min: element.mesh.bounds.min, max: element.mesh.bounds.max))
                } else if kept.contains(element.partID) {
                    classes[element.ifcClass, default: 0] += 1
                }
            }
        }
        openings += extra
        openingElements += extra.count
        guard !solids.isEmpty else {
            throw ImportedMesh.ImportError.invalid(
                "\(name) has no solid cells besides its windows and doors.")
        }
        guard solids.count <= 2048 else {
            throw ImportedMesh.ImportError.invalid(
                "\(name) samples into \(solids.count) boxes; an envelope holds 2,048. Choose a coarser grid.")
        }
        guard openings.count <= 256 else {
            throw ImportedMesh.ImportError.invalid(
                "\(name) has \(openings.count) windows and doors; an envelope holds 256 openings.")
        }
        let envelope: BuildingEnvelope
        do {
            envelope = try BuildingEnvelope(solids: solids, openings: openings)
        } catch {
            throw ImportedMesh.ImportError.invalid(
                "\(name)'s openings cut its solids into more than 2,048 fragments. Choose a coarser grid.")
        }
        return (
            envelope,
            EnvelopeConversionReport(
                name: name, solids: solids.count, openings: openings.count, fragments: envelope.blocks.count,
                solidClasses: classes, openingElements: openingElements)
        )
    }
}

extension ImportedModel {
    /// The scene box holding the source-local box from `low` to `high` (an IFC element's bounds less
    /// the source's `buildingOrigin`), placed as the import is: turned if Y is up, scaled, and moved
    /// with the source so that its lowest point is at `corner`.
    public func sceneBox(sourceLocal low: SIMD3<Double>, _ high: SIMD3<Double>) -> Box {
        func rotate(_ p: SIMD3<Float>) -> SIMD3<Float> { (yUp ? SIMD3(p.x, -p.z, p.y) : p) * scale }
        let base = source.triangles.flatMap { [rotate($0.a), rotate($0.b), rotate($0.c)] }
            .reduce(SIMD3<Float>(repeating: .infinity), simd_min)
        let corners = (0..<8).map { n in
            rotate(
                SIMD3<Float>(
                    SIMD3(
                        n & 1 == 0 ? low.x : high.x, n & 2 == 0 ? low.y : high.y, n & 4 == 0 ? low.z : high.z)
                ))
                - base + corner
        }
        return Box(
            min: corners.reduce(SIMD3(repeating: .infinity), simd_min),
            max: corners.reduce(SIMD3(repeating: -.infinity), simd_max))
    }
}

extension Scenario {
    /// Makes the rigid imports `ids` stationary envelopes, each its own building with the import's
    /// name (with `openings`' extra boxes cut from it), and removes the imports, so that their geometry is not counted twice. The reports
    /// are added to the layout's import notes. Nothing changes if any of them fails.
    @discardableResult
    public mutating func useEnvelopes(importIDs ids: [UUID], openings: [UUID: [Box]] = [:]) throws
        -> [EnvelopeConversionReport]
    {
        var copy = self
        var reports: [EnvelopeConversionReport] = []
        for id in ids {
            guard let model = copy.importedModels?.first(where: { $0.id == id }) else {
                throw SceneObjectError.unsupportedRepresentation
            }
            let (envelope, report) = try model.buildingEnvelope(openings: openings[id] ?? [])
            let object = try copy.addEnvelopeObject(envelope, name: model.name)
            copy.envelopeSources =
                (copy.envelopeSources ?? []) + [
                    EnvelopeSource(
                        objectID: object, kind: model.source.buildingElements == nil ? .mesh : .ifc,
                        detail: report.note)
                ]
            copy.importedModels?.removeAll { $0.id == id }
            reports.append(report)
        }
        if copy.importedModels?.isEmpty == true { copy.importedModels = nil }
        guard copy.rigidBoxes.count <= 2048 else {
            throw ImportedMesh.ImportError.invalid(
                "The scene's envelopes and blocks would hold \(copy.rigidBoxes.count) fragments; it holds 2,048."
            )
        }
        copy.importNotes = (copy.importNotes ?? []) + reports.map(\.note)
        try copy.validateObjectOwnership()
        self = copy
        return reports
    }
}
