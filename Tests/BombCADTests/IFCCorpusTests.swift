import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BombCAD

/// Imports one IFC file of a corpus, headless, as the app would: as rigid obstacles made an
/// envelope, and as a structure of shells and beams. Set `BOMBCAD_IFC_CORPUS_FILE` to the file and
/// `BOMBCAD_IFC_CORPUS_OUT` to a JSON Lines file its row is appended to; `Scripts/ifc-corpus.py`
/// runs it over a folder, one process per file, so that a crash is a row of its own.
@Suite("IFC corpus")
struct IFCCorpusTests {
    static let file = ProcessInfo.processInfo.environment["BOMBCAD_IFC_CORPUS_FILE"]
    static let output = ProcessInfo.processInfo.environment["BOMBCAD_IFC_CORPUS_OUT"]

    struct Row: Codable {
        var file: String
        var bytes: Int
        var schema: String?
        var stage = "read"
        var error: String?
        var seconds: [String: Double] = [:]
        // The decomposition.
        var inventory = 0
        var supported = 0
        var classes: [String: Int] = [:]
        var unsupportedClasses: [String: Int] = [:]
        var storeys = 0
        var buildings = 0
        var materialElements = 0
        var chosen = 0
        var chosenNote: String?
        // Conversion.
        var converted = 0
        var failures: [String] = []
        var missing = 0
        var notes: [String] = []
        var size: [Float] = []
        // As an envelope.
        var envelopeError: String?
        var envelopeSolids = 0
        var envelopeOpenings = 0
        var cellSize: Float = 0
        // As a structure.
        var structureError: String?
        var roles: [String: Int] = [:]
        var rigidReasons: [String: Int] = [:]
        var connections = 0
        var supports: [String] = []
        var assumptions: [String] = []
        var assumedMaterials = 0
        var yaw: Float = 0
        var shells = 0
        var beams = 0
        var smallestElement: Float?
        var smallestAt: String?
        // Under gravity, where asked (`BOMBCAD_IFC_CORPUS_GRAVITY`): after 0.3 s, damped.
        /// Members tied to nothing supported, and their share of the structure's volume (percent).
        var loose = 0
        var looseShare: Int?
        /// Elements whose meshes were repaired, the solids they gave, and pieces left out.
        var repaired = 0
        var repairedSolids = 0
        var repairLeftOut = 0
        var gravityDisplacement: Float?
        var gravityReaction: Float?
        var gravityEroded: Int?
        /// The reaction at clamped nodes, over the weight, which `gravityReaction` left out before
        /// it came from `GravityCheck` (kept for older rows); and the share of the weight on nodes
        /// that moved under 10 mm.
        var gravityClamped: Float?
        var gravityHeld: Float?
        /// Panes of glass, and the shell elements the mesh gives them.
        var panes = 0
        var paneElements = 0
        /// The mean speed (m/s) of the weight that moved over 10 mm, at 0.25 s and at the end: one
        /// falling keeps g over the damping rate, about 0.2 m/s; one deflecting comes to rest.
        var gravitySettling: [Float]?
        var gravityError: String?
    }

