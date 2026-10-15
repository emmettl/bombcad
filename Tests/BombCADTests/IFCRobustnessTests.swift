import BlastCore
import Foundation
import Testing
import simd

@testable import BombCAD

/// What the IFC corpus run (`Scripts/ifc-corpus.py`) found breaking, each on a small IFC written
/// here: products outside the spatial structure, elements whose geometry is in their parts, files
/// the converter cannot read, and files with nothing supported.
@Suite(
    "IFC import robustness",
    .enabled(if: IFCImporter.converterURL != nil, "Prepare the pinned IFC converter before integration tests")
)
struct IFCRobustnessTests {
    /// A GlobalId of digits.
    static func id(_ n: Int) -> String { String(format: "%022d", n) }

    /// A minimal IFC4 file: a project in metres with a site, building and storey, and `body`'s
    /// entities (from #100 on); `contained` are put in the storey.
    static func ifc(_ body: String, contained: [Int] = [], projects: Int = 1) -> Data {
        var lines = [
            "#1=IFCPROJECT('\(id(1))',$,'Project',$,$,$,$,(#20),#7);",
            "#7=IFCUNITASSIGNMENT((#8));",
            "#8=IFCSIUNIT(*,.LENGTHUNIT.,$,.METRE.);",
            "#10=IFCCARTESIANPOINT((0.,0.,0.));",
            "#11=IFCAXIS2PLACEMENT3D(#10,$,$);",
            "#12=IFCDIRECTION((0.,0.,1.));",
            "#20=IFCGEOMETRICREPRESENTATIONCONTEXT($,'Model',3,1.E-05,#11,$);",
            "#21=IFCGEOMETRICREPRESENTATIONSUBCONTEXT('Body','Model',*,*,*,*,#20,$,.MODEL_VIEW.,$);",
            "#30=IFCLOCALPLACEMENT($,#11);",
            "#31=IFCSITE('\(id(31))',$,'Site',$,$,#30,$,$,.ELEMENT.,$,$,$,$,$);",
            "#32=IFCBUILDING('\(id(32))',$,'Building',$,$,#30,$,$,.ELEMENT.,$,$,$);",
            "#33=IFCBUILDINGSTOREY('\(id(33))',$,'Ground',$,$,#30,$,$,.ELEMENT.,0.);",
            "#34=IFCRELAGGREGATES('\(id(34))',$,$,$,#1,(#31));",
            "#35=IFCRELAGGREGATES('\(id(35))',$,$,$,#31,(#32));",
            "#36=IFCRELAGGREGATES('\(id(36))',$,$,$,#32,(#33));",
        ]
        if projects > 1 { lines.append("#2=IFCPROJECT('\(id(2))',$,'Other',$,$,$,$,(#20),#7);") }
        if !contained.isEmpty {
            lines.append(
                "#37=IFCRELCONTAINEDINSPATIALSTRUCTURE('\(id(37))',$,$,$,(\(contained.map { "#\($0)" }.joined(separator: ","))),#33);"
            )
        }
        let text =
            "ISO-10303-21;\nHEADER;\nFILE_DESCRIPTION(('ViewDefinition [ReferenceView]'),'2;1');\n"
            + "FILE_NAME('test.ifc','2026-10-12T00:00:00',(''),(''),'','','');\nFILE_SCHEMA(('IFC4'));\nENDSEC;\nDATA;\n"
            + lines.joined(separator: "\n") + "\n" + body + "\nENDSEC;\nEND-ISO-10303-21;\n"
        return Data(text.utf8)
    }

    /// The entities of a box from `corner`, `size` metres, as a representation at #n…#n+8 (its
    /// IfcProductDefinitionShape is #n+8 and its placement #n+2).
    static func box(_ n: Int, _ corner: SIMD3<Double>, _ size: SIMD3<Double>) -> String {
        """
        #\(n)=IFCCARTESIANPOINT((\(corner.x),\(corner.y),\(corner.z)));
        #\(n + 1)=IFCAXIS2PLACEMENT3D(#\(n),$,$);
        #\(n + 2)=IFCLOCALPLACEMENT($,#\(n + 1));
        #\(n + 3)=IFCCARTESIANPOINT((\(size.x / 2),\(size.y / 2)));
        #\(n + 4)=IFCAXIS2PLACEMENT2D(#\(n + 3),$);
        #\(n + 5)=IFCRECTANGLEPROFILEDEF(.AREA.,$,#\(n + 4),\(size.x),\(size.y));
        #\(n + 6)=IFCEXTRUDEDAREASOLID(#\(n + 5),#11,#12,\(size.z));
        #\(n + 7)=IFCSHAPEREPRESENTATION(#21,'Body','SweptSolid',(#\(n + 6)));
        #\(n + 8)=IFCPRODUCTDEFINITIONSHAPE($,$,(#\(n + 7)));
        """
    }

