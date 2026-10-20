import Testing
import simd

@testable import BlastModel

/// Several freestanding objects with one in the air. Consistency checks only.
@Suite("Experimental rigid-world coupling", .serialized)
struct ExperimentalRigidWorldTests {
    @Test("A cell freed or squeezed between touching objects trades gas with the nearest air")
    func trappedCells() throws {
        // A row of five cells; the middle one opens, then closes, between two solid ones.
        let cell = CellState(
            Primitive(density: 1.2, velocity: SIMD3(0.25, 0, 0), pressure: 101325), gamma: 1.4)
        var empty = cell
        empty.density = 0
        empty.momentumX = 0
        empty.energy = 0
        let cells = [cell, empty, empty, empty, cell]
        let neighbours = { (n: Int) in [n - 1, n + 1].filter { $0 >= 0 && $0 < 5 } }
        func total(_ list: [CellState]) -> SIMD3<Double> {
            list.reduce(.zero) { $0 + SIMD3(Double($1.density), Double($1.momentumX), Double($1.energy)) }
        }
        let opened = try ConservativeCellRemap.apply(
            cells, oldSolid: [false, true, true, true, false], newSolid: [false, true, false, true, false],
            neighbours: neighbours)
        #expect(opened[2].density > 0)
        #expect(simd_length(total(opened) - total(cells)) < 1e-6 * simd_length(total(cells)))
        let closed = try ConservativeCellRemap.apply(
            opened, oldSolid: [false, true, false, true, false], newSolid: [false, true, true, true, false],
            neighbours: neighbours)
        #expect(simd_length(total([closed[0], closed[4]]) - total(cells)) < 1e-6 * simd_length(total(cells)))
    }
}
