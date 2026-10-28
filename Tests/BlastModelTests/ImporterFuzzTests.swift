import Foundation
import Testing
import simd

@testable import BlastModel

/// The importers that read a user's files, run as BombCAD runs them, on a whole folder of inputs:
/// the replay half of Scripts/fuzz/fuzz-importers.py, which writes mutated copies of the fixtures
/// and samples into a folder and runs this test on it. It runs only when `BLASTMODEL_FUZZ_DIR`
/// names the folder; each input's outcome is a line of `BLASTMODEL_FUZZ_OUT`, and the input being
/// read is named in `BLASTMODEL_FUZZ_PROGRESS` first, so that the driver knows which one crashed
/// or hung.
enum ImporterFuzz {
    /// Reads `data` as a file of extension `kind` would be read, through what the app does next
    /// with it, and summarises the outcome in a line ("error: …" for a refusal).
    static func exercise(_ data: Data, kind: String) -> String {
        do {
            switch kind {
            case "dxf", "svg":
                let drawing = try kind == "svg" ? DXFDrawing(svg: data) : DXFDrawing(data: data)
                return plan(drawing)
            case "obj", "stl":
                let inspection = try ImportedMesh.inspect(data: data, fileExtension: kind)
                let finite = inspection.triangles.allSatisfy {
                    [$0.a, $0.b, $0.c].allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
                }
                var line =
                    "mesh \(inspection.triangles.count) triangles, valid \(inspection.validatedMesh != nil), "
                    + "issues \(inspection.issues.count), finite \(finite)"
                if let mesh = inspection.validatedMesh { line += ", " + placed(mesh) }
                return line
            case "asc":
                guard let text = String(data: data, encoding: .utf8) else { return "error: not UTF-8" }
                return terrain(try ElevationGrid(esriASCII: text))
            case "tif":
                // The directory's tags as the reader reads them, then the whole file as an
                // elevation grid: its strips or tiles decoded (LZW, Deflate or none, with their
                // predictors), placed, and cropped into a terrain.
                let tiff = try TIFFReader(data)
                var line = "tiff \(tiff.entries.count) tags"
                for tag in tiff.entries.keys.sorted() {
                    _ = tiff.integers(tag)
                    _ = tiff.doubles(tag)
                    _ = tiff.ascii(tag)
                }
                if let width = tiff.integer(256), let height = tiff.integer(257) {
                    line += ", \(width)x\(height)"
                }
                do {
                    line += ", " + terrain(try ElevationGrid(geoTIFF: data))
                } catch {
                    line += ", grid error: \(describe(error))"
                }
                return line
            case "lzw":
                let out = try TIFFReader.lzw(Array(data), expected: 1 << 20)
                return "lzw \(out.count) bytes"
            case "zlib":
                // A Deflate strip as the GeoTIFF reader inflates it: through Apple's Compression on
                // a Mac, through `Inflate` on Linux; on a Mac `Inflate` is run beside it, so that
                // the two decoders can be compared input by input.
                var line: String
                var inflated: [UInt8]?
                do {
                    inflated = try TIFFReader.inflate(Array(data), expected: 1 << 20)
                    line = "zlib \(inflated?.count ?? 0) bytes"
                } catch {
                    line = "zlib error: \(describe(error))"
                }
                #if canImport(Compression)
                    if data.count > 2 {
                        do {
                            let swift = try Inflate.decode(Array(data.dropFirst(2)), limit: 1 << 20)
                            line += ", inflate \(swift.count) bytes"
                            if let inflated { line += ", same \(swift == inflated)" }
                        } catch {
                            line += ", inflate error: \(error)"
                        }
                    }
                #endif
                return line
            case "osm", "geojson":
                let buildings =
                    try kind == "osm" ? MapBuilding.readOSM(data) : MapBuilding.readGeoJSON(data)
                return
                    "map \(buildings.count) buildings, \(buildings.reduce(0) { $0 + $1.rings.count }) rings"
            default:
                return "error: no reader for .\(kind)"
            }
        } catch {
            return "error: \(describe(error))"
        }
    }

    /// An error's message: the elevation readers' failures describe themselves.
    static func describe(_ error: any Error) -> String {
        (error as? ElevationGrid.Failure)?.description ?? error.localizedDescription
    }

