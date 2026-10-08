import Testing
import simd

@testable import BlastCore

@Suite("Sampled wall pressure loads")
struct SurfaceWallLoadTests {
    @Test("Affine pressure has an analytical patch torque missed by centroid evaluation")
    func patchTorque() throws {
        let geometry = FractionalBoxGeometry(
            try RigidBoxBody(
                mass: 1, size: SIMD3(2, 1, 1), position: SIMD3(-0.5, 0.5, 0.5)))
        let patch = try #require(geometry.wallPatches(lower: .zero, cellSize: 1).first { $0.normal.x > 0.9 })
        let nodes = patch.quadrature
        let walls = nodes.map { node in
            FractionalEulerFlux.Wall(
                cell: 0, normal: -patch.normal, area: node.weight,
                state: .init(volume: 1, density: 1, pressure: 2 + node.point.y))
        }
        let dt = 1e-6
        let result = try FractionalEulerFlux.advanceWithWalls(
            [.init(volume: 1, density: 1, pressure: 2.5)], faces: [], walls: walls, duration: dt)
        let force = result.wallImpulses.reduce(SIMD3<Double>.zero, +) / dt
        let torque = walls.indices.reduce(SIMD3<Double>.zero) {
            $0 + simd_cross(nodes[$1].point - patch.centroid, result.wallImpulses[$1]) / dt
        }
        #expect(simd_length(force - SIMD3(-2.5, 0, 0)) < 1e-12)
        #expect(simd_length(torque - SIMD3(0, 0, 1.0 / 12)) < 1e-12)
        #expect(simd_length(simd_cross(patch.centroid - patch.centroid, force)) == 0)
        #expect(result.wallWork.allSatisfy { $0 == 0 })
    }

