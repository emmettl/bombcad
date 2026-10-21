import Foundation
import Testing
import simd

@testable import BlastModel

/// Files that crashed, hung or misread an importer, found by Scripts/fuzz/fuzz-importers.py and by
/// reading the readers for what it pointed at (docs/linux.md#sanitizers-and-importer-fuzzing-20-october-2026 has the runs). Each is the
/// smallest file that showed it; before its fix, each trapped, ran without end or read as nonsense.
@Suite("Importers refuse or survive corrupt files")
struct ImporterRobustnessTests {
    /// A DXF in millimetres with `entities` in its model space and `blocks` in its BLOCKS section.
    static func dxf(_ entities: String, blocks: String = "") -> Data {
        var text = "0\nSECTION\n2\nHEADER\n9\n$INSUNITS\n70\n4\n0\nENDSEC\n"
        if !blocks.isEmpty { text += "0\nSECTION\n2\nBLOCKS\n" + blocks + "0\nENDSEC\n" }
        text += "0\nSECTION\n2\nENTITIES\n" + entities + "0\nENDSEC\n0\nEOF\n"
        return Data(text.utf8)
    }

    static func arc(start: String, end: String, radius: String = "500") -> String {
        "0\nARC\n8\nWALLS\n10\n0\n20\n0\n40\n\(radius)\n50\n\(start)\n51\n\(end)\n"
    }

    static let line = "0\nLINE\n8\nWALLS\n10\n0\n20\n0\n11\n1000\n21\n0\n"

    @Test(
        "An arc's enormous angle draws a bounded arc, not an endless loop or a trap",
        arguments: [("0", "1e300"), ("1e300", "0"), ("1e15", "0"), ("0", "1e10")])
    func arcAngles(start: String, end: String) throws {
        let drawing = try DXFDrawing(data: Self.dxf(Self.arc(start: start, end: end)))
        // Two turns at most, in pieces of 15°. Before, an end of 1e300 trapped converting the
        // piece count to an Int, a start of 1e300 or 1e15 added turns for ever, and an end of
        // 1e10 made 700 million pieces.
        let segments = drawing.segments()
        #expect(segments.count <= 2 * 24 * 2 + 1)
        #expect(segments.allSatisfy { simd_length($0.a) <= 500.000_001 && simd_length($0.b) <= 500.000_001 })
    }

