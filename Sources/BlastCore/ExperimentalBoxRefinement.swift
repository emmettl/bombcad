import Foundation

// Only the explicit ExperimentalRigidBox/CarSimulation drivers call this synchronous reference path.
extension BlastSolver {
    /// Removes the gas that placing the first patches packed into the box's fluid fine cells.
    ///
    /// Where a box face cuts through a coarse cell of air, `refineFillConserve` shares the gas
    /// the coarse cell held over the fine cells inside the box among those outside it, so that
    /// placing a patch neither loses nor gains gas. That is right for gas that was there, but at
    /// installation the coarse cell's gas over the box was only the domain's fill: the car's
    /// shell, whose top and bottom lie inside coarse cells, would start in air at up to twice
    /// ambient pressure and be pushed up by it. Call once, straight after the patches are first
    /// placed and before any step; each fluid child gives back the share it was given.
    /// Returns the gas mass removed (kg).
    @discardableResult
    func removeExperimentalBoxPackedGas() -> Double {
        guard let refinement else { return 0 }
        let r = refinement.ratio
        let side = refinement.side
        let cells = side * side * side
        let owners = refinement.tileOfPatch.contents().bindMemory(
            to: UInt32.self, capacity: refinement.maxPatches)
        let fine = refinement.fine[0].contents().bindMemory(
            to: CellState.self, capacity: refinement.maxPatches * cells)
        let fineMask = refinement.fineMask.contents().bindMemory(
            to: UInt8.self, capacity: refinement.maxPatches * cells)
        let coarseMask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        let dims = refinement.tileDims
        let volume =
            Double(grid.cellSize / Float(r)) * Double(grid.cellSize / Float(r))
            * Double(grid.cellSize / Float(r))
        var removed = 0.0
        for patch in 0..<refinement.maxPatches where owners[patch] != .max {
            let tile = Int(owners[patch])
            let block =
                SIMD3(tile % dims.x, (tile / dims.x) % dims.y, tile / (dims.x * dims.y))
                &* AirRefinement.patchSize
            func child(_ cell: SIMD3<Int>, _ n: Int) -> Int {
                let local = (cell &- block) &* r &+ SIMD3(n % r, (n / r) % r, n / (r * r))
                return patch * cells + local.x + side * (local.y + side * local.z)
            }
            for c in 0..<(AirRefinement.patchSize * AirRefinement.patchSize * AirRefinement.patchSize) {
                let p = AirRefinement.patchSize
                let cell = block &+ SIMD3(c % p, (c / p) % p, c / (p * p))
                guard grid.contains(cell.x, cell.y, cell.z),
                    coarseMask[grid.index(cell.x, cell.y, cell.z)] == 0
                else { continue }
                var lost = SIMD8<Double>.zero
                var fluid = 0
                var inBox = 0
                for n in 0..<(r * r * r) {
                    let at = child(cell, n)
                    if fineMask[at] & 1 == 0 {
                        fluid += 1
                    } else {
                        // Only the box's own cells: scenery's outline is the air solver's business.
                        guard fineMask[at] & 8 != 0 else { continue }
                        inBox += 1
                        let s = fine[at]
                        lost += SIMD8(
                            Double(s.density), Double(s.momentumX), Double(s.momentumY), Double(s.momentumZ),
                            Double(s.energy), 0, 0, 0)
                    }
                }
                guard inBox > 0, fluid > 0 else { continue }
                let share = lost / Double(fluid)
                for n in 0..<(r * r * r) {
                    let at = child(cell, n)
                    guard fineMask[at] & 1 == 0 else { continue }
                    fine[at].density -= Float(share[0])
                    fine[at].momentumX -= Float(share[1])
                    fine[at].momentumY -= Float(share[2])
                    fine[at].momentumZ -= Float(share[3])
                    fine[at].energy -= Float(share[4])
                }
                removed += lost[0] * volume
            }
        }
        return removed
    }
}
