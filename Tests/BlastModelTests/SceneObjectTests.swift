import Foundation
import Testing

@testable import BlastModel

@Suite("Scene object ownership")
struct SceneObjectTests {
    private let a = Box(min: SIMD3(1, 1, 0), max: SIMD3(2, 2, 1))
    private let b = Box(min: SIMD3(3, 1, 0), max: SIMD3(4, 2, 1))

    private func scene() -> Scenario {
        Scenario(
            name: "Ownership", domainSize: SIMD3(repeating: 6), boxes: [a, b],
            charge: Charge(mass: 0, position: SIMD3(5, 5, 1)),
            structure: StructureModel(solids: [a, b], elementSize: 0.5))
    }

    @Test(
        "Legacy inputs acquire stable ownership without changing solver geometry",
        arguments: ScenarioPreset.allCases)
    func legacy(preset: ScenarioPreset) throws {
        let original = preset.scenario
        let encoder = JSONEncoder()
        encoder.userInfo[Scenario.physicsInputEncoding] = true
        let legacy = try encoder.encode(original)
        #expect(!String(decoding: legacy, as: UTF8.self).contains("objectOwnership"))
        let first = try JSONDecoder().decode(Scenario.self, from: legacy)
        let second = try JSONDecoder().decode(Scenario.self, from: legacy)
        #expect(first == second)
        #expect(first.boxes == original.boxes)
        #expect(first.structure == original.structure)
        #expect(first.rigidBoxes == original.rigidBoxes)
        #expect(try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(first)) == first)
    }

    @Test("Editing, duplication, deletion and reorder use identities even for equal geometry")
    func fixedObjects() throws {
        var scene = scene()
        let first = scene.fixedObjects[0].id
        let second = scene.fixedObjects[1].id
        let duplicate = try scene.duplicateFixedObject(id: first)
        #expect(duplicate != first)
        #expect(scene.object(id: duplicate)?.fixedBox == a)
        try scene.updateFixedObject(id: first, box: b)
        #expect(scene.object(id: first)?.fixedBox == b)
        #expect(scene.object(id: second)?.fixedBox == b)
        try scene.reorderObjects(scene.objects.map(\.id).reversed())
        #expect(try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(scene)) == scene)
        try scene.removeObject(id: second)
        #expect(scene.object(id: first)?.fixedBox == b)
        #expect(scene.object(id: duplicate)?.fixedBox == a)
        #expect(throws: SceneObjectError.self) { try scene.updateFixedObject(id: second, box: a) }
        #expect(throws: SceneObjectError.self) { try scene.reorderObjects([first, first]) }
    }

    @Test("Component ownership distinguishes equal regions and rejects stale references")
    func equalComponents() throws {
        var scene = scene()
        scene.structure?.solids = [a, a]
        let object = try #require(scene.structuralObject)
        let references = object.references(.solid)
        var body = try #require(scene.structure)
        body.removeSolid(at: 0)
        try scene.replaceStructure(body, retainingComponentsFrom: object, removing: references[0])
        #expect(scene.componentIndex(references[0]) == nil)
        #expect(scene.componentIndex(references[1]) == 0)
        #expect(scene.structuralObject?.id == object.id)
        #expect(try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(scene)) == scene)
    }

    @Test("Malformed ownership and duplicate object identity are rejected")
    func malformed() throws {
        let original = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(scene())) as? [String: Any])
        for variant in 0..<5 {
            var json = original
            var ownership = try #require(json["objectOwnership"] as? [String: Any])
            var blocks = try #require(ownership["blocks"] as? [[String: Any]])
            switch variant {
            case 0: ownership["version"] = 99
            case 1:
                blocks[1]["id"] = blocks[0]["id"]
                ownership["blocks"] = blocks
            case 2: ownership["order"] = [UUID().uuidString]
            case 3: ownership["blocks"] = []
            default:
                var body = try #require(ownership["structure"] as? [String: Any])
                body["solidIDs"] = []
                ownership["structure"] = body
            }
            json["objectOwnership"] = ownership
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(Scenario.self, from: JSONSerialization.data(withJSONObject: json))
            }
        }
        var unsupported = scene()
        unsupported.objects.append(
            SceneObject(
                id: unsupported.structuralObject!.id, name: "Second",
                representation: .deformable(unsupported.structure!)))
        #expect(throws: SceneObjectError.self) { try unsupported.validateObjectOwnership() }
        #expect(throws: SceneObjectError.self) { try JSONEncoder().encode(unsupported) }
    }
}
