import Testing
import simd

@testable import BlastCore

@Suite("Fractional volume remap plan")
struct FractionalVolumeRemapTests {
    @Test("A capacity network reroutes an early transfer to preserve a later cell's only exit")
    func reroutesContestedExit() throws {
        let old = [0.02, 0.02, 0.02, 0.02, 0, 0]
        let new = [0, 0, 0.02, 0.02, 0.02, 0.02]
        let faces = [
            FractionalVolumeRemap.Face(a: 0, b: 2, openArea: 1), .init(a: 0, b: 3, openArea: 1),
            .init(a: 1, b: 2, openArea: 1), .init(a: 2, b: 4, openArea: 1), .init(a: 3, b: 5, openArea: 1),
        ]
        let plan = try FractionalVolumeRemap.build(old: old, new: new, faces: faces)
        #expect(plan.maximumOutflowFraction <= 1 && plan.maximumVolumeResidual < 1e-12)
        let state = old.map { FractionalGasTransport.Cell(volume: $0, density: 1.225, pressure: 101325) }
        let result = try FractionalGasTransport.advance(state, newVolumes: new, transfers: plan.transfers)
        for cell in result where cell.volume > 0 { #expect(abs(cell.pressure() - 101325) < 1e-8) }
    }
    @Test("Substeps respect a small transit cell's donor-volume limit")
    func substeppedTransit() throws {
        let faces = [FractionalVolumeRemap.Face(a: 0, b: 1, openArea: 1), .init(a: 1, b: 2, openArea: 1)]
        var volumes = [0.02, 0.001, 0.0]
        var cells = volumes.map { FractionalGasTransport.Cell(volume: $0, density: 1.225, pressure: 101325) }
        let initial = cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        for step in 1...40 {
            let filled = 0.02 * Double(step) / 40
            let next = [0.02 - filled, 0.001, filled]
            let plan = try FractionalVolumeRemap.build(old: volumes, new: next, faces: faces)
            #expect(plan.maximumOutflowFraction <= 1)
            cells = try FractionalGasTransport.advance(cells, newVolumes: next, transfers: plan.transfers)
            volumes = next
        }
        let final = cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        for axis in 0..<5 { #expect(abs(final[axis] - initial[axis]) < 1e-10) }
        for cell in cells where cell.volume > 0 { #expect(abs(cell.pressure() - 101325) < 1e-6) }
    }
    @Test("Moving-box geometry generates conservative adjacent transfers", arguments: [0.2, 0.1, 0.05])
    func geometryPlan(cell: Double) throws {
        let result = try #require(ExperimentalFractionalRemapStudy.run(cellSizes: [cell]).first)
        #expect(result.transferCount > 0)
        #expect(result.maximumOutflowFraction <= 1)
        #expect(abs(result.relativeMassChange) < 1e-10)
        #expect(abs(result.relativeEnergyChange) < 1e-10)
        #expect(simd_length(result.momentumChange) < 1e-10)
        #expect(result.maximumRelativePressureError < 1e-8)
    }
    @Test("Closing and opening cells route only through available adjacent gas")
    func connectedPlan() throws {
        let old = [0.02, 0.08, 0.0]
        let new = [0.0, 0.08, 0.02]
        let faces = [FractionalVolumeRemap.Face(a: 0, b: 1, openArea: 1), .init(a: 1, b: 2, openArea: 1)]
        let plan = try FractionalVolumeRemap.build(old: old, new: new, faces: faces)
        #expect(plan.maximumVolumeResidual < 1e-12 && plan.maximumOutflowFraction <= 1)
        let state = old.map { FractionalGasTransport.Cell(volume: $0, density: 1.225, pressure: 101325) }
        let result = try FractionalGasTransport.advance(state, newVolumes: new, transfers: plan.transfers)
        for cell in result where cell.volume > 0 { #expect(abs(cell.pressure() - 101325) < 1e-8) }
    }
    @Test("Disconnected paths and dry relay cells fail without inventing gas")
    func rejectsMissingRoutes() throws {
        #expect(throws: FractionalVolumeRemap.Failure.self) {
            try FractionalVolumeRemap.build(
                old: [0.02, 0, 0], new: [0, 0, 0.02],
                faces: [.init(a: 0, b: 1, openArea: 1), .init(a: 1, b: 2, openArea: 1)])
        }
        #expect(throws: FractionalVolumeRemap.Failure.self) {
            try FractionalVolumeRemap.build(
                old: [0.02, 0], new: [0, 0.02], faces: [.init(a: 0, b: 1, openArea: 0)])
        }
        #expect(throws: FractionalVolumeRemap.Failure.self) {
            try FractionalVolumeRemap.build(
                old: [0.02, 0], new: [0, 0.03], faces: [.init(a: 0, b: 1, openArea: 1)])
        }
    }
    @Test("A thin transit cell cannot carry more than its initial gas volume")
    func transitCapacity() throws {
        #expect(throws: FractionalVolumeRemap.Failure.self) {
            try FractionalVolumeRemap.build(
                old: [0.02, 0.001, 0], new: [0, 0.001, 0.02],
                faces: [.init(a: 0, b: 1, openArea: 1), .init(a: 1, b: 2, openArea: 1)])
        }
    }
}
