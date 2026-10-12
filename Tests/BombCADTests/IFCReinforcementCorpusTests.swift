import BlastCore
import Foundation
import Testing

@testable import BombCAD

/// How much of the reinforcement in a folder of real IFC files the reader gets: for each file with
/// reinforcing elements or reinforcement properties, how many bars the converter makes, how many
/// take a size the IFC gives, and how many land in a building element. Runs only with
/// `BOMBCAD_IFC_CORPUS` set to the folder (the study volume's corpus); writes
/// `reinforcement/read-report.json` there. CPU only.
@Suite(
    "IFC reinforcement corpus",
    .enabled(
        if: IFCImporter.converterURL != nil
            && ProcessInfo.processInfo.environment["BOMBCAD_IFC_CORPUS"] != nil,
        "Set BOMBCAD_IFC_CORPUS to an IFC corpus folder"))
struct IFCReinforcementCorpusTests {
    struct Entry: Codable {
        var file: String
        var reinforcingElements = 0
        var withProperties = 0
        var converted = 0
        var sizedFromIFC = 0
        var placed = 0
        var notes: [String] = []
        var failure: String?
        /// Why the building's own elements could not be imported, if they could not.
        var importFailure: String?
        var elements = 0
    }

    @Test("Read the reinforcement of every IFC in the corpus that has any")
    func survey() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BOMBCAD_IFC_CORPUS"]!)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "ifc" }
            .sorted { $0.path < $1.path }
        var entries: [Entry] = []
        for url in files {
            guard let data = try? Data(contentsOf: url), data.count <= 20_000_000 else { continue }
            let text = String(decoding: data.prefix(20_000_000), as: UTF8.self).uppercased()
            guard
                text.contains("IFCREINFORCING") || text.contains("IFCTENDON(")
                    || text.contains("CONCRETECOVER") || text.contains("REINFORCEMENTAREARATIO")
                    || text.contains("REINFORCEMENTVOLUMERATIO")
            else { continue }
            var entry = Entry(file: url.path.replacingOccurrences(of: root.path + "/", with: ""))
            do {
                let metadata = try await readMetadata(data)
                entry.reinforcingElements = metadata.elements.count
                entry.withProperties = metadata.properties.count
                // The building elements, where the import can make them; bars land in none otherwise.
                var elements: [ImportedMesh.BuildingElement] = []
                var origin = SIMD3<Double>.zero
                // As a user would: leave out the elements that fail, and choose at most the
                // import's limit, those with reinforcement properties first.
                do {
                    let prepared = try await IFCImporter.prepare(data)
                    var chosen = prepared.defaultIDs
                    if chosen.count > 1024 {
                        let first = chosen.filter { metadata.properties[$0] != nil }
                        chosen = first.union(chosen.subtracting(first).sorted().prefix(1024 - first.count))
                    }
                    for _ in 0..<3 {
                        do {
                            let mesh = try await IFCImporter.convert(prepared, includedIDs: chosen)
                            elements = mesh.buildingElements ?? []
                            origin = mesh.buildingOrigin ?? .zero
                            break
                        } catch let failures as IFCImporter.ElementFailures {
                            chosen.subtract(failures.failures.map(\.id))
                            entry.importFailure = "left out \(failures.failures.count) failing elements"
                        }
                    }
                } catch {
                    entry.importFailure = String("\(error)".prefix(300))
                }
                entry.elements = elements.count
                let (attached, notes) = await IFCReinforcementReader.attach(
                    metadata, to: elements, ifc: data, origin: origin, converter: IFCImporter.converterURL)
                entry.notes = notes
                let bars = attached.flatMap { $0.reinforcement?.bars ?? [] }
                entry.placed = bars.count
                entry.sizedFromIFC = bars.filter { !$0.sizeSource.contains("measured") }.count
                if !metadata.elements.isEmpty {
                    entry.converted =
                        (try? await IFCReinforcementReader.convert(
                            data, converter: IFCImporter.converterURL, origin: origin))?
                        .count ?? 0
                }
            } catch {
                entry.failure = String(error.localizedDescription.prefix(300))
            }
            entries.append(entry)
        }
        let report = root.appendingPathComponent("reinforcement/read-report.json")
        try? FileManager.default.createDirectory(
            at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: report)
        #expect(!entries.isEmpty)
    }

    private func readMetadata(_ ifc: Data) async throws -> IFCReinforcementReader.Metadata {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("source.ifc")
        let xml = folder.appendingPathComponent("metadata.xml")
        try ifc.write(to: input)
        _ = try await IFCImporter.run(
            try #require(IFCImporter.converterURL), arguments: [input.path, xml.path, "-y"], folder: folder)
        return IFCReinforcementReader.Metadata(try Data(contentsOf: xml))
    }
}
