import Foundation
import Metal
import Testing

@testable import BlastCore

/// Freestanding objects and a deformable structure in the air together, stage 1: their masks and
/// wall velocities coexist (`installExperimentalBoxes` beside `setStructures`). A box held in place
/// but given a velocity stands beside a steel plate that a charge bends: the box's cells stay solid
/// at its velocity through the structure's remasks, the box's remaps leave the structure's cells as
/// they are, and the gas changes by what the structure and the box change it apart.
@Suite("Objects beside a moving structure", .gpuThreads)
struct ObjectsBesideStructureTests {
    struct Run {
        var massChange: Double
        var mass: Double
        /// Times a box cell was open after a step, or lost its velocity.
        var boxCellsOpened = 0
        var velocitiesLost = 0
        /// Cells whose solidity a box's remap changed.
        var cellsChangedByRemap = 0
        /// Cells the structure's outline moved through over the run.
        var structureCellsChanged = 0
        /// The step the air first went unstable at, if it did.
        var unstableAt: Int?
    }

    static let boxVelocity = SIMD3<Double>(0, 2, 0)

    static func run(device: MTLDevice, structure: Bool, box: Bool, steps: Int = 300) throws -> Run {
        // A 2 mm steel plate 1.2 m tall and 1 m wide, clamped at its foot, 1.5 m from 1 kg.
        var plate = StructureModel(
            solids: [Box(min: SIMD3(3, 1, 0), max: SIMD3(3.002, 2, 1.2))], material: .structuralSteel,
            elementSize: 0.1, fixedBase: true)
        plate.elementKind = .shell
        var scenario = Scenario(
            name: "Objects beside a structure", domainSize: SIMD3(6, 3, 2.4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1.5, 1.5, 0.6)), gauges: [],
            structure: structure ? plate : nil)
        // Closed, so that no gas leaves: what changes it is the plate's remask and the box's remap.
        scenario.reflectiveFaces = .all
        var configuration = SolverConfiguration()
        configuration.skipStillAir = false
        configuration.mappedCharge = false
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.1, configuration: configuration)
        // A 0.4 m cube beside the plate, held where it is but moving, as far as the air can tell,
        // at 2 m/s along the plate.
        var cube = try RigidBoxBody(mass: 50, size: SIMD3(repeating: 0.4), position: SIMD3(3.6, 1.5, 0.5))
        cube.applyImpulse(50 * Self.boxVelocity)
        if box { try solver.installExperimentalBoxes([cube]) }
        solver.deposit(Charge(mass: 1, position: SIMD3(1.5, 1.5, 0.6)))
        solver.restart()
        let (nx, ny, nz) = (Int(6 / 0.1 + 0.5), Int(3 / 0.1 + 0.5), Int(2.4 / 0.1 + 0.5))
        func solids() -> [Bool] {
            var cells: [Bool] = []
            cells.reserveCapacity(nx * ny * nz)
            for k in 0..<nz { for j in 0..<ny { for i in 0..<nx { cells.append(solver.isSolid(i, j, k)) } } }
            return cells
        }
        var boxCells: [(Int, Int, Int)] = []
        if box {
            for k in 0..<nz {
                for j in 0..<ny {
                    for i in 0..<nx where solver.experimentalBoxOwner(i, j, k) != 0 {
                        boxCells.append((i, j, k))
                    }
                }
            }
        }
        let start = solids()
        let mass0 = solver.totals().mass
        var run = Run(massChange: 0, mass: mass0)
        for step in 0..<steps {
            if box { try solver.clearExperimentalBoxImpulse() }
            let result = solver.advance(steps: 1)
            guard result.isStable else {
                run.unstableAt = step
                break
            }
            for (i, j, k) in boxCells {
                if !solver.isSolid(i, j, k) { run.boxCellsOpened += 1 }
                let v = solver.experimentalWallVelocity(i, j, k)
                if abs(Double(v.y) - Self.boxVelocity.y) > 1e-4 { run.velocitiesLost += 1 }
            }
            if box {
                let before = solids()
                try solver.updateExperimentalBoxes([cube])
                let after = solids()
                run.cellsChangedByRemap += zip(before, after).filter { $0 != $1 }.count
            }
        }
        run.massChange = solver.totals().mass - mass0
        let end = solids()
        run.structureCellsChanged = zip(start, end).filter { $0 != $1 }.count
        return run
    }

    @Test(
        "A held, moving box beside a bending plate keeps its cells and velocity, and leaves the plate's alone"
    )
    func coexist() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        let both = try Self.run(device: device, structure: true, box: true)
        let plateAlone = try Self.run(device: device, structure: true, box: false)
        let boxAlone = try Self.run(device: device, structure: false, box: true)
        let neither = try Self.run(device: device, structure: false, box: false)
        print(
            "both: \(both); plate alone: \(plateAlone.massChange) kg; box alone: \(boxAlone.massChange) kg; "
                + "neither: \(neither.massChange) kg")
        #expect(both.unstableAt == nil && plateAlone.unstableAt == nil && boxAlone.unstableAt == nil)
        #expect(neither.unstableAt == nil)
        // The plate moves through cells, so the remask has work to do.
        #expect(plateAlone.structureCellsChanged > 0)
        #expect(both.boxCellsOpened == 0)
        #expect(both.velocitiesLost == 0)
        #expect(both.cellsChangedByRemap == 0)
        // The gas, in a closed domain: with both the plate and the box, it changes by what each
        // changes it apart (each run's change over the empty domain's).
        let apart = plateAlone.massChange + boxAlone.massChange - neither.massChange
        #expect(abs(both.massChange - apart) <= 1e-4 * both.mass)
    }
}
