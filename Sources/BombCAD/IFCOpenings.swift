import BlastCore
import Foundation
import simd

extension IFCImporter {
    /// The scene boxes of an IFC import's windows and doors that it left out, for an envelope to cut
    /// as openings. Their meshes need not be closed solids (the importer refuses open ones as
    /// obstacles): only their bounds are used. Read from the import's retained IFC bytes.
    static func excludedOpeningBoxes(of model: ImportedModel, converter: URL? = converterURL) async throws
        -> [Box]
    {
        guard let data = model.source.buildingSourceData, let origin = model.source.buildingOrigin,
            let selection = model.source.buildingSelection
        else { return [] }
        let included = Set(selection.includedIDs)
        let ids = selection.inventory.filter {
            $0.supported && ImportedModel.openingClasses.contains($0.ifcClass) && !included.contains($0.id)
        }.map(\.id)
        guard !ids.isEmpty else { return [] }
        guard ids.count <= 256 else {
            throw ImportedMesh.ImportError.invalid(
                "\(model.name) has \(ids.count) windows and doors left out; an envelope holds 256 openings.")
        }
        let converter = try requireConverter(converter)
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("source.ifc")
        let obj = folder.appendingPathComponent("openings.obj")
        try data.write(to: input)
        _ = try await run(
            converter,
            arguments: [
                input.path, obj.path, "-y", "--use-element-guids", "--include", "attribute", "GlobalId",
            ]
                + ids.sorted(), folder: folder)
        let bounds = try elementBounds(try boundedData(obj))
        return ids.compactMap { id in
            bounds[id].map { model.sceneBox(sourceLocal: $0.low - origin, $0.high - origin) }
        }
    }

    /// Each element's bounds in converter OBJ output, over the vertices its faces use.
    static func elementBounds(_ data: Data) throws -> [String: (low: SIMD3<Double>, high: SIMD3<Double>)] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportedMesh.ImportError.invalid("IFC converter output is not UTF-8.")
        }
        var vertices: [SIMD3<Double>] = []
        var bounds: [String: (low: SIMD3<Double>, high: SIMD3<Double>)] = [:]
        var guid: String?
        for raw in text.split(separator: "\n") {
            let f = raw.split(whereSeparator: \.isWhitespace)
            if f.first == "g" || f.first == "o" { guid = f.count == 2 ? String(f[1]) : nil }
            if f.first == "v", f.count >= 4, let x = Double(f[1]), let y = Double(f[2]), let z = Double(f[3])
            {
                vertices.append(SIMD3(x, y, z))
            }
            if f.first == "f", let guid {
                for token in f.dropFirst() {
                    guard let n = token.split(separator: "/").first.flatMap({ Int($0) }), n > 0,
                        n <= vertices.count
                    else { continue }
                    let v = vertices[n - 1]
                    let b = bounds[guid] ?? (v, v)
                    bounds[guid] = (simd_min(b.low, v), simd_max(b.high, v))
                }
            }
        }
        return bounds
    }
}