    /// The first words of a note, as a reason to count.
    static func reason(_ note: String) -> String {
        let text = note.replacingOccurrences(of: #"\d+(\.\d+)?"#, with: "#", options: .regularExpression)
        return String(text.split(separator: ":").first ?? Substring(text)).prefix(90).description
    }

    @Test(
        "One IFC file imports as an envelope and as a structure, or says why not", .enabled(if: file != nil))
    func importFile() async throws {
        let path = try #require(Self.file)
        let url = URL(fileURLWithPath: path)
        var row = Row(file: path, bytes: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let clock = ContinuousClock()
        func lap(_ name: String, _ start: ContinuousClock.Instant) {
            let d = clock.now - start
            row.seconds[name] = Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
        }
        defer {
            if let output = Self.output, let data = try? JSONEncoder().encode(row) {
                let line = data + Data("\n".utf8)
                if let handle = FileHandle(forWritingAtPath: output) {
                    handle.seekToEndOfFile()
                    handle.write(line)
                    try? handle.close()
                } else {
                    FileManager.default.createFile(atPath: output, contents: line)
                }
            }
        }
        do {
            let data = try Data(contentsOf: url)
            if let header = String(data: data.prefix(4000), encoding: .isoLatin1),
                let match = header.range(
                    of: #"FILE_SCHEMA\s*\(\s*\(\s*'([^']*)'"#, options: .regularExpression)
            {
                row.schema = String(header[match]).components(separatedBy: "'").dropFirst().first
            }
            row.stage = "prepare"
            var start = clock.now
            let prepared = try await IFCImporter.prepare(data)
            lap("prepare", start)
            row.inventory = prepared.inventory.count
            row.supported = prepared.defaultIDs.count
            for element in prepared.inventory {
                if element.supported {
                    row.classes[element.ifcClass, default: 0] += 1
                } else if !element.hasChildren {
                    row.unsupportedClasses[element.ifcClass, default: 0] += 1
                }
            }
            row.storeys = Set(prepared.inventory.compactMap(\.storeyID)).count
            row.buildings = Set(prepared.inventory.compactMap(\.buildingID)).count
            row.materialElements = prepared.materials.count
            // As the app asks: at most 1,024 elements, here the lowest storeys' first.
            var ids = prepared.defaultIDs
            // Storeys from the lowest, by their elevations in the IFC (else as listed, after them).
            let elevations = IFCStep.storeyElevations(data)
            var order: [String: Double] = [:]
            for (n, storey) in prepared.inventory.compactMap(\.storeyID).enumerated()
            where order[storey] == nil {
                order[storey] = elevations[storey] ?? 1e12 + Double(n)
            }
            func rank(_ element: ImportedMesh.BuildingSourceElement) -> Double {
                order[element.storeyID ?? ""] ?? .infinity
            }
            if ids.count > 1024 {
                let sorted = prepared.inventory.filter(\.supported).sorted { a, b in
                    rank(a) != rank(b) ? rank(a) < rank(b) : a.id < b.id
                }
                ids = Set(sorted.prefix(1024).map(\.id))
                row.chosenNote = "\(prepared.defaultIDs.count) supported; the first 1,024 by storey"
            }
            row.stage = "convert"
            start = clock.now
            var source: ImportedMesh?
            // Invalid element meshes are excluded and the rest converted again, as the app's
            // review does when the user excludes them; past the triangle limit, the lowest storey
            // alone, as the message advises.
            var narrowed = false
            for _ in 0..<6 {
                row.chosen = ids.count
                do {
                    source = try await IFCImporter.convert(prepared, includedIDs: ids)
                    break
                } catch let failures as IFCImporter.ElementFailures {
                    row.failures += failures.failures.map {
                        "\($0.name) [\($0.id)]: \(Self.reason($0.reason))"
                    }
                    ids.subtract(failures.failures.map(\.id))
                    guard !ids.isEmpty else { throw failures }
                } catch
                    where !narrowed && error.localizedDescription.contains("triangles. Choose fewer elements")
                {
                    narrowed = true
                    let storeys = Set(
                        prepared.inventory.filter { ids.contains($0.id) }.compactMap(\.storeyID))
                    let lowest = storeys.min { (order[$0] ?? .infinity) < (order[$1] ?? .infinity) } ?? ""
                    ids = Set(
                        prepared.inventory.filter { ids.contains($0.id) && ($0.storeyID ?? "") == lowest }
                            .map(\.id))
                    row.chosenNote =
                        (row.chosenNote.map { $0 + "; " } ?? "")
                        + "over the triangle limit: the first storey alone, \(ids.count) elements"
                    guard !ids.isEmpty else { throw error }
                }
            }
            lap("convert", start)
            let mesh = try #require(source, "conversion did not settle")
            let elements = mesh.buildingElements ?? []
            row.converted = elements.count
            row.missing = ids.count - elements.count
            row.notes = (mesh.buildingNotes ?? []).filter {
                !$0.hasPrefix("Inventory follows") && !$0.hasPrefix("Converted coordinates")
                    && !$0.hasPrefix("IFC converted to metres")
            }
            .map { String($0.prefix(600)) }
            row.size = [mesh.bounds.size.x, mesh.bounds.size.y, mesh.bounds.size.z]
            if let note = (mesh.buildingNotes ?? []).first(where: { $0.contains("were remade as the") }) {
                func number(_ pattern: String) -> Int {
                    note.range(of: pattern, options: .regularExpression).flatMap {
                        Int(note[$0].prefix { $0.isNumber })
                    } ?? 0
                }
                row.repaired = number(#"^\d+"#)
                row.repairedSolids =
                    (note.range(of: #"remade as the \d+"#, options: .regularExpression)).flatMap {
                        Int(note[$0].dropFirst(14))
                    } ?? 0
                row.repairLeftOut =
                    (note.range(of: #", \d+ pieces left out"#, options: .regularExpression)).flatMap {
                        Int(note[$0].dropFirst(2).prefix { $0.isNumber })
                    } ?? 0
            }

            // As an envelope: rigid, sampled, windows and doors cut as openings.
            row.stage = "envelope"
            start = clock.now
            let longest = mesh.bounds.size.max()
            row.cellSize = longest > 120 ? 1 : longest > 60 ? 0.5 : 0.25
            let domain = mesh.bounds.size + SIMD3(8, 8, 4)
            do {
                let preview = try mesh.transformed(scale: 1, yUp: false, corner: SIMD3(4, 4, 0))
                    .preview(cellSize: row.cellSize, domain: domain)
                let model = ImportedModel(
                    name: url.lastPathComponent, source: mesh, scale: 1, yUp: false, corner: SIMD3(4, 4, 0),
                    behavior: .rigid, preview: preview)
                let envelope = try model.buildingEnvelope()
                row.envelopeSolids = envelope.envelope.solids.count
                row.envelopeOpenings = envelope.envelope.openings.count
            } catch {
                row.envelopeError = String(error.localizedDescription.prefix(600))
            }
            lap("envelope", start)

            // As a structure of shells and beams.
            row.stage = "structure"
            start = clock.now
            do {
                let structure = try IFCStructure(elements: elements)
                for member in structure.members {
                    row.roles[member.role.rawValue, default: 0] += 1
                    if member.role == .rigid, let note = member.notes.first {
                        row.rigidReasons[Self.reason(note), default: 0] += 1
                    }
                }
                row.connections = structure.connections.count
                row.loose =
                    structure.members.filter { $0.notes.contains { $0.contains("will fall under gravity") } }
                    .count
                if let note = structure.assumptions.first(where: { $0.contains("will fall under gravity") }),
                    let match = note.range(of: #"(\d+)% of the"#, options: .regularExpression)
                {
                    row.looseShare = Int(note[match].prefix { $0.isNumber })
                }
                row.supports = structure.supports.map { String($0.prefix(200)) }
                row.assumptions = structure.assumptions.map { String($0.prefix(300)) }
                row.assumedMaterials = structure.report.assumedMaterials.count
                row.yaw = structure.yaw
                if ProcessInfo.processInfo.environment["BOMBCAD_IFC_CORPUS_BOTTOM"] != nil {
                    let solids = structure.model.solids
                    for member in structure.members.sorted(by: {
                        ($0.solid.map { solids[$0].min.z } ?? 99) < ($1.solid.map { solids[$0].min.z } ?? 99)
                    }).prefix(25) {
                        guard let i = member.solid else { continue }
                        print(
                            "BOTTOM \(member.name) [\(member.role.rawValue) \(member.ifcClass)] \(solids[i].min) \(solids[i].max)"
                        )
                    }
                    for line in structure.supports { print("BOTTOM support \(line.prefix(200))") }
                }
                if ProcessInfo.processInfo.environment["BOMBCAD_IFC_CORPUS_LOOSE"] != nil {
                    // Each loose member, and the nearest member to it: the gap along each axis.
                    let solids = structure.model.solids
                    for member in structure.members
                    where member.notes.contains(where: { $0.contains("will fall") }) {
                        guard let i = member.solid else { continue }
                        var best: (Float, String)?
                        for other in structure.members where other.solid != nil && other.solid != i {
                            let j = other.solid!
                            let gap = (0..<3).map {
                                max(
                                    0,
                                    max(
                                        solids[j].min[$0] - solids[i].max[$0],
                                        solids[i].min[$0] - solids[j].max[$0]))
                            }
                            let d = simd_length(SIMD3(gap[0], gap[1], gap[2]))
                            if best == nil || d < best!.0 {
                                best = (
                                    d,
                                    "\(other.name) [\(other.role.rawValue)] gap \(gap) \(other.notes.contains { $0.contains("will fall") } ? "loose" : "held")"
                                )
                            }
                        }
                        print(
                            "LOOSE \(member.name) [\(member.role.rawValue) \(member.ifcClass)] \(solids[i].min) \(solids[i].max) nearest \(best?.1 ?? "-")"
                        )
                    }
                }
                let shellMesh = try ShellMesh(model: structure.model)
                let paneSolids = Set(structure.members.filter { $0.role == .pane }.compactMap(\.solid))
                row.panes = paneSolids.count
                row.paneElements = shellMesh.elements.filter { paneSolids.contains($0.solid) }.count
                if ProcessInfo.processInfo.environment["BOMBCAD_IFC_CORPUS_PANES"] != nil {
                    for member in structure.members where member.role == .pane {
                        guard let solid = member.solid else { continue }
                        let box = structure.model.solids[solid]
                        let holding = structure.model.openings.filter { $0.holds(box) }.count
                        let crossing = structure.model.openings.filter { o in
                            (0..<3).allSatisfy { o.max[$0] > box.min[$0] && o.min[$0] < box.max[$0] }
                        }
                        let elements = shellMesh.elements.filter { $0.solid == solid }.count
                        print(
                            "PANES \(member.name) \(box) holding \(holding) crossing \(crossing) elements \(elements) notes \(member.notes.suffix(2))"
                        )
                    }
                }
                let owner = { (solid: Int) in
                    structure.members.first { $0.solid == solid }?.name ?? "solid \(solid)"
                }
                row.shells = shellMesh.elements.count
                row.beams = shellMesh.beams.count
                row.smallestElement =
                    (shellMesh.elements.map { $0.size.min() } + shellMesh.beams.map(\.length)).min()
                if let e = shellMesh.elements.min(by: { $0.size.min() < $1.size.min() }),
                    e.size.min() == row.smallestElement
                {
                    row.smallestAt =
                        "shell of \(owner(e.solid)) \(e.size) at \(shellMesh.positions[Int(e.nodes[0])]), its box \(structure.model.solids[e.solid])"
                } else if let b = shellMesh.beams.min(by: { $0.length < $1.length }) {
                    row.smallestAt =
                        "beam of \(owner(b.solid)) \(b.length) at \(shellMesh.positions[Int(b.nodes[0])]), its box \(structure.model.solids[b.solid])"
                }
                if ProcessInfo.processInfo.environment["BOMBCAD_IFC_CORPUS_GRAVITY"] != nil {
                    row.stage = "gravity"
                    let gravity = clock.now
                    do {
                        let device = try #require(MTLCreateSystemDefaultDevice())
                        var model = structure.model
                        if ProcessInfo.processInfo.environment["BOMBCAD_IFC_CORPUS_NOTIES"] != nil {
                            model.tiesTouching = nil
                        }
                        var inspected: ShellSolver?
                        let check = try GravityCheck.run(model, device: device) { inspected = $0 }
                        let solver = try #require(inspected)
                        let mass = check.weight / solver.gravity
                        row.gravitySettling = [check.settling.early, check.settling.late]
                        row.gravityDisplacement = check.peak
                        row.gravityEroded = check.eroded
                        // The clamps' reaction is in `carried`.
                        row.gravityReaction = check.carried
                        row.gravityHeld = check.still
                        if ProcessInfo.processInfo.environment["BOMBCAD_IFC_CORPUS_DETAIL"] != nil {
                            var clamped = 0
                            solver.mutateNodes { clamped = $0.filter(\.isClamped).count }
                            let anchors = solver.anchorSummary()
                            print(
                                "DETAIL mass \(mass) clamped nodes \(clamped) fixedBase \(structure.model.fixedBase) anchors \(anchors?.nodes ?? 0) separated \(anchors?.separated ?? 0) reaction \(anchors?.reaction ?? .zero) maxSettlement \(anchors?.maxSettlement ?? 0)"
                            )
                            for (n, support) in structure.model.supports.enumerated() {
                                let law = structure.model.supportAnchorages[n]
                                print(
                                    "DETAIL support \(n) \(support.min) \(support.max) footing \(law?.footing != nil) bearing \(solver.supportBearingArea(at: n))"
                                )
                            }
                            for f in solver.footingSummaries() {
                                print(
                                    "DETAIL footing size \(f.size) moved \(f.displacement) soil \(f.soilForce) joint \(f.jointForce)"
                                )
                            }
                            var worst: [(Float, String)] = []
                            for member in structure.members {
                                guard let solid = member.solid else { continue }
                                let box = structure.model.solids[solid]
                                var peak: Float = 0
                                for n in 0..<solver.nodeCount {
                                    let p = solver.referencePositions[n]
                                    if (0..<3).allSatisfy({
                                        p[$0] >= box.min[$0] - 0.01 && p[$0] <= box.max[$0] + 0.01
                                    }) {
                                        peak = max(peak, simd_length(solver.node(n).displacement))
                                    }
                                }
                                worst.append(
                                    (peak, "\(member.name) [\(member.role.rawValue)] \(box.min) \(box.max)"))
                            }
                            for (peak, text) in worst.sorted(by: { $0.0 > $1.0 }).prefix(15) {
                                print("DETAIL moved \(peak) \(text)")
                            }
                            print(
                                "DETAIL members moving > 10 mm: \(worst.filter { $0.0 > 0.01 }.count) of \(worst.count)"
                            )
                            let tied = Set(solver.mesh.ties.flatMap { [$0.slave, $0.master] })
                            var eroded: [Int: (count: Int, tied: Int)] = [:]
                            for (e, element) in solver.mesh.elements.enumerated()
                            where solver.flag(e) == .eroded {
                                let touches = (0..<4).contains { tied.contains(element.nodes[$0]) }
                                eroded[element.solid, default: (0, 0)].count += 1
                                if touches { eroded[element.solid, default: (0, 0)].tied += 1 }
                            }
                            for (solid, n) in eroded.sorted(by: { $0.value.count > $1.value.count }).prefix(
                                15)
                            {
                                let name =
                                    structure.members.first { $0.solid == solid }?.name ?? "solid \(solid)"
                                print(
                                    "DETAIL eroded \(n.count) (\(n.tied) at a tie) in \(name) \(structure.model.solids[solid])"
                                )
                            }
                            print(
                                "DETAIL contact ties \(solver.mesh.contactTies.count), tied nodes \(solver.mesh.ties.count)"
                            )
                        }
                    } catch {
                        row.gravityError = String(error.localizedDescription.prefix(300))
                    }
                    lap("gravity", gravity)
                }
            } catch {
                row.structureError = String(error.localizedDescription.prefix(600))
            }
            lap("structure", start)
            row.stage = "done"
        } catch {
            row.error = String(error.localizedDescription.prefix(1200))
        }
    }
}