    /// A grid as the terrain importer uses it: opened (a surface model's roofs taken off) and
    /// cropped into a scene's terrain.
    static func terrain(_ grid: ElevationGrid) -> String {
        let finite = grid.elevations.allSatisfy { $0.isNaN || $0.isFinite }
        var line =
            "grid \(grid.columns)x\(grid.rows), step \(grid.step), sw \(grid.southWest), finite \(finite)"
        if grid.columns * grid.rows <= 1_000_000 {
            let opened = grid.opened(radius: 1)
            line += ", opened \(opened.elevations.count)"
        }
        let spacing = Float(max(grid.spacingInMetres(near: grid.southWest).x, 1))
        if spacing.isFinite {
            let size = SIMD2<Float>(repeating: min(spacing * 20, 2_000))
            if let crop = try? grid.terrain(origin: grid.southWest, size: size, spacing: size.x / 20) {
                line += ", crop \(crop.report.nodes) nodes, lowest \(crop.report.lowest)"
            }
        }
        return line
    }

    /// A mesh that passed inspection, placed as the import sheet places it (metres, Z up, its
    /// corner at 1, 1, 0) and sampled into the preview's boxes on a grid about 40 cells across it.
    static func placed(_ mesh: ImportedMesh) -> String {
        do {
            var placed = try mesh.transformed(scale: 1, yUp: false, corner: SIMD3(1, 1, 0))
            var bounds = placed.bounds
            var span = simd_reduce_max(bounds.max - bounds.min)
            if !(span.isFinite && span > 0.01 && span < 10_000) {
                // As a user would, a model too large or too small for metres is scaled to 10 m.
                let scale = span.isFinite && span > 0 ? 10 / span : 1
                placed = try mesh.transformed(scale: scale, yUp: false, corner: SIMD3(1, 1, 0))
                bounds = placed.bounds
                span = simd_reduce_max(bounds.max - bounds.min)
            }
            let preview = try placed.preview(
                cellSize: max(span / 40, 1e-3), domain: bounds.max + SIMD3(repeating: 2))
            return "preview \(preview.boxes.count) boxes, \(preview.diagnostics.count) diagnostics"
        } catch {
            return "preview error: \(error.localizedDescription)"
        }
    }

    /// A drawing as the plan importer reads it: its segments, the analysis with the layers' roles
    /// guessed, and the building's elements.
    static func plan(_ drawing: DXFDrawing) -> String {
        let segments = drawing.segments()
        let finite = segments.allSatisfy {
            $0.a.x.isFinite && $0.a.y.isFinite && $0.b.x.isFinite && $0.b.y.isFinite
        }
        var options = FloorPlan.Options()
        options.metresPerUnit = drawing.metresPerUnit ?? 0.001
        options.roles = FloorPlan.guessedRoles(drawing.layers)
        let analysis = FloorPlan.analyse(drawing, options: options)
        var line =
            "plan \(drawing.entities.count) entities, \(drawing.blocks.count) blocks, \(segments.count) segments, "
            + "finite \(finite), \(analysis.walls.count) walls, \(analysis.angled.count) angled, "
            + "\(analysis.openings.count) openings"
        do {
            let elements = try FloorPlan.buildingElements(analysis, options: options)
            line += ", \(elements.count) elements"
        } catch {
            line += ", elements error: \(error.localizedDescription)"
        }
        return line
    }
}

@Suite("Importer fuzz replay")
struct ImporterFuzzReplayTests {
    static let folder = ProcessInfo.processInfo.environment["BLASTMODEL_FUZZ_DIR"]

    @Test("Every input in BLASTMODEL_FUZZ_DIR reads or is refused", .enabled(if: folder != nil))
    func replay() throws {
        let environment = ProcessInfo.processInfo.environment
        let folder = URL(fileURLWithPath: try #require(Self.folder))
        let progress = environment["BLASTMODEL_FUZZ_PROGRESS"].map(URL.init(fileURLWithPath:))
        let output = environment["BLASTMODEL_FUZZ_OUT"].map(URL.init(fileURLWithPath:))
        let skip = Int(environment["BLASTMODEL_FUZZ_SKIP"] ?? "") ?? 0
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        var log = ""
        for (n, name) in names.enumerated() where n >= skip {
            let url = folder.appending(path: name)
            if let progress { try Data("\(n) \(name)\n".utf8).write(to: progress) }
            let started = Date()
            let outcome = ImporterFuzz.exercise(
                try Data(contentsOf: url), kind: url.pathExtension.lowercased())
            let seconds = Date().timeIntervalSince(started)
            log +=
                "\(n)\t\(name)\t\(String(format: "%.3f", seconds))\t\(outcome.replacingOccurrences(of: "\n", with: " "))\n"
            // Each line written as it is known: the next input may crash the process.
            if let output {
                try appendLine(log, to: output)
                log = ""
            }
        }
    }

    private func appendLine(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
