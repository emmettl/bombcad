import BlastCore
import Foundation
import Metal
import Testing
import simd

@testable import BombCAD

/// The small house imported as shells and beams, under a blast, against the same house built by
/// hand in the editor and against the IFC imported as rigid obstacles. Set
/// `BOMBCAD_IFC_STUDY` to a directory for its report; it runs three coupled blasts of 0.1 s, of
/// 10 kg unless `BOMBCAD_IFC_STUDY_MASS` says otherwise.
@Suite("IFC structure under a blast", .serialized)
struct IFCStructureStudyTests {
    static let output = ProcessInfo.processInfo.environment["BOMBCAD_IFC_STUDY"]

    /// The house's corner, the charge and the air.
    static let corner = SIMD3<Float>(10, 6, 0)
    static let domain = SIMD3<Float>(24, 20, 9)
    static let cellSize: Float = 0.25
    static let charge = Charge(
        mass: Float(ProcessInfo.processInfo.environment["BOMBCAD_IFC_STUDY_MASS"] ?? "10") ?? 10,
        position: SIMD3(4, 9.3, 0))
    static let duration = 0.1

    struct Run {
        var name: String
        var walls: [(name: String, box: Box, peak: Float)]
        var eroded: Int
        var seconds: Double
        var elements: Int
    }

