import Foundation
import Testing
import simd

@testable import BlastCore

@Suite("Imported model picking and placement")
struct ImportInteractionTests {
    private func cube(size: Float = 1, offset: SIMD3<Float> = .zero, base: Int = 0) -> String {
        let vertices: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 1),
            SIMD3(1, 1, 1), SIMD3(0, 1, 1),
        ]
        let faces = [
            [1, 4, 3, 2], [5, 6, 7, 8], [1, 2, 6, 5], [2, 3, 7, 6], [3, 4, 8, 7], [4, 1, 5, 8],
        ]
        return vertices.map {
            let p = $0 * size + offset
            return "v \(p.x) \(p.y) \(p.z)"
        }.joined(separator: "\n") + "\n"
            + faces.map { "f " + $0.map { String($0 + base) }.joined(separator: " ") }.joined(separator: "\n")
    }
    private func model(boxes: [Box], behavior: ImportedModel.Behavior = .rigid) throws -> ImportedModel {
        let source = try ImportedMesh(data: Data(cube().utf8), fileExtension: "obj")
        var preview = try source.preview(cellSize: 0.25, domain: SIMD3(repeating: 10))
        preview.boxes = boxes
        return ImportedModel(
            name: "Imported", source: source, scale: 1, yUp: false, corner: .zero, behavior: behavior,
            preview: preview)
    }
    private func scene() -> Scenario {
        Scenario(
            name: "Check", domainSize: SIMD3(repeating: 10), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(9, 9, 9)))
    }
    @Test("Parallel and interior rays intersect robustly")
    func rayIntersection() {
        let box = Box(min: SIMD3(1, 1, 1), max: SIMD3(2, 2, 2))
        #expect(ScenePicking.distance(to: box, origin: SIMD3(1.5, 0, 1.5), direction: SIMD3(0, 1, 0)) == 1)
        #expect(ScenePicking.distance(to: box, origin: SIMD3(0, 0, 1.5), direction: SIMD3(0, 1, 0)) == nil)
        #expect(ScenePicking.distance(to: box, origin: SIMD3(repeating: 1.5), direction: SIMD3(0, 1, 0)) == 0)
        #expect(ScenePicking.distance(to: box, origin: SIMD3(1.5, 3, 1.5), direction: SIMD3(0, 1, 0)) == nil)
    }
    @Test("Picking respects occupied gaps, closest imported volumes and native occlusion")
    func picking() throws {
        let front = try model(boxes: [Box(min: SIMD3(1, 1, 0), max: SIMD3(2, 2, 1))])
        let back = try model(boxes: [Box(min: SIMD3(1, 4, 0), max: SIMD3(2, 5, 1))])
        var layout = scene()
        layout.importedModels = [back, front]
        let origin = SIMD3<Float>(1.5, 0, 0.5)
        let direction = SIMD3<Float>(0, 1, 0)
        #expect(ScenePicking.importedModel(in: layout, origin: origin, direction: direction) == front.id)
        #expect(ScenePicking.importedModel(in: layout, origin: SIMD3(3, 0, 0.5), direction: direction) == nil)
        layout.boxes = [Box(min: SIMD3(1, 0.25, 0), max: SIMD3(2, 0.75, 1))]
        #expect(ScenePicking.importedModel(in: layout, origin: origin, direction: direction) == nil)
        layout.boxes = []
        layout.importedModels = [
            try model(boxes: [
                Box(min: SIMD3(0, 2, 0), max: SIMD3(1, 3, 1)), Box(min: SIMD3(3, 2, 0), max: SIMD3(4, 3, 1)),
            ])
        ]
        #expect(ScenePicking.importedModel(in: layout, origin: SIMD3(2, 0, 0.5), direction: direction) == nil)
    }
    @Test("Structural openings permit picking through them and detached sources are not pickable")
    func openingsAndDetach() throws {
        let imported = try model(boxes: [Box(min: SIMD3(1, 4, 1), max: SIMD3(2, 5, 2))])
        var layout = scene()
        layout.importedModels = [imported]
        var body = StructureModel(solids: [Box(min: SIMD3(0, 1, 0), max: SIMD3(3, 2, 3))], elementSize: 0.25)
        body.openings = [Box(min: SIMD3(1, 1, 1), max: SIMD3(2, 2, 2))]
        layout.structure = body
        #expect(
            ScenePicking.importedModel(in: layout, origin: SIMD3(1.5, 0, 1.5), direction: SIMD3(0, 1, 0))
                == imported.id)
        #expect(
            ScenePicking.importedModel(in: layout, origin: SIMD3(0.5, 0, 1.5), direction: SIMD3(0, 1, 0))
                == nil)
        layout.detachImport(id: imported.id)
        #expect(
            ScenePicking.importedModel(in: layout, origin: SIMD3(1.5, 0, 1.5), direction: SIMD3(0, 1, 0))
                == nil)
    }
    @Test("Imported deformable bodies are picked at their current edited layout volumes")
    func structuralOwner() throws {
        let imported = try model(
            boxes: [Box(min: SIMD3(4, 4, 0), max: SIMD3(5, 5, 1))], behavior: .deformable)
        var layout = scene()
        layout.importedModels = [imported]
        layout.structure = StructureModel(
            solids: [Box(min: SIMD3(1, 1, 0), max: SIMD3(2, 2, 1))], elementSize: 0.25)
        #expect(
            ScenePicking.importedModel(in: layout, origin: SIMD3(1.5, 0, 0.5), direction: SIMD3(0, 1, 0))
                == imported.id)
        #expect(
            ScenePicking.importedModel(in: layout, origin: SIMD3(4.5, 0, 0.5), direction: SIMD3(0, 1, 0))
                == nil)
    }

    @Test("Overlap checks exclude an edited model itself and subtract structural openings")
    func overlaps() throws {
        let boxes = [Box(min: SIMD3(1, 1, 0), max: SIMD3(2, 2, 1))]
        let own = try model(boxes: boxes)
        var layout = scene()
        layout.importedModels = [own]
        let ownReport = try ImportPlacementReport.analyze(
            boxes: boxes, scenario: layout, editingID: own.id, cellSize: 0.25)
        #expect(!ownReport.issues.contains { $0.kind == .overlap })
        layout.boxes = [Box(min: SIMD3(1.5, 1, 0), max: SIMD3(2.5, 2, 1))]
        let overlap = try ImportPlacementReport.analyze(
            boxes: boxes, scenario: layout, editingID: own.id, cellSize: 0.25)
        #expect(
            overlap.issues.first { $0.kind == .overlap }?.bounds
                == Box(min: SIMD3(1.5, 1, 0), max: SIMD3(2, 2, 1)))
        layout.importedModels = nil
        layout.boxes = []
        layout.structure = StructureModel(
            solids: [Box(min: .zero, max: SIMD3(repeating: 4))],
            openings: [Box(min: SIMD3(repeating: 1), max: SIMD3(repeating: 3))], elementSize: 0.25)
        let hollow = try ImportPlacementReport.analyze(
            boxes: [Box(min: SIMD3(repeating: 1.25), max: SIMD3(repeating: 2.75))], scenario: layout,
            cellSize: 0.25)
        #expect(!hollow.issues.contains { $0.kind == .overlap })
    }
    @Test("All charge locations inside the sampled import are highlighted")
    func charges() throws {
        var layout = scene()
        layout.charge.position = SIMD3(1.5, 1.5, 0.5)
        layout.additionalCharges = [Charge(mass: 1, position: SIMD3(1.25, 1.25, 0.25))]
        let report = try ImportPlacementReport.analyze(
            boxes: [Box(min: SIMD3(1, 1, 0), max: SIMD3(2, 2, 1))], scenario: layout, cellSize: 0.25)
        #expect(report.issues.filter { $0.kind == .blockedCharge }.count == 2)
        #expect(report.issues.filter { $0.isCritical }.count == 2)
    }
    @Test("Face-connected volumes form one component while edge contact does not")
    func connectivity() throws {
        let first = Box(min: .zero, max: SIMD3(repeating: 1))
        let face = try ImportPlacementReport.analyze(
            boxes: [first, Box(min: SIMD3(1, 0, 0), max: SIMD3(2, 1, 1))], scenario: scene(), cellSize: 0.25)
        #expect(face.componentCount == 1)
        #expect(!face.issues.contains { $0.kind == .floating || $0.kind == .disconnected })
        let edge = try ImportPlacementReport.analyze(
            boxes: [first, Box(min: SIMD3(1, 1, 0), max: SIMD3(2, 2, 1))], scenario: scene(), cellSize: 0.25)
        #expect(edge.componentCount == 2)
        #expect(edge.issues.filter { $0.kind == .disconnected }.count == 1)
    }
    @Test("Floating components explain fixed-base limitations without certifying supports")
    func floating() throws {
        let boxes = [
            Box(min: .zero, max: SIMD3(repeating: 1)), Box(min: SIMD3(3, 3, 2), max: SIMD3(4, 4, 3)),
        ]
        let report = try ImportPlacementReport.analyze(
            boxes: boxes, scenario: scene(), cellSize: 0.25, fixedBase: true)
        #expect(report.componentCount == 2)
        #expect(report.issues.filter { $0.kind == .floating }.count == 1)
        #expect(report.issues.first { $0.kind == .floating }?.detail.contains("may not hold") == true)
        #expect(report.warnings.first?.contains("does not establish a structural connection") == true)
    }
    @Test("Placement budgets explicitly report incomplete checks")
    func bounds() throws {
        var layout = scene()
        layout.boxes = Array(repeating: Box(min: .zero, max: SIMD3(repeating: 1)), count: 4097)
        let report = try ImportPlacementReport.analyze(boxes: [], scenario: layout, cellSize: 0.25)
        #expect(report.checksIncomplete)
        #expect(report.warnings.count == 2)
    }
    @Test("A saved demonstration layout preserves placement warnings for visual checking")
    func demoLayout() throws {
        let source = try ImportedMesh(
            data: Data((cube(size: 2) + "\n" + cube(offset: SIMD3(4, 4, 2), base: 8)).utf8),
            fileExtension: "obj")
        let corner = SIMD3<Float>(2, 2, 0)
        let preview = try source.transformed(scale: 1, yUp: false, corner: corner).preview(
            cellSize: 0.25, domain: SIMD3(10, 10, 6))
        let imported = ImportedModel(
            name: "Placement demo", source: source, scale: 1, yUp: false, corner: corner, behavior: .rigid,
            preview: preview)
        var layout = Scenario(
            name: "Placement demo", domainSize: SIMD3(10, 10, 6),
            boxes: [Box(min: SIMD3(3.5, 2, 0), max: SIMD3(4.5, 3, 1))],
            charge: Charge(mass: 0, position: SIMD3(3, 3, 0.5)))
        try layout.installImport(imported, material: .plainConcrete, fixedBase: false)
        let data = try JSONEncoder().encode(layout)
        let restored = try JSONDecoder().decode(Scenario.self, from: data)
        let report = try ImportPlacementReport.analyze(
            boxes: preview.boxes, scenario: restored, editingID: imported.id, cellSize: 0.25)
        #expect(
            Set(report.issues.map { $0.kind }) == Set([.overlap, .blockedCharge, .floating, .disconnected]))
        try data.write(to: URL(fileURLWithPath: "/private/tmp/bombcad-placement-demo.json"))
    }
}
