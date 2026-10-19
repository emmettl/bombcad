import BlastCore
import Foundation
import Metal
import Testing
import simd

@testable import BombCAD

/// The worked example of docs/using-the-app.md, "From architectural plans": the two-storey house
/// drawn as a DXF plan (Samples/Plans), raised in FreeCAD and exported as IFC, imported as shells
/// and panes, and struck by a charge on the ground in front of it. Set `BOMBCAD_PLAN_STUDY` to a
/// directory for its report.
@Suite("A house from a floor plan under a blast", .serialized)
struct PlanHouseStudyTests {
    static let output = ProcessInfo.processInfo.environment["BOMBCAD_PLAN_STUDY"]
    static let cellSize: Float = 0.25
    static let duration = 0.15
    /// 20 kg of TNT on the ground 10 m before the front wall's middle; the open faces 4 m/kg^(1/3)
    /// (10.9 m) from it and from the house.
    static let corner = SIMD3<Float>(11, 21, 0)
    static let domain = SIMD3<Float>(30, 38.5, 17)
    static let charge = Charge(mass: 20, position: SIMD3(15, 11, 0))

    func fixture() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Samples/Plans/house.ifc")
    }

    @Test(
        "The plan's house imports with its walls' materials and stands, then takes the blast",
        .enabled(if: output != nil))
    func study() async throws {
        let prepared = try await IFCImporter.prepare(Data(contentsOf: fixture()))
        let source = try await IFCImporter.convert(prepared, includedIDs: prepared.defaultIDs)
        try await run(source, name: "house.ifc", report: "plan-house-20kg")
    }

    /// The same house read from its DXF plan in BombCAD (`FloorPlan`), without FreeCAD, under the
    /// same charge: the two routes compared.
    @Test("The house read from its DXF plan takes the same blast", .enabled(if: output != nil))
    func studyFromPlan() async throws {
        let url = fixture().deletingLastPathComponent().appendingPathComponent("house-plan.dxf")
        let drawing = try DXFDrawing(data: Data(contentsOf: url))
        var options = FloorPlan.Options()
        options.metresPerUnit = try #require(drawing.metresPerUnit)
        options.roles = [
            "WALL-EXT": .wall(.cavityBrickBlock), "WALL-INT": .wall(.block100), "DOOR": .door,
            "WINDOW-GF": .window, "WINDOW-FF": .window,
        ]
        options.layerStoreys = ["DOOR": 0, "WINDOW-GF": 0, "WINDOW-FF": 1]
        let plan = FloorPlan.analyse(drawing, options: options)
        let source = try ImportedMesh(
            buildingElements: FloorPlan.buildingElements(plan, options: options), notes: plan.notes,
            origin: SIMD3(plan.bounds.min.x, plan.bounds.min.y, 0))
        try await run(source, name: "house-plan.dxf", report: "plan-house-dxf-20kg")
    }

    func run(_ source: ImportedMesh, name: String, report reportName: String) async throws {
        let output = try #require(Self.output)
        let preview = try source.transformed(scale: 1, yUp: false, corner: Self.corner)
            .preview(cellSize: Self.cellSize, domain: Self.domain)
        var model = ImportedModel(
            name: name, source: source, scale: 1, yUp: false, corner: Self.corner,
            behavior: .deformable,
            preview: preview)
        model.structuralOptions = IFCStructure.Options(elementSize: 0.25)
        var scenario = Scenario(
            name: "House from a plan", domainSize: Self.domain, boxes: [], charge: Self.charge,
            gauges: [Gauge("Before the front wall", at: Self.corner + SIMD3(4, -0.2, 1.5))])
        try scenario.installImport(model, material: .reinforcedConcrete, fixedBase: true)
        #expect(scenario.tightOpenFaces.isEmpty, "\(scenario.tightOpenFaces)")
        let installed = try #require(scenario.importedModels?.first)
        let report = try #require(installed.structuralReport)
        let body = try #require(scenario.structuralObjects.first?.structure)

        // The cavity walls are the brick leaf, carrying the block's mass; the partitions block.
        for member in report.members where member.role == .shell && member.name.contains("wall") {
            #expect(
                member.material == StructureMaterial.masonry.name, "\(member.name): \(member.material ?? "-")"
            )
        }
        for member in report.members where member.name.contains("partition") {
            #expect(
                member.material == StructureMaterial.concreteBlock.name,
                "\(member.name): \(member.material ?? "-")")
        }

        let device = try #require(MTLCreateSystemDefaultDevice())
        let started = ContinuousClock.now
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: Self.cellSize)
        try solver.load(scenario)
        let shells = try #require(solver.shells)
        let walls = report.members.filter { $0.role == .shell }.compactMap { member in
            member.solid.map { (member.name, body.solids[$0]) }
        }
        let nodes: [[Int]] = walls.map { _, box in
            (0..<shells.nodeCount).filter { n in
                let p = shells.referencePositions[n]
                return (0..<3).allSatisfy { p[$0] >= box.min[$0] - 0.01 && p[$0] <= box.max[$0] + 0.01 }
            }
        }
        // From the house at rest under its own weight (settled as `load` leaves it).
        let rest = nodes.map { list in list.map { shells.node($0).displacement } }
        var peaks = [Float](repeating: 0, count: walls.count)
        var peakAt = [SIMD3<Float>](repeating: .zero, count: walls.count)
        while solver.time < Self.duration {
            let batch = solver.advance(steps: 16, timeLimit: Self.duration)
            if batch.steps == 0 && !solver.airIsAsleep { break }
            for (w, list) in nodes.enumerated() {
                for (k, n) in list.enumerated() {
                    let moved = simd_length(shells.node(n).displacement - rest[w][k])
                    if moved > peaks[w] {
                        peaks[w] = moved
                        peakAt[w] = shells.referencePositions[n] - Self.corner
                    }
                }
            }
        }
        let elapsed = ContinuousClock.now - started
        let ambient = scenario.atmosphere.pressure
        let gauge = solver.gaugeHistories[0]
        let peak = (gauge.map(\.pressure).max() ?? ambient) - ambient
        let summary = shells.summary()

        var text =
            "The two-storey house from Samples/Plans (\(name)) at \(Self.corner), \(Self.charge.mass) kg of TNT at "
            + "\(Self.charge.position), cells of \(Self.cellSize) m, \(Self.duration) s, \(String(format: "%.0f", Double(elapsed.components.seconds))) s to run\n\n"
        text += "Imported: \(report.members.count) elements, \(report.connections.count) connections\n"
        for member in report.members {
            text +=
                "  \(member.name): \(member.role.rawValue), \(member.material ?? "-") (\(member.materialSource)); "
                + member.notes.joined(separator: " ") + "\n"
        }
        for line in report.supports + report.assumptions { text += "  \(line)\n" }
        text += String(format: "\nBefore the front wall: %.0f kPa\n", peak / 1000)
        text += "Elements failed: \(summary.erodedElements) of \(shells.elementCount)\n"
        for (w, (wall, value)) in zip(walls, peaks).enumerated() {
            text += String(
                format: "  %@: peak %.1f mm at (%.2f, %.2f, %.2f) m\n", wall.0, value * 1000, peakAt[w].x,
                peakAt[w].y,
                peakAt[w].z)
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        try text.write(toFile: output + "/\(reportName).txt", atomically: true, encoding: .utf8)
        print(text)
        #expect(peaks.allSatisfy { $0.isFinite })
    }
}
