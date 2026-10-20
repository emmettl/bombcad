import Foundation
import Testing
import simd

@testable import BlastModel

/// Material and model set-up on the CPU that no test checks: steel's rate law by grade, the
/// timber strength classes and cross-laminated panels, and per-solid assignments.
@Suite("Structure materials and models: untested paths")
struct StructureModelGapTests {
    /// `StructureModel.solidNear` meshes the pieces near a charge as solids and the rest as
    /// shells. It has three outcomes: mixed (the shells at `shellSize`), none near (all shells,
    /// the body's element size becoming `shellSize`), and all near (all solids, unchanged sizes).
    /// Per-solid buckling curves (`setBucklingCurve`) are trimmed of trailing defaults, as their
    /// encoding relies on, follow their solids through `part` and `removeSolid`, and survive
    /// encoding.
    @Test(
        "Solids near a point are meshed as solids, the rest as shells; per-solid curves keep to their solids")
    func perSolidAssignments() throws {
        let near = Box(min: SIMD3(0, 0, 0), max: SIMD3(1, 0.2, 2))
        let middle = Box(min: SIMD3(3, 0, 0), max: SIMD3(4, 0.2, 2))
        let far = Box(min: SIMD3(10, 0, 0), max: SIMD3(11, 0.2, 2))
        let model = StructureModel(solids: [near, middle, far], elementSize: 0.05)

        // Within 1 m of the first wall's face (the second is 2.5 m off).
        let mixed = model.solidNear(SIMD3(-0.5, 0.1, 1), within: 1, shellSize: 0.25)
        #expect(mixed.isMixed)
        #expect((0..<3).map { mixed.elementKind(of: $0) } == [.solid, .shell, .shell])
        #expect(mixed.shellElementSize == 0.25 && mixed.elementSize == 0.05)
        #expect(mixed.part(.shell)?.elementSize == 0.25 && mixed.part(.solid)?.solids == [near])
        // On the boundary the distance counts as near.
        let boundary = model.solidNear(SIMD3(-1, 0.1, 1), within: 1, shellSize: 0.25)
        #expect(boundary.elementKind(of: 0) == .solid)

        let none = model.solidNear(SIMD3(-20, 0.1, 1), within: 1, shellSize: 0.25)
        #expect(!none.isMixed && none.isAllShells)
        #expect(none.elementKind == .shell && none.solidElementKind.isEmpty && none.elementSize == 0.25)

        let all = model.solidNear(SIMD3(5, 0.1, 1), within: 20, shellSize: 0.25)
        #expect(!all.isMixed && !all.isAllShells && all.elementKind == .solid)
        #expect(all.elementSize == 0.05 && all.shellElementSize == nil)

        var curves = model
        curves.setBucklingCurve(.c, of: 1)
        #expect(curves.solidBucklingCurves == [nil, .c])
        #expect((0..<3).map { curves.bucklingCurve(of: $0) } == [.b, .c, .b])
        // Out of range is ignored; setting the model's default back trims the list.
        curves.setBucklingCurve(.a, of: 7)
        #expect(curves.solidBucklingCurves == [nil, .c])
        let decoded = try JSONDecoder().decode(StructureModel.self, from: JSONEncoder().encode(curves))
        #expect(decoded.solidBucklingCurves == [nil, .c] && decoded.bucklingCurve(of: 1) == .c)
        var removed = curves
        removed.removeSolid(at: 0)
        #expect(removed.bucklingCurve(of: 0) == .c && removed.bucklingCurve(of: 1) == .b)
        curves.setBucklingCurve(nil, of: 1)
        #expect(curves.solidBucklingCurves.isEmpty)
    }
}
