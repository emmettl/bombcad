import BlastCore
import Foundation
import Metal
import Testing
import simd

@testable import BombCAD

/// IFC buildings as exposure-only envelopes against the same buildings as rigid obstacles. Run
/// with BOMBCAD_ENVELOPE_STUDY=<folder>; it writes a report there. The quick check (the duplex,
/// coarse) always runs when the IFC converter is prepared.
@Suite("IFC envelopes against rigid imports", .serialized)
struct EnvelopeImportStudyTests {
    private static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "Samples/Importer/Buildings")

    struct Case: Codable {
        var building: String
        var cellSize: Float
        var representation: String
        var solidCells: Int
        var boxes: Int
        var steps: Int
        var seconds: Double
        var faces: Int
        var peakPa: Float
        var positiveLoadingNS: Double
        var signedImpulseNS: SIMD3<Double>
        var mapPeak: [Float]
        var mapImpulse: [Float]
    }

    struct Comparison: Codable {
        var building: String
        var cellSize: Float
        var pair: String
        var differingCells: Int
        var peakL1: Double
        var impulseL1: Double
        var loadingDifference: Double
        var vectorImpulseDifference: Double
    }

    /// One run of `scene` for `duration`, its surfaces observed as `observer`.
    private func run(
        _ scene: Scenario, observer: SceneObject, cellSize: Float, duration: Double, device: MTLDevice,
        building: String, representation: String
    ) throws -> Case {
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: cellSize)
        try solver.configureEnvelopeExposure(objects: [observer])
        let clock = Date()
        let steps = solver.advance(until: duration).steps
        let seconds = Date().timeIntervalSince(clock)
        let grid = solver.grid
        var solid = 0
        for k in 0..<grid.nz {
            for j in 0..<grid.ny { for i in 0..<grid.nx where solver.isSolid(i, j, k) { solid += 1 } }
        }
        // The map at 1.5 m, with solid cells as NaN, to compare cell by cell.
        let k = min(Int(1.5 / cellSize), grid.nz - 1)
        var peak: [Float] = []
        var impulse: [Float] = []
        for j in 0..<grid.ny {
            for i in 0..<grid.nx {
                let open = !solver.isSolid(i, j, k)
                peak.append(open ? solver.peakOverpressure(i, j, k) : .nan)
                impulse.append(open ? solver.impulse(i, j, k) : .nan)
            }
        }
        let summary = try #require(solver.envelopeExposureSummaries()?.first)
        return Case(
            building: building, cellSize: cellSize, representation: representation, solidCells: solid,
            boxes: scene.rigidBoxes.count, steps: steps, seconds: seconds, faces: summary.faceCount,
            peakPa: summary.peakPositivePa, positiveLoadingNS: summary.surfacePositiveImpulseNS,
            signedImpulseNS: summary.signedImpulseNS, mapPeak: peak, mapImpulse: impulse)
    }

    private func compare(_ a: Case, _ b: Case, pair: String, scene: Scenario, cellSize: Float) -> Comparison {
        // Relative L1 over the map's cells open in both, beyond 3 m of the charge.
        func l1(_ x: [Float], _ y: [Float]) -> Double {
            let nx = Int((scene.domainSize.x / cellSize).rounded())
            var (difference, total) = (0.0, 0.0)
            for n in x.indices where !x[n].isNaN && !y[n].isNaN {
                let p = SIMD2(Float(n % nx) + 0.5, Float(n / nx) + 0.5) * cellSize
                guard simd_distance(p, SIMD2(scene.charge.position.x, scene.charge.position.y)) > 3 else {
                    continue
                }
                difference += Double(abs(x[n] - y[n]))
                total += Double(abs(x[n]))
            }
            return total > 0 ? difference / total : 0
        }
        return Comparison(
            building: a.building, cellSize: cellSize, pair: pair,
            differingCells: abs(a.solidCells - b.solidCells),
            peakL1: l1(a.mapPeak, b.mapPeak), impulseL1: l1(a.mapImpulse, b.mapImpulse),
            loadingDifference: abs(b.positiveLoadingNS / a.positiveLoadingNS - 1),
            vectorImpulseDifference: simd_length(b.signedImpulseNS - a.signedImpulseNS)
                / max(simd_length(a.signedImpulseNS), 1e-9))
    }

    /// The building in a domain with room round it, the charge `standoff` in front of it.
    private func study(
        _ file: String, cellSize: Float, standoff: Float, mass: Float, duration: Double, device: MTLDevice
    ) async throws -> (cases: [Case], comparisons: [Comparison], conversion: EnvelopeConversionReport) {
        // As in the app: elements that fail validation (open meshes) are excluded, and it is retried.
        // Windows and doors are left out by choice, as the import's repairs now make most of them
        // closed solids: their bounds become the envelope's openings.
        let prepared = try await IFCImporter.prepare(
            Data(contentsOf: Self.folder.appendingPathComponent(file)))
        var included = prepared.defaultIDs
        included.subtract(
            prepared.inventory.filter { ["IfcWindow", "IfcDoor"].contains($0.ifcClass) }.map(\.id))
        var excluded: [String] = []
        var converted: ImportedMesh?
        while converted == nil {
            do {
                converted = try await IFCImporter.convert(prepared, includedIDs: included)
            } catch let failures as IFCImporter.ElementFailures {
                let ids = Set(failures.failures.map(\.id))
                excluded += prepared.inventory.filter { ids.contains($0.id) }.map(\.ifcClass)
                included.subtract(ids)
            }
        }
        let source = try #require(converted)
        print(
            "\(file): \(excluded.count) elements excluded as open meshes: \(Dictionary(excluded.map { ($0, 1) }, uniquingKeysWith: +))"
        )
        let size = source.bounds.size
        let margin: Float = 8
        let domain = SIMD3(size.x + 2 * margin, size.y + 2 * margin + standoff, size.z + 6)
        let corner = SIMD3(margin, margin + standoff, 0)
        let preview = try source.transformed(scale: 1, yUp: false, corner: corner).preview(
            cellSize: cellSize, domain: domain)
        let model = ImportedModel(
            name: file, source: source, scale: 1, yUp: false, corner: corner, behavior: .rigid,
            preview: preview)
        var rigid = Scenario(
            name: file, domainSize: domain, boxes: [],
            charge: Charge(mass: mass, position: SIMD3(domain.x / 2, margin, 0.5)))
        rigid.gauges = []
        rigid.importedModels = [model]
        // Placing source-local bounds as the import is placed puts each element where the import does.
        let origin = try #require(source.buildingOrigin)
        for (local, placed) in zip(
            source.buildingElements ?? [], try model.transformedSource().buildingElements ?? [])
        {
            let box = model.sceneBox(
                sourceLocal: SIMD3<Double>(local.mesh.bounds.min), SIMD3<Double>(local.mesh.bounds.max))
            #expect(
                simd_distance(box.min, placed.mesh.bounds.min) < 1e-3
                    && simd_distance(box.max, placed.mesh.bounds.max) < 1e-3)
        }
        _ = origin
        let clock = Date()
        let openings = try await IFCImporter.excludedOpeningBoxes(of: model)
        let boundsSeconds = Date().timeIntervalSince(clock)
        var plain = rigid
        let conversion = try #require(try plain.useEnvelopes(importIDs: [model.id]).first)
        var opened = rigid
        let openedConversion = try #require(
            try opened.useEnvelopes(importIDs: [model.id], openings: [model.id: openings]).first)
        print(
            "\(file): \(openings.count) left-out windows and doors read as opening bounds in \(String(format: "%.2f", boundsSeconds)) s"
        )
        let observer = SceneObject(
            name: "observer", representation: .envelope(try BuildingEnvelope(solids: preview.boxes)))
        let r = try run(
            rigid, observer: observer, cellSize: cellSize, duration: duration, device: device, building: file,
            representation: "rigid import")
        let e0 = try run(
            plain, observer: plain.envelopeObjects[0], cellSize: cellSize, duration: duration, device: device,
            building: file, representation: "envelope")
        let e1 = try run(
            opened, observer: opened.envelopeObjects[0], cellSize: cellSize, duration: duration,
            device: device,
            building: file, representation: "envelope, left-out windows and doors cut as openings")
        return (
            [r, e0, e1],
            [
                compare(r, e0, pair: "envelope against the rigid import", scene: rigid, cellSize: cellSize),
                compare(
                    r, e1, pair: "envelope with openings against the rigid import", scene: rigid,
                    cellSize: cellSize),
            ], openedConversion.openingElements > 0 ? openedConversion : conversion
        )
    }

    @Test(
        "A duplex as an envelope is exactly its rigid import; its left-out windows and doors become openings",
        .enabled(if: IFCImporter.converterURL != nil && MTLCreateSystemDefaultDevice() != nil))
    func quick() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let (cases, comparisons, conversion) = try await study(
            "duplex-apartment.ifc", cellSize: 0.5, standoff: 6, mass: 5, duration: 0.04, device: device)
        // The duplex's 24 windows and 14 doors, left out of the rigid import (their walls' openings
        // are cut by the converter), become the envelope's openings.
        #expect(conversion.openingElements == 38)
        let exact = comparisons[0]
        #expect(exact.differingCells == 0 && exact.peakL1 == 0 && exact.impulseL1 == 0, "\(exact)")
        #expect(exact.loadingDifference < 1e-9, "\(exact)")
        #expect(cases.allSatisfy { $0.faces > 0 })
        // The bounds cut a little more than the holes: frames, sills and reveals.
        #expect(comparisons[1].differingCells > 0)
    }

    @Test(
        "Whole buildings as envelopes against rigid imports, with costs",
        .enabled(
            if: ProcessInfo.processInfo.environment["BOMBCAD_ENVELOPE_STUDY"] != nil
                && IFCImporter.converterURL != nil
        ))
    func full() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let output = URL(
            filePath: try #require(ProcessInfo.processInfo.environment["BOMBCAD_ENVELOPE_STUDY"]),
            directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var cases: [Case] = []
        var comparisons: [Comparison] = []
        var lines: [String] = []
        for (file, cells) in [
            ("building-architecture.ifc", [Float(0.5), 0.25]), ("duplex-apartment.ifc", [0.5, 0.25]),
        ] {
            for cell in cells {
                let clock = Date()
                let result = try await study(
                    file, cellSize: cell, standoff: 8, mass: 10, duration: 0.08, device: device)
                cases += result.cases
                comparisons += result.comparisons
                lines.append(
                    String(
                        format: "%@ at %.3f m (%.1f s in all): %@", file, cell,
                        Date().timeIntervalSince(clock),
                        result.conversion.note))
                for c in result.cases {
                    lines.append(
                        String(
                            format:
                                "  %@: %d solid cells, %d boxes, %d faces, %d steps in %.2f s; peak %.1f kPa, "
                                + "positive loading %.0f N s", c.representation, c.solidCells, c.boxes,
                            c.faces, c.steps,
                            c.seconds, c.peakPa / 1000, c.positiveLoadingNS))
                }
                for m in result.comparisons {
                    lines.append(
                        String(
                            format:
                                "  %@: %d cells differ; maps %.2f%% peak, %.2f%% impulse; loading %.2f%%, "
                                + "vector impulse %.2f%%", m.pair, m.differingCells, 100 * m.peakL1,
                            100 * m.impulseL1,
                            100 * m.loadingDifference, 100 * m.vectorImpulseDifference))
                }
            }
        }
        let text = lines.joined(separator: "\n") + "\n"
        print(text)
        try text.write(to: output.appending(path: "report.txt"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(comparisons).write(to: output.appending(path: "comparisons.json"))
        for c in comparisons where c.pair == "envelope against the rigid import" {
            #expect(c.differingCells == 0 && c.peakL1 == 0 && c.impulseL1 == 0, "\(c.building) \(c.cellSize)")
        }
    }
}
