import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Glazing thinner than a cell holds its own cells in the air (`BuildingEnvelope.paneCells`).
@Suite("Envelope pane cells", .serialized, .gpuThreads)
struct EnvelopePaneCellTests {
    /// A 6 m wall 0.2 m thick with a window 1.5 by 1.25 m, its 6 mm glass at the wall's middle:
    /// in a cut opening, or set in the wall without one.
    func wall(cutOpening: Bool) throws -> BuildingEnvelope {
        let solid = Box(min: SIMD3(4, 4, 0), max: SIMD3(10, 4.2, 3))
        let window = Box(min: SIMD3(6.25, 4, 1), max: SIMD3(7.75, 4.2, 2.25))
        let pane = Box(min: SIMD3(6.25, 4.097, 1), max: SIMD3(7.75, 4.103, 2.25))
        return try BuildingEnvelope(solids: [solid], openings: cutOpening ? [window] : [], panes: [pane])
    }

    func scene(cutOpening: Bool) throws -> Scenario {
        var scene = Scenario(
            name: "Glazed wall", domainSize: SIMD3(16, 16, 6), boxes: [],
            charge: Charge(mass: 0.5, position: SIMD3(7, 1, 1)))
        try scene.addEnvelopeObject(wall(cutOpening: cutOpening), name: "Wall")
        return scene
    }

    @Test("A pane thinner than a cell takes the cells across its window through its wall, cut or not")
    func cells() throws {
        for cut in [true, false] {
            let scene = try scene(cutOpening: cut)
            let grid = scene.grid(cellSize: 0.25)
            let cells = scene.envelopeObjects[0].envelope!.paneCells(0, grid: grid)
            // 6 across, 5 up (centres in [1, 2.25)), the wall's one row of centres (4.125 m) through.
            #expect(cells.count == 30, "cut \(cut): \(cells.count)")
            #expect(Set(cells.map { ($0 / grid.nx) % grid.ny }) == [16])
        }
    }

    @Test("Its window is closed in the air and it records the load, not the wall")
    func records() throws {
        for cut in [true, false] {
            let scene = try scene(cutOpening: cut)
            let solver = try BlastSolver(
                device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.25)
            let cells = scene.envelopeObjects[0].envelope!.paneCells(0, grid: solver.grid)
            let grid = solver.grid
            #expect(
                cells.allSatisfy {
                    solver.isSolid($0 % grid.nx, ($0 / grid.nx) % grid.ny, $0 / (grid.nx * grid.ny))
                })
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.02))
            _ = solver.advance(until: 0.012)
            let histories = try #require(solver.envelopeComponentHistories())
            let pane = try #require(histories.first { $0.component.kind == .pane })
            // Both its faces, 30 cells' each, and the blast's load on the side facing it.
            #expect(pane.faceCount == 60, "cut \(cut): \(pane.faceCount) faces")
            #expect(max(pane.peakOuterPa, pane.peakInnerPa) > 1000, "cut \(cut)")
        }
    }
}
