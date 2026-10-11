import Testing
import simd

@testable import BlastCore

@Suite("Conserved quadratic gas reconstruction")
struct ConservedGasReconstructionTests {
    private func conserved(_ p: SIMD3<Double>) -> SIMD8<Double> {
        SIMD8(
            2 + 0.1 * p.x + 0.02 * p.x * p.x - 0.01 * p.y * p.z,
            0.3 + 0.12 * p.y + 0.02 * p.x * p.z,
            -0.2 + 0.15 * p.z - 0.01 * p.y * p.y,
            0.05 + 0.1 * p.x - 0.02 * p.x * p.y,
            3 + 0.2 * p.y + 0.04 * p.z * p.z + 0.02 * p.x * p.y, 0, 0, 0)
    }
    private func nodes(_ centre: SIMD3<Double>, index: Int) -> [SIMD3<Double>] {
        let rotation = simd_quatd(angle: 0.04 * Double(index), axis: simd_normalize(SIMD3(1.0, 2, 3)))
        let extent = SIMD3<Double>(0.1 + 0.003 * Double(index), 0.15, 0.08 + 0.002 * Double(index))
        return (0..<8).map { n in
            centre
                + rotation.act(
                    extent
                        * SIMD3<Double>(
                            n & 1 == 0 ? -1 : 1, n & 2 == 0 ? -1 : 1, n & 4 == 0 ? -1 : 1) / sqrt(3.0))
        }
    }
    private func sample(_ centre: SIMD3<Double>, index: Int, boost: SIMD3<Double>)
        -> ConservedGasReconstruction.Sample
    {
        let points = nodes(centre, index: index)
        var covariance = FiniteVolumePressureFit.zero
        var average = SIMD8<Double>.zero
        for point in points {
            let offset = point - centre
            covariance +=
                (1.0 / 8)
                * simd_double3x3(
                    columns: (
                        offset * offset.x, offset * offset.y, offset * offset.z
                    ))
            average += ConservedGasReconstruction.transform(conserved(point), velocity: -boost) / 8
        }
        return .init(centre: centre, covariance: covariance, density: average)
    }

