import Testing
import simd

@testable import BlastCore

@Suite("Positive gas-volume quadrature")
struct GasQuadratureTests {
    @Test("Full and half-fluid cells integrate quadratic moments")
    func moments() throws {
        for centre in [SIMD3<Double>(3, 0.5, 0.5), SIMD3(1, 0.5, 0.5)] {
            let geometry = FractionalBoxGeometry(
                try RigidBoxBody(
                    mass: 1, size: SIMD3(repeating: 1), position: centre))
            let nodes = geometry.gasQuadrature(lower: .zero, cellSize: 1)
            let width = centre.x == 3 ? 1.0 : 0.5
            #expect(abs(nodes.reduce(0) { $0 + $1.weight } - width) < 1e-12)
            #expect(abs(nodes.reduce(0) { $0 + $1.weight * $1.point.x } - width * width / 2) < 1e-12)
            #expect(
                abs(nodes.reduce(0) { $0 + $1.weight * $1.point.x * $1.point.x } - width * width * width / 3)
                    < 1e-12)
            #expect(abs(nodes.reduce(0) { $0 + $1.weight * $1.point.y * $1.point.y } - width / 3) < 1e-12)
            #expect(
                abs(nodes.reduce(0) { $0 + $1.weight * $1.point.x * $1.point.y } - width * width / 4) < 1e-12)
            #expect(nodes.allSatisfy { $0.weight > 0 && !geometry.contains($0.point) })
        }
    }
    @Test("Rotated cut-cell nodes remain in gas and recover clipped volume", arguments: [0.2, 0.1])
    func clippedVolumes(h: Double) throws {
        let domain = try ExperimentalConnectedGasStudy.domain(cellSize: h, rotation: 0.23)
        for n in domain.cells.indices where domain.cells[n].volume > 0 {
            let lower = domain.centres[n] - SIMD3(repeating: h / 2)
            let nodes = domain.geometry.gasQuadrature(lower: lower, cellSize: h)
            #expect(abs(nodes.reduce(0) { $0 + $1.weight } - domain.cells[n].volume) / (h * h * h) < 1e-8)
            #expect(
                nodes.allSatisfy { node in
                    node.weight > 0 && !domain.geometry.contains(node.point)
                        && (0..<3).allSatisfy {
                            node.point[$0] >= lower[$0] - 1e-12 && node.point[$0] <= lower[$0] + h + 1e-12
                        }
                })
        }
    }
    @Test("Gas-average initialization preserves matched energy and transport budgets")
    func loadInitialization() throws {
        let rows = try ExperimentalConnectedLoadStudy.run(
            cellSizes: [0.2], rotations: [0, 0.23], duration: 0.00005,
            targetPulseEnergy: 6400, volumeAverage: true)
        for r in rows {
            #expect(r.initialization == "gasAverage" && r.maximumQuadratureVolumeResidual < 1e-8)
            let background = 101325 / (1.4 - 1) * r.initialMass / 1.225
            #expect(abs(r.initialEnergy - background - 6400) < 1e-7)
            #expect(abs(r.relativeMassChange) < 1e-12 && abs(r.relativeEnergyChange) < 1e-12)
            #expect(simd_length(r.momentumBudgetResidual) < 1e-10)
        }
    }
}