    @Test("A wall in no storey is found in the file itself, imported, and said to be")
    func uncontained() async throws {
        let data = Self.ifc(
            Self.box(100, [0, 0, 0], [4, 0.2, 3])
                + "\n#109=IFCWALL('\(Self.id(109))',$,'Loose wall',$,$,#102,#108,$,$);\n"
                + Self.box(110, [0, 2, 0], [4, 0.2, 3])
                + "\n#119=IFCWALL('\(Self.id(119))',$,'Kept wall',$,$,#112,#118,$,$);",
            contained: [119])
        let prepared = try await IFCImporter.prepare(data)
        let loose = try #require(prepared.inventory.first { $0.id == Self.id(109) })
        #expect(loose.uncontained == true && loose.supported && loose.storey == nil)
        #expect(prepared.inventory.first { $0.id == Self.id(119) }?.storey == "Ground")
        let source = try await IFCImporter.convert(prepared, includedIDs: prepared.defaultIDs)
        #expect(source.buildingElements?.count == 2)
        #expect(
            source.buildingNotes?.contains { $0.contains("in no storey") && $0.contains("Loose wall") }
                == true)
    }

    @Test(
        "A wall built of parts imports its parts, as elements of their own and as one member of a structure")
    func parts() async throws {
        // A wall entity with no geometry, aggregating two blocks that carry it.
        let data = Self.ifc(
            "#100=IFCWALL('\(Self.id(100))',$,'Block wall',$,$,#30,$,$,$);\n"
                + Self.box(110, [0, 0, 0], [2, 0.2, 3])
                + "\n#119=IFCBUILDINGELEMENTPART('\(Self.id(119))',$,'Block',$,$,#112,#118,$,$);\n"
                + Self.box(120, [2, 0, 0], [2, 0.2, 3])
                + "\n#129=IFCBUILDINGELEMENTPART('\(Self.id(129))',$,'Block',$,$,#122,#128,$,$);\n"
                + "#130=IFCRELAGGREGATES('\(Self.id(130))',$,$,$,#100,(#119,#129));",
            contained: [100])
        let prepared = try await IFCImporter.prepare(data)
        #expect(prepared.inventory.filter { $0.parentID == Self.id(100) && $0.supported }.count == 2)
        let source = try await IFCImporter.convert(prepared, includedIDs: prepared.defaultIDs)
        let elements = try #require(source.buildingElements)
        #expect(
            elements.count == 2
                && elements.allSatisfy { $0.assembly?.id == Self.id(100) && $0.storey == "Ground" })
        // The wall itself has no geometry, and is not reported missing: its parts carry it.
        #expect(source.buildingNotes?.contains { $0.contains("without converted geometry") } == false)
        #expect(source.buildingNotes?.contains { $0.contains("2 parts") } == true)
        let structure = try IFCStructure(elements: elements)
        #expect(structure.members.count == 1)
        let wall = try #require(structure.members.first)
        #expect(wall.name == "Block wall" && wall.role == .shell && wall.parts?.count == 2)
        #expect(abs(structure.model.solids[wall.solid!].size.x - 4) < 0.01)
    }

    @Test("A file the converter cannot read, or with nothing supported, says what it holds")
    func unreadable() async throws {
        do {
            _ = try await IFCImporter.prepare(Self.ifc("", projects: 2))
            Issue.record("Two projects were accepted")
        } catch {
            #expect(error.localizedDescription.contains("could not read the file's structure"))
            #expect(error.localizedDescription.contains("IfcProject"))
        }
        let proxy = Self.ifc(
            Self.box(100, [0, 0, 0], [1, 1, 1])
                + "\n#109=IFCBUILDINGELEMENTPROXY('\(Self.id(109))',$,'Thing',$,$,#102,#108,$,$);",
            contained: [109])
        do {
            _ = try await IFCImporter.prepare(proxy)
            Issue.record("A file with only a proxy was accepted")
        } catch {
            #expect(error.localizedDescription.contains("it holds 1 IfcBuildingElementProxy"))
        }
    }

    @Test("A wall whose representation is two touching solids is taken apart into them, and imported")
    func repaired() async throws {
        // One wall, its body two boxes of one representation side by side: the converter welds
        // them into one mesh whose shared face leaves edges used four times.
        let data = Self.ifc(
            Self.box(100, [0, 0, 0], [2, 0.2, 3]) + "\n" + Self.box(110, [2, 0, 0], [2, 0.2, 3]) + """

                #119=IFCEXTRUDEDAREASOLID(#115,#111,#12,3.);
                #120=IFCSHAPEREPRESENTATION(#21,'Body','SweptSolid',(#106,#119));
                #121=IFCPRODUCTDEFINITIONSHAPE($,$,(#120));
                #122=IFCWALL('\(Self.id(122))',$,'Layered wall',$,$,#30,#121,$,$);
                """,
            contained: [122])
        let prepared = try await IFCImporter.prepare(data)
        let source = try await IFCImporter.convert(prepared, includedIDs: prepared.defaultIDs)
        let elements = try #require(source.buildingElements)
        // The face the two shared is removed: one closed solid, the whole wall, a piece of it.
        #expect(
            !elements.isEmpty
                && elements.allSatisfy { $0.assembly?.id == Self.id(122) && $0.ifcClass == "IfcWall" })
        #expect(!elements.contains { $0.globalID == Self.id(122) })
        let low = elements.map(\.mesh.bounds.min).reduce(SIMD3<Float>(repeating: .infinity), simd_min)
        let high = elements.map(\.mesh.bounds.max).reduce(SIMD3<Float>(repeating: -.infinity), simd_max)
        #expect(abs(high.x - low.x - 4) < 1e-3 && abs(high.z - low.z - 3) < 1e-3)
        #expect(source.buildingNotes?.contains { $0.contains("were remade as the") } == true)
        #expect(source.buildingNotes?.contains { $0.contains("without converted geometry") } == false)
        // As a structure, one wall.
        let structure = try IFCStructure(elements: elements)
        #expect(structure.members.count == 1 && structure.members[0].name == "Layered wall")
        #expect(structure.members[0].role == .shell)
    }

    @Test("Two profiles sharing their fillet arcs are each given arcs of their own before conversion")
    func sharedSegments() throws {
        // Two W460 sections drawn as outlines, two of their four fillet arcs (reversed, as Revit
        // writes them) the same entities in both. The converter then leaves the second's ends open:
        // in the Clinic's structural model, 183 of its 277 wide-flange beams.
        let (b, d, tf, tw, r) = (0.0765, 0.2275, 0.0133, 0.004, 0.0177)
        let (y1, x1) = (d - tf, tw + r)
        let y2 = y1 - r
        enum Segment {
            case line((Double, Double), (Double, Double))
            case arc((Double, Double), Double, Double)
        }
        let outline: [Segment] = [
            .line((-b, -y1), (-b, -d)), .line((-b, -d), (b, -d)), .line((b, -d), (b, -y1)),
            .line((b, -y1), (x1, -y1)),
            .arc((x1, -y2), 180, 270), .line((tw, -y2), (tw, y2)), .arc((x1, y2), 90, 180),
            .line((x1, y1), (b, y1)),
            .line((b, y1), (b, d)), .line((b, d), (-b, d)), .line((-b, d), (-b, y1)),
            .line((-b, y1), (-x1, y1)),
            .arc((-x1, y2), 0, 90), .line((-tw, y2), (-tw, -y2)), .arc((-x1, -y2), 270, 0),
            .line((-x1, -y1), (-b, -y1)),
        ]
        var lines = ["#200=IFCDIRECTION((1.,0.));"]
        var next = 1000
        func add(_ text: String) -> Int {
            lines.append("#\(next)=\(text)")
            next += 1
            return next - 1
        }
        func segment(_ part: Segment) -> Int {
            switch part {
            case .line(let p, let q):
                let a = add("IFCCARTESIANPOINT((\(p.0),\(p.1)));")
                let b = add("IFCCARTESIANPOINT((\(q.0),\(q.1)));")
                return add(
                    "IFCCOMPOSITECURVESEGMENT(.CONTINUOUS.,.T.,#\(add("IFCPOLYLINE((#\(a),#\(b)));")));")
            case .arc(let centre, let from, let to):
                let point = add("IFCCARTESIANPOINT((\(centre.0),\(centre.1)));")
                let circle = add("IFCCIRCLE(#\(add("IFCAXIS2PLACEMENT2D(#\(point),#200);")),\(r));")
                let trimmed = add(
                    "IFCTRIMMEDCURVE(#\(circle),(IFCPARAMETERVALUE(\(from))),(IFCPARAMETERVALUE(\(to))),.T.,.PARAMETER.);"
                )
                return add("IFCCOMPOSITECURVESEGMENT(.CONTINUOUS.,.F.,#\(trimmed));")
            }
        }
        let shared = [4: segment(outline[4]), 6: segment(outline[6])]
        for n in 0..<2 {
            let segments = outline.indices.map { shared[$0] ?? segment(outline[$0]) }
            let curve = add("IFCCOMPOSITECURVE((\(segments.map { "#\($0)" }.joined(separator: ","))),.F.);")
            let profile = add("IFCARBITRARYCLOSEDPROFILEDEF(.AREA.,$,#\(curve));")
            let k = 500 + 100 * n
            lines += [
                "#\(k)=IFCCARTESIANPOINT((0.,\(2 * n).,0.));", "#\(k + 1)=IFCDIRECTION((0.,1.,0.));",
                "#\(k + 2)=IFCDIRECTION((1.,0.,0.));",
                "#\(k + 3)=IFCAXIS2PLACEMENT3D(#\(k),#\(k + 1),#\(k + 2));",
                "#\(k + 4)=IFCEXTRUDEDAREASOLID(#\(profile),#\(k + 3),#12,7.);",
                "#\(k + 5)=IFCSHAPEREPRESENTATION(#21,'Body','SweptSolid',(#\(k + 4)));",
                "#\(k + 6)=IFCPRODUCTDEFINITIONSHAPE($,$,(#\(k + 5)));",
                "#\(k + 7)=IFCBEAM('\(Self.id(k + 7))',$,'Beam \(n + 1)',$,$,#30,#\(k + 6),$,$);",
            ]
        }
        let data = Self.ifc(lines.joined(separator: "\n"), contained: [507, 607])
        // The second outline is given copies of the two arcs, its curve rewritten in place.
        let unshared = IFCStep.unsharingCurveSegments(data)
        #expect(unshared.copies == 2)
        let curves = IFCStep.entities(unshared.data) { $0 == "IFCCOMPOSITECURVE" }
        #expect(
            curves.count == 2
                && Set(curves.values.flatMap { IFCStep.references($0.arguments[0]) }).count == 32)
        #expect(IFCStep.unsharingCurveSegments(unshared.data).copies == 0)
        // The copies are new entities, their circles and placements copied, their points shared.
        let before = IFCStep.entities(data) { _ in true }
        let after = IFCStep.entities(unshared.data) { _ in true }
        #expect(after.count == before.count + 2 * 4)
        #expect(Set(after.values.map(\.id)).count == after.count)
        #expect(
            after.values.filter { $0.name == "IFCCARTESIANPOINT" }.count
                == before.values.filter { $0.name == "IFCCARTESIANPOINT" }.count)
        // Everything else is as it was: a file with nothing shared comes back unchanged.
        #expect(
            before.values.allSatisfy { entity in
                entity.name == "IFCCOMPOSITECURVE" || after[entity.id] == entity
            })
        let plain = Self.ifc(Self.box(100, [0, 0, 0], [1, 1, 1]))
        #expect(IFCStep.unsharingCurveSegments(plain).data == plain)
    }

    @Test("Past the triangle limit the message says to choose fewer elements")
    func triangleLimit() throws {
        let guid = Self.id(5)
        var text = "g \(guid)\nv 0 0 0\nv 1 0 0\nv 0 1 0\n"
        text += String(repeating: "f 1 2 3\n", count: 1_001)
        let metadata = [guid: ImportedMesh.BuildingSourceElement(id: guid, name: "Big", ifcClass: "IfcWall")]
        #expect {
            _ = try IFCImporter.inspectOBJ(Data(text.utf8), metadata: metadata, triangleLimit: 1_000)
        } throws: { error in
            error.localizedDescription.contains("more than 1,000 triangles")
                && error.localizedDescription.contains("a storey at a time")
        }
    }
}
