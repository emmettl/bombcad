import Testing
import simd

@testable import BlastCore

@Suite("Import placement shortcuts")
struct ImportPlacementTests {
    @Test("Units and up axis determine the physical footprint without changing scale")
    func dimensions() throws {
        let bounds = Box(min: SIMD3(10, 20, 30), max: SIMD3(110, 220, 330))
        let size = try ImportPlacement.size(sourceBounds: bounds, scale: 0.01, yUp: true)
        #expect(simd_distance(size, SIMD3(1, 3, 2)) < 1e-5)
    }
    @Test("Centering preserves height and ground placement preserves horizontal coordinates")
    func placement() throws {
        let corner = SIMD3<Float>(7, 9, 3)
        let size = SIMD3<Float>(2, 4, 1)
        let domain = SIMD3<Float>(10, 12, 8)
        #expect(
            try ImportPlacement.centeredFootprint(size: size, corner: corner, domain: domain)
                == SIMD3(4, 4, 3))
        #expect(ImportPlacement.onGround(corner: corner) == SIMD3(7, 9, 0))
        #expect(throws: ImportedMesh.ImportError.self) {
            try ImportPlacement.centeredFootprint(size: SIMD3(11, 4, 1), corner: corner, domain: domain)
        }
    }
    @Test("Expanding adds clearance and preserves all existing domain extents")
    func expand() throws {
        let current = SIMD3<Float>(10, 12, 8)
        let result = try ImportPlacement.expandedDomain(
            size: SIMD3(2, 4, 1), corner: SIMD3(9, 11, 0), current: current, cellSize: 0.5,
            maxCells: 1_000_000)
        #expect(result == SIMD3(12, 16, 8))
        #expect(all(result .>= current))
        #expect(
            try ImportPlacement.expandedDomain(
                size: SIMD3(repeating: 1), corner: .zero, current: current, cellSize: 0.5, maxCells: 1_000_000
            ) == current)
    }
    @Test("Memory limits and invalid placement reject expansion before changing a layout")
    func limits() throws {
        #expect(throws: ImportedMesh.ImportError.self) {
            try ImportPlacement.expandedDomain(
                size: SIMD3(2, 4, 1), corner: SIMD3(9, 11, 0), current: SIMD3(10, 12, 8), cellSize: 0.5,
                maxCells: 1000)
        }
        #expect(throws: ImportedMesh.ImportError.self) {
            try ImportPlacement.expandedDomain(
                size: SIMD3(repeating: 1), corner: SIMD3(-1, 0, 0), current: SIMD3(repeating: 4),
                cellSize: 0.25, maxCells: 1_000_000)
        }
        #expect(throws: ImportedMesh.ImportError.self) {
            try ImportPlacement.size(
                sourceBounds: Box(min: .zero, max: SIMD3(repeating: 1)), scale: .infinity, yUp: false)
        }
    }
}