    @Test(
        "Five independent quadratic densities reproduce point states and all volume inventories with variable rho/u"
    )
    func polynomial() throws {
        for boost in [SIMD3<Double>.zero, SIMD3(300, -200, 70)] {
            var samples: [ConservedGasReconstruction.Sample] = []
            for z in -1...1 {
                for y in -1...1 {
                    for x in -1...1 {
                        samples.append(
                            sample(SIMD3(Double(x), Double(y), Double(z)), index: samples.count, boost: boost)
                        )
                    }
                }
            }
            let local = samples[13]
            let volume = nodes(local.centre, index: 13)
            let controls = volume + [SIMD3(0.2, -0.1, 0.17), SIMD3(-0.3, 0.4, -0.2)]
            let fit = try ConservedGasReconstruction.fit(
                cell: local, neighbours: samples.enumerated().filter { $0.offset != 13 }.map(\.element),
                controls: controls, scale: 0.4, boundComponents: false)
            #expect(fit.factor == 1 && !fit.positivityReduced && !fit.rankFallback)
            for point in controls {
                let exact = ConservedGasReconstruction.transform(conserved(point), velocity: -boost)
                let actual = fit.state(at: point)
                for c in 0..<5 { #expect(abs(actual.amount[c] - exact[c]) / max(1, abs(exact[c])) < 1e-10) }
                #expect(actual.pressure() > 0)
            }
            let recovered = volume.reduce(SIMD8<Double>.zero) { $0 + fit.state(at: $1).amount / 8 }
            for c in 0..<5 {
                #expect(abs(recovered[c] - local.density[c]) / max(1, abs(local.density[c])) < 1e-11)
            }
        }
    }

    @Test(
        "Common EOS backoff repairs inadmissible sampled kinetic energy without changing any mean inventory")
    func positivity() throws {
        let zero = FiniteVolumePressureFit.zero
        let cell = ConservedGasReconstruction.Sample(
            centre: .zero, covariance: simd_double3x3(diagonal: SIMD3(repeating: 1.0 / 3)),
            density: SIMD8(1, 0, 0, 0, 1, 0, 0, 0))
        let axes = [SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        let neighbours = (axes + axes.map { -$0 }).map { point in
            ConservedGasReconstruction.Sample(
                centre: point, covariance: zero,
                density: SIMD8(1, 1.3 * point.x, 1.3 * point.y, 0, 1, 0, 0, 0))
        }
        let volume = (0..<8).map { n in
            SIMD3<Double>(n & 1 == 0 ? -1 : 1, n & 2 == 0 ? -1 : 1, n & 4 == 0 ? -1 : 1) / sqrt(3.0)
        }
        let controls = volume + [SIMD3(1, 1, 0)]
        let fit = try ConservedGasReconstruction.fit(
            cell: cell, neighbours: neighbours, controls: controls, scale: 1)
        #expect(fit.positivityReduced && fit.rankFallback && fit.factor > 0 && fit.factor < 0.77)
        for point in controls { #expect(fit.state(at: point).pressure() > 0) }
        let recovered = volume.reduce(SIMD8<Double>.zero) { $0 + fit.state(at: $1).amount / 8 }
        #expect(simd_length(recovered - cell.density) < 1e-12)
        for point in controls {
            let state = fit.state(at: point)
            #expect(abs(state.amount[1]) <= 1.3 && abs(state.amount[2]) <= 1.3)
            #expect(state.amount[4] == 1 && state.amount[0] == 1)
        }
    }

    @Test("Constant density and boosted velocity do not spuriously throttle a smooth pressure polynomial")
    func pressure() throws {
        let velocity = SIMD3<Double>(300, 100, -40)
        func p(_ point: SIMD3<Double>) -> Double { 101325 + 2500 * point.x + 900 * point.y * point.y }
        var samples: [ConservedGasReconstruction.Sample] = []
        for z in -1...1 {
            for y in -1...1 {
                for x in -1...1 {
                    let centre = SIMD3<Double>(Double(x), Double(y), Double(z))
                    let points = nodes(centre, index: samples.count)
                    var covariance = FiniteVolumePressureFit.zero
                    var average = SIMD8<Double>.zero
                    for point in points {
                        let d = point - centre
                        covariance += (1.0 / 8) * simd_double3x3(columns: (d * d.x, d * d.y, d * d.z))
                        average +=
                            FractionalGasTransport.Cell(
                                volume: 1, density: 1.225, velocity: velocity, pressure: p(point)
                            ).amount / 8
                    }
                    samples.append(.init(centre: centre, covariance: covariance, density: average))
                }
            }
        }
        let controls = nodes(.zero, index: 13) + [SIMD3(0.2, -0.1, 0.17)]
        let fit = try ConservedGasReconstruction.fit(
            cell: samples[13], neighbours: samples.enumerated().filter { $0.offset != 13 }.map(\.element),
            controls: controls, scale: 1)
        #expect(fit.factor == 1 && !fit.positivityReduced)
        for point in controls {
            #expect(abs(fit.state(at: point).pressure() - p(point)) < 1e-7)
            #expect(simd_distance(fit.state(at: point).velocity, velocity) < 1e-10)
        }
    }

    @Test("Nonphysical inventories and invalid controls are rejected without repairs")
    func invalid() throws {
        let cell = ConservedGasReconstruction.Sample(
            centre: .zero, covariance: FiniteVolumePressureFit.zero, density: SIMD8(1, 0, 0, 0, -1, 0, 0, 0))
        #expect(throws: FractionalGasTransport.Failure.invalidState) {
            try ConservedGasReconstruction.fit(cell: cell, neighbours: [], controls: [.zero], scale: 1)
        }
        #expect(throws: ConservedGasReconstruction.Failure.invalidGeometry) {
            try ConservedGasReconstruction.fit(cell: cell, neighbours: [], controls: [], scale: 1)
        }
    }
}
