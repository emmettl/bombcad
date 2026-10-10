import CompressibleFlow
import Testing

@testable import BlastCore

@Suite("Released shared gas packet bindings")
struct SharedPacketBindingsTests {
    @Test("Application packet values and operator are the released public types")
    func publicBinding() throws {
        let input: PrescribedGasTransport.Cell = FractionalGasTransport.Cell(
            volume: 1, density: 1, pressure: 1)
        let transfer: PrescribedGasTransport.Transfer = FractionalGasTransport.Transfer(
            from: 0, to: 1, volume: 0.5)
        let result: [PrescribedGasTransport.Cell] = try FractionalGasTransport.advance(
            [input, input], newVolumes: [0.5, 1.5], transfers: [transfer])
        #expect(result.map { $0.amount[0] } == [0.5, 1.5])
    }
    @Test("App-facing failures and exact dry-cleanup boundary retain their contract")
    func dryBoundary() throws {
        let input = [
            FractionalGasTransport.Cell(volume: 1, amount: SIMD8(1, 1, 0, 0, 64, 0, 0, 0)),
            .init(volume: 0, amount: .zero),
        ]
        let budget = Double(sign: .plus, exponent: -40, significand: 1)
        let result = try FractionalGasTransport.advance(
            input, newVolumes: [0, 1], transfers: [.init(from: 0, to: 1, volume: 1)],
            walls: [.init(cell: 0, impulse: .zero, gasWork: budget)])
        #expect((0..<8).allSatisfy { result[0].amount[$0].bitPattern == 0 })
        #expect(throws: FractionalGasTransport.Failure.occupiedDryCell) {
            try FractionalGasTransport.advance(
                input, newVolumes: [0, 1], transfers: [.init(from: 0, to: 1, volume: 1)],
                walls: [.init(cell: 0, impulse: .zero, gasWork: budget.nextUp)])
        }
    }
}