    func fixture() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(
                "Samples/Importer/Buildings/building-architecture.ifc")
    }

    func scenario() -> Scenario {
        Scenario(
            name: "IFC house", domainSize: Self.domain, boxes: [], charge: Self.charge,
            gauges: [Gauge("Before the west wall", at: Self.corner + SIMD3(0, 3.3, 1.5))])
    }

    /// The house imported from its IFC, as a structure (`deformable`) or as rigid obstacles.
    func imported(deformable: Bool) async throws -> (Scenario, ImportedModel) {
        let prepared = try await IFCImporter.prepare(Data(contentsOf: fixture()))
        let source = try await IFCImporter.convert(prepared, includedIDs: prepared.defaultIDs)
        let preview = try source.transformed(scale: 1, yUp: false, corner: Self.corner)
            .preview(cellSize: Self.cellSize, domain: Self.domain)
        var model = ImportedModel(
            name: "building-architecture.ifc", source: source, scale: 1, yUp: false, corner: Self.corner,
            behavior: deformable ? .deformable : .rigid, preview: preview)
        if deformable { model.structuralOptions = IFCStructure.Options(elementSize: 0.25) }
        var scenario = scenario()
        try scenario.installImport(model, material: .reinforcedConcrete, fixedBase: true)
        return (scenario, scenario.importedModels!.first!)
    }

    /// Runs the blast, recording each wall's peak displacement.
    func run(_ name: String, _ scenario: Scenario, walls: [(String, Box)]) throws -> Run {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let started = ContinuousClock.now
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: Self.cellSize)
        try solver.load(scenario)
        var peaks = [Float](repeating: 0, count: walls.count)
        let shells = solver.shells
        let nodes: [[Int]] = walls.map { _, box in
            guard let shells else { return [] }
            return (0..<shells.nodeCount).filter { n in
                let p = shells.referencePositions[n]
                return (0..<3).allSatisfy { p[$0] >= box.min[$0] - 0.01 && p[$0] <= box.max[$0] + 0.01 }
            }
        }
        while solver.time < Self.duration {
            let batch = solver.advance(steps: 16, timeLimit: Self.duration)
            if batch.steps == 0 && !solver.airIsAsleep { break }
            guard let shells else { continue }
            for (w, list) in nodes.enumerated() {
                for n in list { peaks[w] = max(peaks[w], simd_length(shells.node(n).displacement)) }
            }
        }
        let elapsed = ContinuousClock.now - started
        return Run(
            name: name, walls: zip(walls, peaks).map { ($0.0, $0.1, $1) },
            eroded: shells?.summary().erodedElements ?? 0,
            seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18,
            elements: (shells?.elementCount ?? 0) + (shells?.beamCount ?? 0))
    }

    @Test(
        "The IFC house as shells moves as the same house built by hand; the cost against rigid is reported",
        .enabled(if: output != nil))
    func study() async throws {
        let output = try #require(Self.output)
        // As imported.
        let (structural, model) = try await imported(deformable: true)
        let report = try #require(model.structuralReport)
        let body = try #require(structural.structuralObjects.first?.structure)
        let walls = report.members.filter { $0.role == .shell }.map { ($0.name, body.solids[$0.solid!]) }

        // By hand: the three outer walls as a user types them into the editor from the drawing,
        // to the centimetre, as shells of the materials the report gives, the base tied by
        // starter bars; the roof, the floor and the plumbing wall (gypsum board) the same rigid
        // obstacles as the import's.
        func typed(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Box {
            Box(min: Self.corner + a, max: Self.corner + b)
        }
        var hand = StructureModel(
            solids: [
                typed(SIMD3(0.30, 0.30, 0), SIMD3(0.50, 6.30, 3.63)),
                typed(SIMD3(4.30, 0.30, 0), SIMD3(4.50, 2.10, 3.63)),
                typed(SIMD3(5.70, 2.10, 0), SIMD3(5.90, 6.30, 2.23)),
            ], material: .reinforcedConcrete, elementSize: 0.25)
        // Each wall's material as the report gives it, chosen for it in the editor.
        hand.solidMaterial = body.solidMaterial
        hand.elementKind = .shell
        hand.fixedBase = true
        hand.baseAnchorage = .dowelled(ratio: BaseConnection.dowelRatio)
        var built = scenario()
        built.boxes = model.rigidBoxes
        _ = try built.addStructureObject(hand, name: "House by hand")

        let (rigid, _) = try await imported(deformable: false)

        let runs = [
            try run("Imported as shells", structural, walls: walls),
            try run("Built by hand", built, walls: walls),
            try run("Imported rigid", rigid, walls: []),
        ]
        var text =
            "The small house (building-architecture.ifc) at \(Self.corner), \(Self.charge.mass) kg of TNT at "
            + "\(Self.charge.position), cells of \(Self.cellSize) m, \(Self.duration) s\n\n"
        text += "Imported: \(report.members.count) elements, \(report.connections.count) connections\n"
        for member in report.members {
            text +=
                "  \(member.name): \(member.role.rawValue), \(member.material ?? "-") (\(member.materialSource))"
                + (member.solid.map { " \(body.solids[$0].min) \(body.solids[$0].max)" } ?? "") + "; "
                + member.notes.joined(separator: " ") + "\n"
        }
        for line in report.supports + report.assumptions { text += "  \(line)\n" }
        text += "\n"
        for run in runs {
            text +=
                "\(run.name): \(run.elements) elements, \(run.eroded) eroded, "
                + String(format: "%.1f s\n", run.seconds)
            for wall in run.walls {
                text += String(format: "  %@: peak %.2f mm\n", wall.name, wall.peak * 1000)
            }
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        try text.write(
            toFile: output + "/blast-house-\(Int(Self.charge.mass))kg.txt", atomically: true, encoding: .utf8)
        print(text)
        // The stated differences: walls typed to the centimetre, their tops 4 mm higher than
        // the IFC's. The struck wall's peak within 5%; the sheltered walls', a tenth as large
        // and loaded by the wave bent round the house, within 10%.
        for (a, b) in zip(runs[0].walls, runs[1].walls) {
            let struck = max(a.peak, b.peak) > 0.01
            #expect(
                abs(a.peak - b.peak) <= (struck ? 0.05 : 0.1) * max(a.peak, b.peak),
                "\(a.name): \(a.peak) against \(b.peak)")
        }
        // Where the walls break, the elements removed within a twentieth (or two).
        #expect(abs(runs[0].eroded - runs[1].eroded) <= max(2, runs[0].eroded / 20))
    }
}
