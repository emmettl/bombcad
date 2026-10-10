import BlastCore
import DocumentKit
import Foundation

/// Project payloads deliberately separate editable scene instances from shared source geometry.
enum ImportedSceneCodec {
    struct ScenePayload: Codable {
        var format = "dev.bombcad.scene"
        var encodingVersion = 3
        var scenario: Scenario
        var imports: [Instance]?

        init(scenario: Scenario, imports: [Instance]?) {
            self.scenario = scenario
            self.imports = imports
            // Older readers must not silently discard durable object/component ownership, nor
            // stand a base on the ground that stands on a footing, nor turn a joint face down, nor
            // read a joint at an angle as one under the body, nor lay flat ground over a terrain.
            encodingVersion =
                scenario.terrain != nil
                ? 8
                : scenario.hasLaterConnections
                    ? 7
                    : !scenario.envelopeObjects.isEmpty
                        ? 6
                        : scenario.hasFootingsOrTurnedJoints
                            ? 5
                            : scenario.structuralObjects.count > 1 ? 4 : 3
        }
    }

    struct SourceMesh: Codable {
        struct PartIdentity: Codable, Equatable {
            var id: Int
            var name: String
        }

        var format = "dev.simulationkit.source-mesh"
        var encodingVersion = 1
        /// Positions are exactly as imported. Instance scale, axis conversion and placement
        /// are applied once by ImportedModel.transformedSource(), never during asset encoding.
        var coordinateSpace = "source"
        var mesh: ImportedMesh
        var parts: [PartIdentity]

        init(_ mesh: ImportedMesh) {
            self.mesh = mesh
            encodingVersion = mesh.buildingElements == nil ? 1 : 2
            parts = mesh.parts.map { PartIdentity(id: $0.id, name: $0.name) }
        }

        func validate() throws {
            guard format == "dev.simulationkit.source-mesh", encodingVersion == 1 || encodingVersion == 2,
                encodingVersion == (mesh.buildingElements == nil ? 1 : 2),
                coordinateSpace == "source",
                parts == mesh.parts.map({ PartIdentity(id: $0.id, name: $0.name) })
            else {
                throw ProjectFileError.invalid(
                    "Unsupported source-mesh encoding or changed source part identities.")
            }
        }
    }

    /// Provenance for the retained preview. The importer regenerates managed geometry when
    /// resolution changes; detached scene geometry remains authoritative regardless of preview.
    struct PreviewKey: Codable, Equatable {
        var samplerVersion = 1
        var sourceSHA256: String
        var scale: Float
        var yUp: Bool
        var corner: SIMD3<Float>
        var cellSize: Float
        var domainSize: SIMD3<Float>

        init(_ model: ImportedModel, sourceSHA256: String, domainSize: SIMD3<Float>) {
            self.sourceSHA256 = sourceSHA256
            scale = model.scale
            yUp = model.yUp
            corner = model.corner
            cellSize = model.preview.cellSize
            self.domainSize = domainSize
        }
    }

    struct Instance: Codable {
        var id: UUID
        var name: String
        var sourceAssetID: UUID
        var scale: Float
        var yUp: Bool
        var corner: SIMD3<Float>
        var behavior: ImportedModel.Behavior
        var preview: ImportedMesh.Preview
        var previewKey: PreviewKey
        var regenerationEnabled: Bool?
        var partMaterials: [Int: StructureMaterial]?

        init(_ model: ImportedModel, asset: ProjectManifest.Asset, domainSize: SIMD3<Float>) {
            id = model.id
            name = model.name
            sourceAssetID = asset.id
            scale = model.scale
            yUp = model.yUp
            corner = model.corner
            behavior = model.behavior
            preview = model.preview
            previewKey = PreviewKey(model, sourceSHA256: asset.sha256, domainSize: domainSize)
            regenerationEnabled = model.regenerationEnabled
            partMaterials = model.partMaterials
        }

        func model(source: ImportedMesh) -> ImportedModel {
            var model = ImportedModel(
                id: id, name: name, source: source, scale: scale, yUp: yUp, corner: corner,
                behavior: behavior, preview: preview, partMaterials: partMaterials)
            model.regenerationEnabled = regenerationEnabled
            return model
        }
    }

