import Foundation
import Testing
import simd

@testable import BlastCore
@testable import BombCAD

/// Reinforcement read from an IFC through the converter (`IFCReinforcementReader`): a concrete
/// wall with its bars nested in it, and a slab with only reinforcement properties.
@Suite(
    "IFC reinforcement import",
    .enabled(if: IFCImporter.converterURL != nil, "Prepare the pinned IFC converter before integration tests")
)
struct IFCReinforcementImportTests {
    private var sample: Data {
        get throws {
            try Data(
                contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent(
                        "Samples/Importer/Reinforcement/reinforced-wall.ifc"))
        }
    }

    private func metadata(_ ifc: Data) async throws -> IFCReinforcementReader.Metadata {
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

    @Test("The metadata gives each bar's size and the element it is nested in, and a slab's properties")
    func readsMetadata() async throws {
        let read = try await metadata(try sample)
        #expect(read.elements.count == 55)
        #expect(read.scale == 0.001)
        let bar = try #require(read.elements.values.first)
        #expect(bar.diameter == 12 && bar.role == "MAIN" && bar.host != nil)
        let properties = try #require(read.properties.values.first)
        #expect(properties.cover == 0.025 && properties.areaRatio == 0.01)
        #expect(properties.source == "Pset_ConcreteElementGeneral")
    }

    @Test("Bars converted and measured land in their wall, and become its mats; the slab takes its ratio")
    func attachesAndMaps() async throws {
        let ifc = try sample
        let mesh = try await IFCImporter.convert(ifc)
        let elements = try #require(mesh.buildingElements)
        let (attached, notes) = await IFCReinforcementReader.attach(
            try await metadata(ifc), to: elements, ifc: ifc, origin: try #require(mesh.buildingOrigin),
            converter: IFCImporter.converterURL)
        #expect(notes.contains { $0.contains("55 of its 55 reinforcing elements placed") })
        let wall = try #require(attached.first { $0.name == "Wall" })
        let bars = try #require(wall.reinforcement?.bars)
        #expect(bars.count == 55)
        // The IFC's 12 mm, in its own millimetres, over the measured size of the faceted bars.
        #expect(bars.allSatisfy { $0.diameter == 0.012 && $0.sizeSource.contains("own attributes") })
        let vertical = bars.filter { abs($0.axis.z) > 0.99 }
        #expect(vertical.count == 40 && vertical.allSatisfy { abs($0.length - 3) < 0.05 })
        #expect(attached.first { $0.name == "Roof slab" }?.reinforcement?.properties?.areaRatio == 0.01)

        let structure = try IFCStructure(elements: attached, options: .init(elementSize: 0.25))
        let member = try #require(structure.members.first { $0.name == "Wall" })
        #expect(
            member.reinforcementAssumed == false && member.reinforcementSource?.contains("55 bars") == true)
        let slab = try #require(structure.members.first { $0.name == "Roof slab" })
        #expect(slab.reinforcementSource?.contains("Pset_ConcreteElementGeneral") == true)
        let shells = try ShellMesh(model: structure.model)
        let plate = try #require(shells.elements.first { $0.solid == member.solid })
        let perMetre = 5 * Float.pi * 0.006 * 0.006
        #expect(plate.bars.count == 2)
        #expect(plate.bars.allSatisfy { abs($0.y / perMetre - 1) < 0.03 })
    }
}
