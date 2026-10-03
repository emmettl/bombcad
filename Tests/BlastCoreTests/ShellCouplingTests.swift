import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Checks that the air loads shells correctly and that their solid mask follows them.
@Suite("Shell coupling")
struct ShellCouplingTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    private static let elastic = StructureMaterial.elastic(
        density: 2400, youngsModulus: 20e9, poissonRatio: 0.2)

    /// A shock tube closed by a 500 mm wall meshed with shells.
    private func makeTube(fixedBase: Bool) throws -> (
        solver: BlastSolver, shells: ShellSolver, ambient: Atmosphere
    ) {
        var model = StructureModel(
            solids: [Box(x: 8...8.5, y: 0...4, height: 4)], material: Self.elastic, elementSize: 0.25,
            fixedBase: fixedBase)
        model.elementKind = .shell
        model.shellLayers = 4
        var scenario = Scenario(
            name: "Tube", domainSize: SIMD3(16, 4, 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)),
            gauges: [Gauge("Face", at: SIMD3(7.9, 2, 2)), Gauge("Downstream", at: SIMD3(12, 2, 2))],
            structure: model)
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        let shells = try #require(solver.shells)
        let ambient = scenario.atmosphere
        solver.fill { i, _, _ in
            Primitive(
                density: ambient.density * (i < 8 ? 4 : 1), pressure: ambient.pressure * (i < 8 ? 5 : 1))
        }
        return (solver, shells, ambient)
    }

    @Test("The wall's thickness is solid to the air, and nothing else")
    func mask() throws {
        let (solver, _, _) = try makeTube(fixedBase: true)
        for j in [0, 8, 15] {
            for k in [0, 8, 15] {
                #expect(solver.isSolid(32, j, k) && solver.isSolid(33, j, k))
                #expect(!solver.isSolid(31, j, k) && !solver.isSolid(34, j, k))
            }
        }
    }

    @Test("A free shell wall gains exactly the impulse the air delivers to its face")
    func impulseTransfer() throws {
        let (solver, shells, ambient) = try makeTube(fixedBase: false)
        shells.gravity = 0
        shells.groundContact = false
        solver.advance(until: 0.025)
        let history = try #require(solver.gaugeHistories.first)
        #expect(history.allSatisfy { $0.pressure >= ambient.pressure - 1 })
        var delivered = 0.0
        for k in 0..<solver.grid.nz {
            for j in 0..<solver.grid.ny {
                delivered += Double(solver.impulse(31, j, k)) * 0.25 * 0.25
            }
        }
        let momentum = shells.momentum()
        #expect(delivered > 10_000, "delivered \(delivered) N s")
        #expect(abs(momentum.x - delivered) / delivered < 0.02, "momentum \(momentum.x) vs \(delivered) N s")
        #expect(abs(momentum.y) + abs(momentum.z) < 0.001 * delivered)
    }

    @Test("An intact shell wall lets through only the sound it makes by flexing")
    func intactWallSeals() throws {
        let (solver, shells, ambient) = try makeTube(fixedBase: true)
        solver.advance(until: 0.03)
        let downstream = try #require(solver.gaugeHistories.last)
        let loudest = downstream.map { abs($0.pressure - ambient.pressure) }.max() ?? 0
        #expect(loudest > 20 && loudest < 2000, "downstream overpressure \(loudest) Pa")
        #expect(!shells.hasFailed)
        #expect(!shells.summary().hasBlownUp)
    }

    @Test("A hole in a shell wall opens the air's mask and lets the blast through")
    func breachVents() throws {
        let (solver, shells, ambient) = try makeTube(fixedBase: true)
        shells.erode { abs($0.y - 2) < 0.5 && abs($0.z - 2) < 0.5 }
        solver.advance(steps: 1)
        #expect(!solver.isSolid(32, 8, 8) && !solver.isSolid(33, 8, 8), "the hole should be open to the air")
        #expect(solver.isSolid(32, 2, 2) && solver.isSolid(33, 14, 14), "the rest of the wall should remain")
        let result = solver.advance(until: 0.03)
        #expect(result.isStable)
        let downstream = try #require(solver.gaugeHistories.last)
        let peak = (downstream.map(\.pressure).max() ?? 0) - ambient.pressure
        #expect(peak > 10_000, "downstream overpressure \(peak) Pa")
    }
}
