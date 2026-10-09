import BlastCore
import Foundation
import Testing

@testable import BombCAD

@Suite("Layout JSON diagnostics")
struct LayoutJSONDiagnosticsTests {
    private func payload() throws -> [String: Any] {
        let scene = Scenario(
            name: "JSON diagnostics", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(2, 2, 1)))
        return try #require(
            JSONSerialization.jsonObject(with: ScenarioDocument.encode(scene)) as? [String: Any])
    }

    private func expectError(_ data: Data, message: String) {
        do {
            _ = try ProjectDocument(legacyJSON: data)
            Issue.record("Expected layout import to fail")
        } catch {
            #expect(error.localizedDescription == message)
        }
    }

    @Test("Missing layout fields identify the exact required path")
    func missingFields() throws {
        var layout = try payload()
        layout.removeValue(forKey: "reflectiveFaces")
        expectError(
            try JSONSerialization.data(withJSONObject: layout),
            message: "Layout JSON is missing the required field \"reflectiveFaces\".")
        layout = try payload()
        var charge = try #require(layout["charge"] as? [String: Any])
        charge.removeValue(forKey: "mass")
        layout["charge"] = charge
        expectError(
            try JSONSerialization.data(withJSONObject: layout),
            message: "Layout JSON is missing the required field \"charge.mass\".")
    }

    @Test("Wrong value types and nulls identify their field or array position")
    func invalidValues() throws {
        var layout = try payload()
        var charge = try #require(layout["charge"] as? [String: Any])
        charge["position"] = ["invalid", 2, 1] as [Any]
        layout["charge"] = charge
        expectError(
            try JSONSerialization.data(withJSONObject: layout),
            message: "Layout JSON has the wrong value type at \"charge.position[0]\".")
        layout = try payload()
        charge = try #require(layout["charge"] as? [String: Any])
        charge["mass"] = NSNull()
        layout["charge"] = charge
        expectError(
            try JSONSerialization.data(withJSONObject: layout),
            message: "Layout JSON requires a non-null value at \"charge.mass\".")
    }

    @Test("Malformed JSON has a readable syntax error; valid layouts still import")
    func malformedAndValid() throws {
        expectError(Data("{".utf8), message: "The layout file is not valid JSON.")
        let document = try ProjectDocument(legacyJSON: JSONSerialization.data(withJSONObject: payload()))
        #expect(document.scenario.name == "JSON diagnostics")
        #expect(document.scenario.charge.mass == 0)
    }
}
