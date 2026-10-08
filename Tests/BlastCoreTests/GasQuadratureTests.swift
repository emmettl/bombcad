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
        var first = SIMD3<Double>.zero
        var squares = SIMD3<Double>.zero
        var crossXY = 0.0
        for n in domain.cells.indices where domain.cells[n].volume > 0 {
            let lower = domain.centres[n] - SIMD3(repeating: h / 2)
            let nodes = domain.geometry.gasQuadrature(lower: lower, cellSize: h)
            for node in nodes {
                first += node.weight * node.point
                squares += node.weight * node.point * node.point
                crossXY += node.weight * node.point.x * node.point.y
            }
            #expect(abs(nodes.reduce(0) { $0 + $1.weight } - domain.cells[n].volume) / (h * h * h) < 1e-8)
            #expect(
                nodes.allSatisfy { node in
                    node.weight > 0 && !domain.geometry.contains(node.point)
                        && (0..<3).allSatisfy {
                            node.point[$0] >= lower[$0] - 1e-12 && node.point[$0] <= lower[$0] + h + 1e-12
                        }
                })
        }
        // The rotated uniform cube is fully inside [0,2]^3. Its second central
        // moments are isotropic, so these whole-domain gas moments are analytical.
        let solidVolume = 0.8 * 0.8 * 0.8
        let centre = domain.bodyCentre
        #expect(simd_length(first - (SIMD3(repeating: 8) - solidVolume * centre)) < 2e-10)
        let expectedSquares =
            SIMD3<Double>(repeating: 32.0 / 3)
            - solidVolume * (centre * centre + SIMD3(repeating: 0.8 * 0.8 / 12))
        #expect(simd_length(squares - expectedSquares) < 2e-10)
        #expect(abs(crossXY - (8 - solidVolume * centre.x * centre.y)) < 2e-10)
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
