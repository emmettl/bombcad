import Foundation
import SceneModel
import SceneView
import Testing
import simd

@Suite("Shared geometry and camera")
struct GeometryTests {
    @Test("Bounds keep the saved-layout JSON representation")
    func boxCoding() throws {
        let data = Data(#"{"min":[1,2,3],"max":[5,8,10]}"#.utf8)
        let box = try JSONDecoder().decode(Box.self, from: data)
        #expect(box.size == SIMD3<Float>(4, 6, 7))
        let encoded = try JSONEncoder().encode(box)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: [Int]])
        #expect(object == ["min": [1, 2, 3], "max": [5, 8, 10]])
    }

    @Test("Grid centres map back to their cells with x-fastest indexing")
    func gridMapping() {
        let grid = Grid(nx: 7, ny: 5, nz: 3, cellSize: 0.25)
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for i in 0..<grid.nx {
                    let cell = grid.cell(containing: grid.cellCentre(i, j, k))
                    #expect(cell.0 == i && cell.1 == j && cell.2 == k)
                    #expect(grid.index(i, j, k) == i + 7 * j + 35 * k)
                }
            }
        }
    }

    @Test("Bounds framing and centre rays follow translated scenes")
    func cameraTranslation() {
        let bounds = Box(min: SIMD3(0, 0, 0), max: SIMD3(8, 6, 4))
        let offset = SIMD3<Float>(100, -20, 30)
        let first = OrbitCamera.framing(bounds)
        let shifted = OrbitCamera.framing(Box(min: bounds.min + offset, max: bounds.max + offset))
        #expect(shifted.target == first.target + offset)
        #expect(shifted.distance == first.distance)
        let ray = shifted.ray(ndc: .zero, aspectRatio: 1.5)
        #expect(simd_length(ray.direction - simd_normalize(shifted.target - ray.origin)) < 1e-6)
        #expect(simd_length(shifted.eye - first.eye - offset) < 1e-4)
    }
}