    static func encode(
        _ scenario: Scenario, manifest: inout ProjectManifest, files: inout [String: Data]
    ) throws -> Data {
        try validateInstances(scenario.importedModels ?? [])
        var scene = scenario
        scene.importedModels = nil
        var instances: [Instance]? = scenario.importedModels.map { _ in [] }
        // Retain existing assets, including sources needed by layout undo. Reusing canonical
        // bytes preserves IDs across save/reopen and deduplicates identical source instances.
        var sourcesByHash: [String: ProjectManifest.Asset] = [:]
        for asset in manifest.assets where asset.path.hasSuffix(".mesh.json") {
            sourcesByHash[asset.sha256] = asset
        }
        for model in scenario.importedModels ?? [] {
            let data = try ProjectArchive.encodeJSON(SourceMesh(model.source))
            var candidate = ProjectManifest.Asset(path: "", data: data)
            candidate.id = sourceID(candidate.sha256)
            candidate.path = "assets/\(candidate.id.uuidString.lowercased()).mesh.json"
            let asset: ProjectManifest.Asset
            if let existing = sourcesByHash[candidate.sha256], files[existing.path] == data {
                asset = existing
            } else {
                guard !manifest.assets.contains(where: { $0.id == candidate.id }),
                    files[candidate.path] == nil
                else {
                    throw ProjectFileError.invalid(
                        "An embedded asset conflicts with a source-mesh identifier.")
                }
                asset = candidate
                manifest.assets.append(asset)
                files[asset.path] = data
                sourcesByHash[asset.sha256] = asset
            }
            instances?.append(Instance(model, asset: asset, domainSize: scenario.domainSize))
        }
        return try ProjectArchive.encodeJSON(ScenePayload(scenario: scene, imports: instances))
    }

    static func decode(_ archive: ProjectArchive) throws -> Scenario {
        let data = archive.files["scene.json"]!
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // A direct reader for development-era flat Scenario payloads; no migration framework.
        guard object?["format"] != nil else {
            let scenario = try JSONDecoder().decode(Scenario.self, from: data)
            try validateInstances(scenario.importedModels ?? [])
            return scenario
        }
        struct Header: Decodable {
            var format: String
            var encodingVersion: Int
        }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.format == "dev.bombcad.scene", (1...8).contains(header.encodingVersion) else {
            throw ProjectFileError.invalid(
                "Unsupported scene encoding: \(header.format), version \(header.encodingVersion).")
        }
        let payload = try JSONDecoder().decode(ScenePayload.self, from: data)
        if header.encodingVersion >= 3 {
            guard let scene = object?["scenario"] as? [String: Any], scene["objectOwnership"] != nil else {
                throw ProjectFileError.invalid("This scene encoding requires object ownership.")
            }
        }
        let hasEnvelopes = !payload.scenario.envelopeObjects.isEmpty
        let hasFootings = payload.scenario.hasFootingsOrTurnedJoints
        let expected =
            payload.scenario.terrain != nil
            ? 8
            : payload.scenario.hasLaterConnections
                ? 7
                : hasEnvelopes ? 6 : hasFootings ? 5 : payload.scenario.structuralObjects.count > 1 ? 4 : 3
        // The unmerged envelope prototype also wrote v5 before footing support landed on main.
        // Its geometry is explicit and can migrate to v6 without discarding either feature.
        let prototypeEnvelope = header.encodingVersion == 5 && hasEnvelopes
        let legacy =
            header.encodingVersion < 3 && !hasEnvelopes && !hasFootings && payload.scenario.terrain == nil
            && !payload.scenario.hasLaterConnections
            && payload.scenario.structuralObjects.count <= 1
        guard header.encodingVersion == expected || prototypeEnvelope || legacy else {
            throw ProjectFileError.invalid("Scene objects do not match their encoding version.")
        }
        guard payload.scenario.importedModels == nil else {
            throw ProjectFileError.invalid("The scene contains conflicting inline and referenced imports.")
        }
        let assets = Dictionary(uniqueKeysWithValues: archive.manifest.assets.map { ($0.id, $0) })
        var sources: [UUID: ImportedMesh] = [:]
        var models: [ImportedModel]? = payload.imports.map { _ in [] }
        for instance in payload.imports ?? [] {
            guard let asset = assets[instance.sourceAssetID], let sourceData = archive.files[asset.path]
            else {
                throw ProjectFileError.invalid("Missing source asset for \(instance.name).")
            }
            if sources[asset.id] == nil {
                let sourceHeader = try JSONDecoder().decode(Header.self, from: sourceData)
                guard sourceHeader.format == "dev.simulationkit.source-mesh",
                    [1, 2].contains(sourceHeader.encodingVersion)
                else {
                    throw ProjectFileError.invalid("Unsupported source-mesh encoding for \(instance.name).")
                }
                let source = try JSONDecoder().decode(SourceMesh.self, from: sourceData)
                try source.validate()
                sources[asset.id] = source.mesh
            }
            let model = instance.model(source: sources[asset.id]!)
            guard
                instance.previewKey
                    == PreviewKey(model, sourceSHA256: asset.sha256, domainSize: payload.scenario.domainSize)
            else {
                throw ProjectFileError.invalid(
                    "The retained preview for \(instance.name) does not match its source or sampling settings."
                )
            }
            models?.append(model)
        }
        try validateInstances(models ?? [])
        var scenario = payload.scenario
        scenario.importedModels = models
        scenario.resolveLegacyStructuralSource()
        // Do not install or regenerate here: scene boxes and structural edits must survive,
        // especially when a source has been detached from its generated geometry.
        return scenario
    }