    @Test("Sampled clipped boxes match divergence-theorem affine force and torque", arguments: [0.0, 0.23])
    func wholeBox(angle: Double) throws {
        let centre = SIMD3<Double>(1.013, 1.027, 1.041)
        let size = SIMD3<Double>(0.8, 0.6, 0.4)
        let origin = SIMD3<Double>(0.2, -0.3, 0.4)
        let gradient = SIMD3<Double>(230, -170, 310)
        let geometry = FractionalBoxGeometry(
            try RigidBoxBody(
                mass: 1, size: size, position: centre,
                orientation: simd_quatd(angle: angle, axis: simd_normalize(SIMD3(1, 2, 3)))))
        var points: [SIMD3<Double>] = []
        var walls: [FractionalEulerFlux.Wall] = []
        let h = 0.2
        for k in 0..<10 {
            for j in 0..<10 {
                for i in 0..<10 {
                    let lower = h * SIMD3<Double>(Double(i), Double(j), Double(k))
                    for patch in geometry.wallPatches(lower: lower, cellSize: h) {
                        for node in patch.quadrature {
                            points.append(node.point)
                            walls.append(
                                .init(
                                    cell: 0, normal: -patch.normal, area: node.weight,
                                    state: .init(
                                        volume: 1, density: 1.225,
                                        pressure: 101325 + simd_dot(gradient, node.point - centre))))
                        }
                    }
                }
            }
        }
        let dt = 1e-6
        let initial = FractionalGasTransport.Cell(volume: 1, density: 1.225, pressure: 101325)
        let update = try FractionalEulerFlux.advanceWithWalls(
            [initial], faces: [], walls: walls, duration: dt)
        let force = update.wallImpulses.reduce(SIMD3<Double>.zero, +) / dt
        let torque = points.indices.reduce(SIMD3<Double>.zero) {
            $0 + simd_cross(points[$1] - origin, update.wallImpulses[$1]) / dt
        }
        let expected = -(size.x * size.y * size.z) * gradient
        #expect(simd_length(force - expected) < 1e-8)
        #expect(simd_length(torque - simd_cross(centre - origin, expected)) < 1e-8)
        let gasImpulse = SIMD3(
            update.cells[0].amount[1], update.cells[0].amount[2], update.cells[0].amount[3])
        #expect(simd_length(gasImpulse + dt * force) < 1e-12)
        #expect(
            update.cells[0].amount[0] == initial.amount[0] && update.cells[0].amount[4] == initial.amount[4])
    }

    @Test("Grouping preserves sampled boundary ownership and rejects invalid sample measures")
    func samplesValidation() throws {
        let domain = try ExperimentalConnectedGasStudy.domain(
            cellSize: 0.2, rotation: 0.23, surfaceQuadrature: true)
        func plan(_ boundaries: [ConnectedGasGroups.Boundary]) throws -> ConnectedGasGroups.Plan {
            try ConnectedGasGroups.build(
                cells: domain.cells, centres: domain.centres, nominalVolume: 0.008,
                faces: domain.faces, boundaries: boundaries)
        }
        let grouped = try plan(domain.boundaries)
        let expanded = ConnectedGasGroups.sampledBoundaries(grouped.boundaries)
        #expect(expanded.filter { $0.owner == 1 }.count > grouped.boundaries.filter { $0.owner == 1 }.count)
        #expect(expanded.allSatisfy { $0.samples == nil })
        let index = try #require(domain.boundaries.firstIndex { $0.owner == 1 })
        let original = domain.boundaries[index]
        for mode in 0..<6 {
            var boundaries = domain.boundaries
            var samples = try #require(original.samples)
            samples = samples.map { node in
                .init(
                    point: mode == 1 ? node.point + original.normal * 0.01 : node.point,
                    area: mode == 0 ? node.area * 2 : (mode == 2 ? -node.area : node.area))
            }
            if mode == 3 {
                let seed = abs(original.normal.x) < 0.8 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
                let tangent = simd_normalize(simd_cross(original.normal, seed))
                samples = [.init(point: original.centroid + 0.01 * tangent, area: original.area)]
            }
            if mode == 4 { samples = [.init(point: original.centroid, area: .nan)] }
            if mode == 5 { samples = [] }
            boundaries[index] = .init(
                cell: original.cell, area: original.area, normal: original.normal,
                centroid: original.centroid, owner: original.owner, samples: samples)
            #expect(throws: ConnectedGasGroups.Failure.self) { try plan(boundaries) }
        }
    }

    @Test("Uniform gas remains at rest with limited surface samples")
    func uniformSamples() throws {
        let result = try ExperimentalConnectedLoadStudy.run(
            cellSizes: [0.2], rotations: [0.23],
            duration: 0.00005, pulseAmplitude: 0, volumeAverage: true, limited: true, surfaceQuadrature: true)[
                0]
        #expect(simd_length(result.bodyImpulse) < 1e-9)
        #expect(simd_length(result.bodyAngularImpulse) < 1e-9)
        #expect(result.maximumSpeed < 1e-8)
        #expect(abs(result.relativeMassChange) < 1e-12 && abs(result.relativeEnergyChange) < 1e-12)
    }

    @Test("Constant-state transport agrees with centroid loads and limited sampled loads conserve")
    func studyBudgets() throws {
        let reference = try ExperimentalConnectedLoadStudy.run(
            cellSizes: [0.2], rotations: [0.23],
            duration: 0.00005, targetPulseEnergy: 6400, volumeAverage: true)[0]
        let constant = try ExperimentalConnectedLoadStudy.run(
            cellSizes: [0.2], rotations: [0.23],
            duration: 0.00005, targetPulseEnergy: 6400, volumeAverage: true, surfaceQuadrature: true)[0]
        #expect(simd_length(reference.bodyImpulse - constant.bodyImpulse) < 1e-10)
        #expect(simd_length(reference.bodyAngularImpulse - constant.bodyAngularImpulse) < 1e-10)
        let limited = try ExperimentalConnectedLoadStudy.run(
            cellSizes: [0.2], rotations: [0.23],
            duration: 0.00005, targetPulseEnergy: 6400, volumeAverage: true, limited: true,
            surfaceQuadrature: true)[0]
        #expect(
            limited.wallIntegration == "bodySurfaceDegree2"
                && limited.bodyWallSamples > limited.bodyWallPatches)
        #expect(abs(limited.relativeMassChange) < 1e-12 && abs(limited.relativeEnergyChange) < 1e-12)
        #expect(simd_length(limited.momentumBudgetResidual) < 1e-10 && limited.wallWork == 0)
    }
}