    @Test("An arc of ordinary angles is drawn as before")
    func ordinaryArc() throws {
        let drawing = try DXFDrawing(data: Self.dxf(Self.arc(start: "350", end: "10")))
        let segments = drawing.segments()
        #expect(segments.count == 2)
        #expect(
            simd_distance(segments[0].a, SIMD2(500 * cos(350 * .pi / 180), 500 * sin(350 * .pi / 180))) < 1e-9
        )
        #expect(
            simd_distance(segments[1].b, SIMD2(500 * cos(10 * .pi / 180), 500 * sin(10 * .pi / 180))) < 1e-9)
    }

    @Test(
        "A DXF with a NaN or infinite number in an entity is refused",
        arguments: [
            // An arc's NaN angle and a polyline's NaN bulge trapped converting a piece count to an
            // Int; an infinite bulge drew a circle some 10¹⁸ mm across; an infinite end raised a
            // wall at infinity, and a NaN one dropped the line without a word.
            ImporterRobustnessTests.arc(start: "0", end: "nan"),
            ImporterRobustnessTests.arc(start: "nan", end: "90"),
            ImporterRobustnessTests.arc(start: "0", end: "90", radius: "inf"),
            "0\nLWPOLYLINE\n8\nWALLS\n70\n0\n10\n0\n20\n0\n42\nnan\n10\n1000\n20\n0\n",
            "0\nLWPOLYLINE\n8\nWALLS\n70\n0\n10\n0\n20\n0\n42\ninf\n10\n1000\n20\n0\n",
            "0\nLINE\n8\nWALLS\n10\n0\n20\n0\n11\n1e309\n21\n0\n",
            "0\nLINE\n8\nWALLS\n10\nnan\n20\n0\n11\n1000\n21\n0\n",
            "0\nCIRCLE\n8\nWALLS\n10\n0\n20\n0\n40\n-inf\n",
        ])
    func nonFinite(entity: String) {
        #expect(throws: DXFDrawing.ReadError.self) { try DXFDrawing(data: Self.dxf(entity)) }
    }

    @Test("A drawing made in code with a NaN arc or bulge still makes its segments without trapping")
    func nonFiniteInCode() {
        let drawing = DXFDrawing(
            layers: ["WALLS"],
            entities: [
                .init(layer: "WALLS", shape: .arc(center: .zero, radius: 1, start: 0, end: .nan)),
                .init(layer: "WALLS", shape: .arc(center: .zero, radius: 1, start: .nan, end: 90)),
                .init(
                    layer: "WALLS", shape: .polyline([.zero, SIMD2(1, 0)], bulges: [.nan, 0], closed: false)),
            ])
        // The arcs draw nothing; the bulge is drawn straight.
        #expect(
            drawing.segments() == [.init(layer: "WALLS", a: .zero, b: SIMD2(1, 0), block: nil, insert: nil)])
    }

    @Test("A bulge between a vertex and its repeat is drawn straight, not trapped on")
    func repeatedVertex() throws {
        // The bulge made a NaN centre (a chord of zero normalised), and so a NaN piece count.
        let drawing = try DXFDrawing(
            data: Self.dxf(
                "0\nLWPOLYLINE\n8\nWALLS\n70\n0\n10\n0\n20\n0\n42\n0.5\n10\n0\n20\n0\n10\n1000\n20\n0\n"))
        let segments = drawing.segments()
        #expect(segments.count == 1)
        #expect(segments.first.map { $0.a == SIMD2(0, 0) && $0.b == SIMD2(1000, 0) } == true)
    }

    @Test("A block that inserts itself a dozen times is refused, not expanded to 12⁸ copies")
    func selfInsertingBlock() {
        let inserts = (0..<12).map { "0\nINSERT\n8\n0\n2\nA\n10\n\($0)\n20\n0\n" }.joined()
        let data = Self.dxf(
            "0\nINSERT\n8\nWALLS\n2\nA\n10\n0\n20\n0\n",
            blocks: "0\nBLOCK\n2\nA\n10\n0\n20\n0\n" + Self.line + inserts + "0\nENDBLK\n")
        #expect(throws: DXFDrawing.ReadError.self) { try DXFDrawing(data: data) }
    }

    @Test("Blocks nested a few levels, inserted a few times each, still read and expand")
    func nestedBlocks() throws {
        // Three levels of four inserts each over a block of one line: 64 lines.
        let blocks = (0..<4).map { level in
            "0\nBLOCK\n2\nB\(level)\n10\n0\n20\n0\n"
                + (level == 3
                    ? Self.line
                    : (0..<4).map { "0\nINSERT\n8\n0\n2\nB\(level + 1)\n10\n\($0 * 2000)\n20\n0\n" }.joined())
                + "0\nENDBLK\n"
        }.joined()
        let drawing = try DXFDrawing(
            data: Self.dxf("0\nINSERT\n8\nWALLS\n2\nB0\n10\n0\n20\n0\n", blocks: blocks))
        #expect(drawing.expandedPieces() == 64)
        #expect(drawing.segments().count == 64)
    }

    @Test("A DXF of many layers lists them in order, once each, without quadratic time")
    func manyLayers() throws {
        // 50,000 lines on 25,000 layers: before, each entity searched the list of layers.
        let entities = (0..<50_000).map {
            "0\nLINE\n8\nL\($0 % 25_000)\n10\n\($0)\n20\n0\n11\n\($0)\n21\n1000\n"
        }
        let drawing = try DXFDrawing(data: Self.dxf(entities.joined()))
        #expect(drawing.layers.count == 25_000)
        #expect(drawing.layers.first == "L0" && drawing.layers.last == "L24999")
    }

    static func svg(_ body: String) -> Data {
        Data(
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="10m" height="10m" viewBox="0 0 10000 10000">\
            <g id="Walls">\(body)</g></svg>
            """.utf8)
    }

    @Test(
        "An SVG arc whose radii or rotation overflow is drawn straight to its end, not trapped on",
        arguments: ["M0 0 A1e200 1e200 0 0 1 10 10", "M0 0 A5 5 1e308 0 1 10 10"])
    func svgArcOverflow(path: String) throws {
        let drawing = try DXFDrawing(svg: Self.svg("<path d=\"\(path)\"/>"))
        #expect(drawing.entities.count == 1)
        #expect(drawing.segments().count == 1)
    }

    @Test("An SVG with a coordinate past a Double's range is refused, not trapped on")
    func svgInfinite() {
        // An arc to 1e309 (infinity) trapped converting a NaN piece count to an Int.
        #expect(throws: DXFDrawing.ReadError.self) {
            try DXFDrawing(svg: Self.svg("<path d=\"M0 0 A1 1 0 0 1 1e309 0\"/>"))
        }
        #expect(throws: DXFDrawing.ReadError.self) {
            try DXFDrawing(
                svg: Self.svg("<line transform=\"scale(1e308)\" x1=\"0\" y1=\"0\" x2=\"10\" y2=\"0\"/>"))
        }
    }

    @Test("An SVG whose size overflows gives no unit from it, not an infinite one")
    func svgUnitOverflow() throws {
        // A width of 1e309 mm (infinity) over its view box made a unit of infinitely many metres;
        // the height's unit is taken instead.
        let data = Data(
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="1e309mm" height="10mm" viewBox="0 0 1e-320 10">\
            <g id="Walls"><line x1="0" y1="0" x2="1" y2="1"/></g></svg>
            """.utf8)
        let unit = try #require(try DXFDrawing(svg: data).metresPerUnit)
        #expect(abs(unit - 0.001) < 1e-15)
    }

    @Test("An SVG arc of ordinary radii is still flattened into pieces")
    func svgArc() throws {
        let drawing = try DXFDrawing(svg: Self.svg("<path d=\"M0 0 A5 5 0 0 1 10 0\"/>"))
        guard case .polyline(let points, _, _) = drawing.entities.first?.shape else {
            Issue.record("no polyline")
            return
        }
        // A half turn in pieces of at most 15°: 12 or so, not one straight piece.
        #expect(points.count > 10)
    }

    @Test("An SVG whose <use> elements copy a symbol past the limit is refused, and stops reading")
    func svgUseAmplification() throws {
        // 114 KB of SVG came to 24 million points, 2,000 squares copied 3,000 times, and ran for
        // minutes. With a limit of 100,000 points it is refused after 13 copies; under it, 10
        // copies read.
        let symbol = String(repeating: "<path d=\"M0 0 L1 0 L1 1 L0 1 Z\"/>", count: 2_000)
        func file(uses: Int) -> Data {
            Data(
                """
                <svg xmlns="http://www.w3.org/2000/svg" width="10m" height="10m" viewBox="0 0 10000 10000">\
                <defs><symbol id="s">\(symbol)</symbol></defs>\
                <g id="Walls">\(String(repeating: "<use href=\"#s\"/>", count: uses))</g></svg>
                """.utf8)
        }
        #expect(throws: DXFDrawing.ReadError.self) {
            try DXFDrawing(svg: file(uses: 3_000), pieceLimit: 100_000)
        }
        let drawing = try DXFDrawing(svg: file(uses: 10), pieceLimit: 100_000)
        #expect(drawing.blocks.count == 10 && drawing.expandedPieces() == 80_000)
    }

    @Test("An SVG or OSM file in invalid UTF-8 is refused before Linux's XMLParser traps on it")
    func invalidUTF8() throws {
        // An element name of 0xF4 then "i": libxml2 passes it on, and FoundationXML trapped (SIGILL).
        let name = Data("<svg><p".utf8) + Data([0xF4]) + Data("i/></svg>".utf8)
        #expect(throws: DXFDrawing.ReadError.self) { try DXFDrawing(svg: name) }
        let osm = Data("<osm><n".utf8) + Data([0xF4]) + Data("i/></osm>".utf8)
        #expect(throws: MapBuilding.Failure.self) { try MapBuilding.readOSM(osm) }
        // So did a comment in Latin-1 with no encoding declared, as a European exporter may write.
        let comment = Data("<svg><!-- caf".utf8) + Data([0xE9]) + Data(" --><g id=\"Walls\"/></svg>".utf8)
        #expect(throws: DXFDrawing.ReadError.self) { try DXFDrawing(svg: comment) }
        // An encoding libxml2 does not know passes the bytes on as they are, and trapped too.
        let unknown =
            Data("<?xml version=\"1.0\" encoding=\"UTF%8\"?><svg><g la".utf8) + Data([0xE2])
            + Data("el=\"x\"/></svg>".utf8)
        #expect(throws: DXFDrawing.ReadError.self) { try DXFDrawing(svg: unknown) }
        // A file that names its encoding is converted by libxml2, and reads.
        let latin =
            Data("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><svg><g id=\"Mur ".utf8) + Data([0xE9])
            + Data("\"><line x1=\"0\" y1=\"0\" x2=\"1000\" y2=\"0\"/></g></svg>".utf8)
        let drawing = try DXFDrawing(svg: latin)
        #expect(drawing.layers == ["Mur é"])
    }

    /// An SVG of a line inside groups nested `depth` deep, read on a thread with a stack of 512 KB
    /// (a secondary thread's on macOS); the read's outcome, or nil if it threw.
    static func readNested(depth: Int) -> Int? {
        let data = svg(
            String(repeating: "<g>", count: depth) + "<line x1=\"0\" y1=\"0\" x2=\"1000\" y2=\"0\"/>"
                + String(repeating: "</g>", count: depth))
        final class Box: @unchecked Sendable {
            var segments: Int?
            let done = DispatchSemaphore(value: 0)
        }
        let box = Box()
        let thread = Thread {
            box.segments = (try? DXFDrawing(svg: data))?.segments().count
            box.done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        box.done.wait()
        return box.segments
    }

    @Test("An SVG nested deeper than its limit is refused; within it, it reads on a small stack")
    func svgNesting() {
        // 5,000 groups deep overflowed the stack walking the tree (signal 11).
        #expect(Self.readNested(depth: 5_000) == nil)
        // The svg element, the layer's group and the line make three levels more.
        #expect(Self.readNested(depth: SVGTree.depthLimit - 3) == 1)
        #expect(Self.readNested(depth: SVGTree.depthLimit - 2) == nil)
    }
}
