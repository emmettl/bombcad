import CompressibleFlow
import Testing
import simd

@testable import BlastCore

@Suite("Released shared Euler bindings")
struct SharedEulerBindingsTests {
    @Test("The actual app-owned tube stages assemble the released public result type")
    func multistageBinding() throws {
        let operatorType: CompressibleFlow.FractionalEulerFlux.Type = FractionalEulerFlux.self
        let cell = FractionalGasTransport.Cell(volume: 1, density: 1, pressure: 1)
        let walls: [CompressibleFlow.FractionalEulerFlux.Wall] = [
            FractionalEulerFlux.Wall(cell: 0, normal: SIMD3(-1, 0, 0), area: 1),
            .init(cell: 0, normal: SIMD3(1, 0, 0), area: 1),
        ]
        let result: CompressibleFlow.FractionalEulerFlux.Result = try LimitedTubeFlux.advance(
            [cell], area: 1, walls: walls, duration: 0.001, cfl: 0.2)
        #expect(result.cells == [cell] && result.wallImpulses.count == 2)
        #expect(result.wallWork == [0, 0])
        #expect(result.wallImpulses[0].x == -0.001 && result.wallImpulses[1].x == 0.001)
        #expect(try operatorType.maximumStep([cell], faces: [], walls: walls).isFinite)
    }

    @Test("App-facing invalid geometry retains the released failure identity")
    func failureBinding() throws {
        let cells = [FractionalGasTransport.Cell](
            repeating: .init(volume: 1, density: 1, pressure: 1), count: 2)
        let faces: [CompressibleFlow.FractionalEulerFlux.Face] = [
            FractionalEulerFlux.Face(a: 0, b: 1, normal: SIMD3(2, 0, 0), area: 1)
        ]
        #expect(throws: CompressibleFlow.FractionalEulerFlux.Failure.invalidFace) {
            try FractionalEulerFlux.maximumStep(cells, faces: faces)
        }
    }
}
