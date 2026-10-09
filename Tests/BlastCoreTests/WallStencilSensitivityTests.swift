import Testing
import simd

@testable import BlastCore

@Suite("Initial wall stencil sensitivity")
struct WallStencilSensitivityTests {
    @Test("Graph rings retain unique connected neighbours, exclude the centre and have deterministic order")
    func graph() {
        let adjacency: [Set<Int>] = [[1, 2], [0, 3], [0, 3, 4], [1, 2, 5], [2], [3], []]
        #expect(
            ExperimentalVolumePressureFitStudy.stencil(group: 0, adjacency: adjacency, rings: 1) == [1, 2])
        #expect(
            ExperimentalVolumePressureFitStudy.stencil(group: 0, adjacency: adjacency, rings: 2) == [
                1, 2, 3, 4,
            ])
        #expect(
            ExperimentalVolumePressureFitStudy.stencil(group: 0, adjacency: adjacency, rings: 3) == [
                1, 2, 3, 4, 5,
            ])
        #expect(ExperimentalVolumePressureFitStudy.stencil(group: 6, adjacency: adjacency, rings: 3).isEmpty)
    }

    @Test("Invalid stencil depths are rejected before any geometry or pressure initialization")
    func invalid() {
        for depth in [0, 4] {
            #expect(throws: ExperimentalInitialWallTraceStudy.Failure.invalidConfiguration) {
                try ExperimentalInitialWallTraceStudy.run(volumeFits: true, stencilRings: depth)
            }
        }
    }

    @Test("Additional orientations retain baseline loads across stencil depths, averages and sampled bounds")
    func probe() throws {
        let variants = try (1...3).map { depth in
            try ExperimentalInitialWallTraceStudy.run(
                cellSizes: [0.2], rotations: [0.1, 0.4], volumeFits: true, stencilRings: depth)
        }
        for index in 0..<2 {
            let baseline = variants[1][index]
            var previousSize = 0.0
            for depth in 1...3 {
                let row = variants[depth - 1][index]
                let full = row.volumeFits!
                #expect(full.stencilRings == depth && row.halfDurationVolumeFits!.stencilRings == depth)
                #expect(simd_distance(row.limited.force, baseline.limited.force) < 1e-8)
                #expect(simd_distance(row.limited.torque, baseline.limited.torque) < 1e-8)
                #expect(
                    row.pulseAmplitude == baseline.pulseAmplitude && row.wallSamples == baseline.wallSamples)
                #expect(full.meanStencilSize > previousSize)
                previousSize = full.meanStencilSize
                #expect(
                    full.modes[0].kind == ["oneRingLinear", "twoRingLinear", "threeRingLinear"][depth - 1])
                if depth == 1 { #expect(full.quadraticFallbackAreaFraction > 0) }
                for bound in full.bounds! + row.halfDurationVolumeFits!.bounds! {
                    #expect(bound.maximumRelativeAverageResidual < 1e-10)
                    #expect(bound.maximumRelativeBoundViolation < 1e-12)
                }
                for (a, b) in zip(full.modes, row.halfDurationVolumeFits!.modes) {
                    #expect(
                        simd_distance(a.loads.force, b.loads.force) / simd_length(row.referenceForce) < 1e-5)
                    #expect(
                        simd_distance(a.loads.torque, b.loads.torque) / simd_length(row.referenceTorque)
                            < 1e-5)
                    if a.kind.hasSuffix("Bounded") {
                        #expect(a.outsideStencilAreaFraction == 0 && a.negativeExcessAreaFraction == 0)
                    }
                }
            }
        }
    }
}