    private static func validateInstances(_ models: [ImportedModel]) throws {
        guard Set(models.map(\.id)).count == models.count else {
            throw ProjectFileError.invalid("Imported model instance IDs must be unique.")
        }
        for model in models {
            guard model.source.buildingElements == nil || model.behavior == .rigid else {
                throw ProjectFileError.invalid("IFC building instances must use rigid behavior.")
            }
            let p = model.preview
            guard model.scale.isFinite, model.scale > 0,
                [model.corner.x, model.corner.y, model.corner.z].allSatisfy({ $0.isFinite && $0 >= 0 }),
                p.cellSize.isFinite, p.cellSize > 0, p.boxes.count <= 2048, p.occupiedCells >= 0,
                valid(p.bounds), p.boxes.allSatisfy(valid)
            else { throw ProjectFileError.invalid("Invalid transform or preview for \(model.name).") }
            var size = model.source.bounds.size * model.scale
            if model.yUp { size = SIMD3(size.x, size.z, size.y) }
            guard [size.x, size.y, size.z].allSatisfy({ $0.isFinite && $0 > 0 }),
                [model.corner.x + size.x, model.corner.y + size.y, model.corner.z + size.z].allSatisfy(
                    \.isFinite)
            else {
                throw ProjectFileError.invalid(
                    "Source coordinates overflow after transforming \(model.name).")
            }
            _ = try model.regionMaterials()
        }
    }

    private static func valid(_ box: Box) -> Bool {
        [box.min.x, box.min.y, box.min.z, box.max.x, box.max.y, box.max.z].allSatisfy(\.isFinite)
            && box.size.x > 0 && box.size.y > 0 && box.size.z > 0
    }

    /// Content-derived, UUID-shaped identifiers stay stable even before the document's first
    /// save is read back. Full SHA-256 checksums still guard the asset contents and collisions.
    private static func sourceID(_ checksum: String) -> UUID {
        var hex = Array(checksum.prefix(32))
        hex[12] = "8"
        hex[16] = Character(String((Int(String(hex[16]), radix: 16)! & 3) | 8, radix: 16))
        let value =
            String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-" + String(hex[12..<16])
            + "-" + String(hex[16..<20]) + "-" + String(hex[20..<32])
        return UUID(uuidString: value)!
    }
}

extension Scenario {
    /// Whether any structure's base or support region stands on a footing (`Footing`), or a
    /// support's joint faces another way than down (`JointSide`).
    var hasFootingsOrTurnedJoints: Bool {
        structuralObjects.contains { object in
            guard let body = object.structure else { return false }
            return body.baseAnchorage?.footing != nil
                || body.supportAnchorages.contains { $0?.footing != nil || ($0?.side ?? .below) != .below }
        }
    }

    /// Whether any support's joint lies at an angle of its own (`Anchorage.jointNormal`), which
    /// readers before scene version 7 would take for a joint under the body.
    var hasLaterConnections: Bool {
        structuralObjects.contains { object in
            object.structure?.supportAnchorages.contains { $0?.jointNormal != nil } ?? false
        }
    }
}
