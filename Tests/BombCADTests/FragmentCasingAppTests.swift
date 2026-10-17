import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@Suite("A casing's dimensions and metal in projects and headless runs")
struct FragmentCasingAppTests {
    @Test("--casing sets the description's dimensions and metal, and needs --fragments")
    func options() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "casing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "casing.json")
        try Data(#"{"casingMass": 10, "count": 500}"#.utf8).write(to: file)
        let options = try HeadlessRun.Options.parse([
            "a.bombcad", "--fragments", file.path, "--casing", "0.006,0.25,castIron",
        ])
        let spec = try #require(options.fragments)
        #expect(spec.wallThickness == 0.006 && spec.innerDiameter == 0.25 && spec.metal == .castIron)
        let steel = try HeadlessRun.Options.parse([
            "a.bombcad", "--fragments", file.path, "--casing", "0.006,0.25",
        ])
        #expect(steel.fragments?.metal == .steel && steel.fragments?.mottMeanMass != nil)
        for arguments in [
            ["a.bombcad", "--casing", "0.006,0.25"],
            ["a.bombcad", "--fragments", file.path, "--casing", "0.006"],
            ["a.bombcad", "--fragments", file.path, "--casing", "0.006,-1"],
            ["a.bombcad", "--fragments", file.path, "--casing", "0.006,0.25,lead"],
        ] {
            #expect(throws: ProjectFileError.self) { try HeadlessRun.Options.parse(arguments) }
        }
    }

    @Test("A project keeps its casing's dimensions and metal; one saved without them opens as before")
    func saved() throws {
        var document = ProjectDocument(
            scenario: Scenario(
                name: "Cased", domainSize: SIMD3(repeating: 20), boxes: [],
                charge: Charge(mass: 10, position: SIMD3(10, 10, 1))))
        var spec = FragmentSpec()
        spec.casingMass = 1
        spec.count = 200
        spec.wallThickness = 0.004
        spec.innerDiameter = 0.12
        spec.metal = .castIron
        document.fragments = spec
        let reopened = try ProjectDocument(archive: document.makeArchive())
        #expect(reopened.fragments == spec && reopened.fragments?.metal == .castIron)
        // Without them, the description is written as it always was.
        spec.wallThickness = nil
        spec.innerDiameter = nil
        spec.metal = .steel
        let json = try String(decoding: JSONEncoder().encode(spec), as: UTF8.self)
        #expect(!json.contains("wallThickness") && !json.contains("massExponent"))
    }
}
