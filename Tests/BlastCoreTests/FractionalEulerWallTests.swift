import Testing
import simd

@testable import BlastCore

@Suite("Stationary fractional Euler walls")
struct FractionalEulerWallTests {
    @Test("Invalid walls and excessive steps fail; separating gas gives positive traction")
    func invalidWall() throws {
        let cell = FractionalGasTransport.Cell(volume: 1, density: 1, pressure: 1)
        let wall = FractionalEulerFlux.Wall(cell: 0, normal: SIMD3(1, 0, 0), area: 1)
        let limit = try FractionalEulerFlux.maximumStep([cell], faces: [], walls: [wall])
        #expect(throws: FractionalEulerFlux.Failure.self) {
            try FractionalEulerFlux.advanceWithWalls([cell], faces: [], walls: [wall], duration: limit * 2)
        }
        #expect(throws: FractionalEulerFlux.Failure.self) {
            try FractionalEulerFlux.maximumStep(
                [cell], faces: [], walls: [.init(cell: 0, normal: SIMD3(2, 0, 0), area: 1)])
        }
        let separating = FractionalGasTransport.Cell(
            volume: 1, density: 1, velocity: SIMD3(-2, 0, 0), pressure: 1)
        let result = try FractionalEulerFlux.advanceWithWalls(
            [separating], faces: [], walls: [wall], duration: 0.001)
        #expect(result.wallImpulses[0].x > 0 && result.wallImpulses[0].x < 0.001)
        #expect(result.cells[0].amount[4] == separating.amount[4])
        let vacuumGap = FractionalGasTransport.Cell(
            volume: 1, density: 1, velocity: SIMD3(-7, 0, 0), pressure: 1)
        let unloaded = try FractionalEulerFlux.advanceWithWalls(
            [vacuumGap], faces: [], walls: [wall], duration: 0.001)
        #expect(unloaded.wallImpulses[0] == .zero)
        #expect(unloaded.cells[0].amount == vacuumGap.amount)
    }
    @Test("Six closed walls preserve resting gas and report pressure times area impulse")
    func restingBox() throws {
        let cell = FractionalGasTransport.Cell(volume: 1, density: 1.225, pressure: 101325)
        let normals = [SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        let walls = normals.flatMap {
            [FractionalEulerFlux.Wall(cell: 0, normal: $0, area: 1), .init(cell: 0, normal: -$0, area: 1)]
        }
        let step = try FractionalEulerFlux.maximumStep([cell], faces: [], walls: walls)
        #expect(step.isFinite && step > 0)
        let result = try FractionalEulerFlux.advanceWithWalls([cell], faces: [], walls: walls, duration: step)
        #expect(result.cells[0].amount == cell.amount)
        for n in walls.indices {
            #expect(simd_length(result.wallImpulses[n] - 101325 * step * walls[n].normal) < 1e-12)
        }
    }

    @Test("A closed pressure pulse balances gas momentum against accumulated wall impulse")
    func closedPulse() throws {
        let initial = (0..<8).map {
            FractionalGasTransport.Cell(
                volume: $0 == 0 ? 0.0001 : 0.001, density: 1.225,
                pressure: $0 == 0 ? 150000 : 101325)
        }
        let faces = (0..<7).map {
            FractionalEulerFlux.Face(a: $0, b: $0 + 1, normal: SIMD3(1, 0, 0), area: 0.01)
        }
        let walls = [
            FractionalEulerFlux.Wall(cell: 0, normal: SIMD3(-1, 0, 0), area: 0.01),
            .init(cell: 7, normal: SIMD3(1, 0, 0), area: 0.01),
        ]
        var cells = initial
        var wallImpulse = SIMD3<Double>.zero
        for _ in 0..<100 {
            let step = try FractionalEulerFlux.maximumStep(cells, faces: faces, walls: walls)
            let result = try FractionalEulerFlux.advanceWithWalls(
                cells, faces: faces, walls: walls, duration: step)
            cells = result.cells
            wallImpulse += result.wallImpulses.reduce(.zero, +)
        }
        let before = initial.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        let after = cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        let gasChange = SIMD3(after[1] - before[1], after[2] - before[2], after[3] - before[3])
        #expect(simd_length(gasChange + wallImpulse) < 1e-12)
        #expect(simd_length(wallImpulse) > 1e-6)
        #expect(abs(after[0] / before[0] - 1) < 1e-12)
        #expect(abs(after[4] / before[4] - 1) < 1e-12)
        #expect(cells.allSatisfy { $0.pressure() > 0 })
    }

    @Test("Tangential slip has no wall mass, energy or tangential momentum transfer")
    func tangentialSlip() throws {
        let old = FractionalGasTransport.Cell(volume: 1, density: 2, velocity: SIMD3(0, 3, 0), pressure: 10)
        let result = try FractionalEulerFlux.advanceWithWalls(
            [old], faces: [],
            walls: [.init(cell: 0, normal: SIMD3(1, 0, 0), area: 1)], duration: 0.01)
        #expect(abs(result.wallImpulses[0].x - 0.1) < 1e-14)
        #expect(result.wallImpulses[0].y == 0)
        for axis in [0, 2, 3, 4] { #expect(result.cells[0].amount[axis] == old.amount[axis]) }
    }
}
