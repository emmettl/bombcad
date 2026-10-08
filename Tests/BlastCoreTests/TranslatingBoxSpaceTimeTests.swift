import Testing
import simd

@testable import BlastCore

@Suite("Prescribed translating box space/time geometry")
struct TranslatingBoxSpaceTimeTests {
    @Test("A moving slab integrates area, first moment, volume and signed pressure work")
    func slab() throws {
        let body = try RigidBoxBody(mass: 1, size: SIMD3(repeating: 1), position: SIMD3(-0.25, 0.5, 0.5))
        let velocity = SIMD3<Double>(0.5, 0, 0)
        let sweep = try TranslatingBoxSpaceTimeGeometry(body: body, velocity: velocity)
        let r = try sweep.integrate(lower: .zero, cellSize: 1, duration: 1)
        #expect(abs(r.initialGasVolume - 0.75) < 1e-13)
        #expect(abs(r.finalGasVolume - 0.25) < 1e-13)
        #expect(abs(r.gasVolumeTime - 0.5) < 1e-13)
        #expect(abs(r.walls[1].areaTime - 1) < 1e-13)
        #expect(abs(r.walls[1].timeWeightedArea - 0.5) < 1e-13)
        #expect(simd_length(r.walls[1].firstMomentTime) < 1e-13)
        #expect(abs(r.openFaces[0].areaTime) < 1e-13)
        #expect(abs(r.openFaces[1].areaTime - 1) < 1e-13)
        for side in 2..<6 { #expect(abs(r.openFaces[side].areaTime - 0.5) < 1e-13) }
        #expect(simd_distance(r.openFaces[2].firstMomentTime, SIMD3(11.0 / 96, -0.25, 0)) < 1e-13)
        #expect(simd_distance(r.openFaces[5].firstMomentTime, SIMD3(11.0 / 96, 0, 0.25)) < 1e-13)
        #expect(simd_distance(r.wallAreaVector, SIMD3(-1, 0, 0)) < 1e-13)
        #expect(abs(simd_dot(velocity, r.wallAreaVector) + 0.5) < 1e-13)
        #expect(
            simd_length(
                r.pressureAngularImpulse(
                    cellCentre: SIMD3(repeating: 0.5), initialCentreOfMass: body.position, velocity: velocity)
            ) < 1e-13)
    }

    @Test("Clear endpoints still capture a box passing through the cell")
    func transientIntersection() throws {
        let body = try RigidBoxBody(mass: 1, size: SIMD3(repeating: 0.2), position: SIMD3(-0.5, 0.5, 0.5))
        let r = try TranslatingBoxSpaceTimeGeometry(body: body, velocity: SIMD3(2, 0, 0))
            .integrate(lower: .zero, cellSize: 1, duration: 1)
        #expect(abs(r.initialGasVolume - 1) < 1e-13)
        #expect(abs(r.finalGasVolume - 1) < 1e-13)
        #expect(abs(r.gasVolumeTime - 0.996) < 1e-13)
        #expect(r.walls.reduce(0) { $0 + $1.areaTime } > 0.1)
        #expect(simd_length(r.wallAreaVector) < 1e-13)
        for event in [0.2, 0.3, 0.7, 0.8] {
            #expect(r.eventTimes.contains { abs($0 - event) < 1e-13 })
        }
    }

    @Test("Rotated edge crossings conserve local moments and uniform exact traces across wet/dry cells")
    func rotatedDomain() throws {
        let reports = try ExperimentalTranslatingBoxGeometryStudy.run(cellSizes: [0.2])
        #expect(reports.count == 2)
        for r in reports {
            #expect(r.dryToWetCells > 0)
            #expect(r.wetToDryCells > 0)
            #expect(r.maximumRelativeAreaClosure < 1e-10)
            #expect(r.maximumRelativeMomentClosure < 1e-10)
            #expect(r.maximumRelativeVolumeChangeResidual < 1e-10)
            #expect(r.maximumRelativeSharedAreaResidual < 1e-10)
            #expect(r.maximumRelativeSharedMomentResidual < 1e-10)
            #expect(abs(r.globalInitialVolumeResidual) < 1e-10)
            #expect(abs(r.globalFinalVolumeResidual) < 1e-10)
            #expect(abs(r.globalVolumeTimeResidual) < 1e-10)
            #expect(simd_length(r.uniformPressureBodyImpulse) < 1e-8)
            #expect(simd_length(r.uniformPressureBodyAngularImpulse) < 1e-8)
            #expect(abs(r.uniformPressureBodyWork) < 1e-8)
            #expect(r.maximumRelativeUniformMassResidual < 1e-10)
            #expect(r.maximumRelativeUniformMomentumResidual < 1e-8)
            #expect(r.maximumRelativeUniformEnergyResidual < 1e-10)
            #expect(r.minimumPredictedVolume > -pow(r.cellSize, 3) * 1e-10)
        }
    }

    @Test("Torque follows an offset centre of mass while geometry follows the box centre")
    func offsetCentreOfMass() throws {
        let body = try RigidBoxBody(
            mass: 1, size: SIMD3(repeating: 1), position: SIMD3(-0.25, 0.6, 0.5),
            centreOfMass: SIMD3(0, 0.1, 0), inertia: SIMD3(repeating: 0.2))
        let velocity = SIMD3<Double>(0.5, 0, 0)
        let r = try TranslatingBoxSpaceTimeGeometry(body: body, velocity: velocity)
            .integrate(lower: .zero, cellSize: 1, duration: 1)
        let angular = r.pressureAngularImpulse(
            cellCentre: SIMD3(repeating: 0.5), initialCentreOfMass: body.position, velocity: velocity)
        #expect(simd_distance(angular, SIMD3(0, 0, -0.1)) < 1e-13)
        #expect(abs(r.gasVolumeTime - 0.5) < 1e-13)
    }

    @Test("Nearly parallel plane triples are explicitly unsupported")
    func nearlyParallel() throws {
        let body = try RigidBoxBody(
            mass: 1, size: SIMD3(repeating: 1),
            orientation: simd_quatd(angle: 1e-10, axis: simd_normalize(SIMD3(1, 2, 3))))
        #expect(throws: TranslatingBoxSpaceTimeGeometry.Failure.illConditionedOrientation) {
            try TranslatingBoxSpaceTimeGeometry(body: body, velocity: SIMD3(1, 0, 0))
        }
    }

    @Test("Reversing a rotated path preserves moments and torque about the moving centre")
    func reversedPath() throws {
        let velocity = SIMD3<Double>(0.4, 0.2, -0.1)
        let duration = 0.6
        let body = try RigidBoxBody(
            mass: 1, size: SIMD3(repeating: 0.7), position: SIMD3(0.3, 0.4, 0.55),
            orientation: simd_quatd(angle: 0.23, axis: simd_normalize(SIMD3(1, 2, 3))))
        let finalBody = try RigidBoxBody(
            mass: body.mass, size: body.size, position: body.position + duration * velocity,
            orientation: body.orientation)
        let forward = try TranslatingBoxSpaceTimeGeometry(body: body, velocity: velocity)
            .integrate(lower: .zero, cellSize: 1, duration: duration)
        let reverse = try TranslatingBoxSpaceTimeGeometry(body: finalBody, velocity: -velocity)
            .integrate(lower: .zero, cellSize: 1, duration: duration)
        #expect(abs(forward.gasVolumeTime - reverse.gasVolumeTime) < 1e-12)
        #expect(abs(forward.initialGasVolume - reverse.finalGasVolume) < 1e-12)
        for (a, b) in zip(forward.openFaces + forward.walls, reverse.openFaces + reverse.walls) {
            #expect(abs(a.areaTime - b.areaTime) < 1e-12)
            #expect(simd_distance(a.firstMomentTime, b.firstMomentTime) < 1e-12)
            #expect(abs(a.timeWeightedArea + b.timeWeightedArea - duration * a.areaTime) < 1e-12)
        }
        let forwardTorque = forward.pressureAngularImpulse(
            cellCentre: SIMD3(repeating: 0.5), initialCentreOfMass: body.position, velocity: velocity)
        let reverseTorque = reverse.pressureAngularImpulse(
            cellCentre: SIMD3(repeating: 0.5), initialCentreOfMass: finalBody.position, velocity: -velocity)
        #expect(simd_distance(forwardTorque, reverseTorque) < 1e-12)
        #expect(simd_length(forwardTorque) > 1e-5)
    }

    @Test("A stationary touching wall replaces the coincident open face")
    func stationaryContact() throws {
        let body = try RigidBoxBody(mass: 1, size: SIMD3(repeating: 1), position: SIMD3(-0.5, 0.5, 0.5))
        let r = try TranslatingBoxSpaceTimeGeometry(body: body, velocity: .zero)
            .integrate(lower: .zero, cellSize: 1, duration: 0.3)
        #expect(abs(r.gasVolumeTime - 0.3) < 1e-13)
        #expect(abs(r.openFaces[0].areaTime) < 1e-13)
        #expect(abs(r.walls[1].areaTime - 0.3) < 1e-13)
        #expect(simd_length(r.openAreaVector + r.wallAreaVector) < 1e-13)
    }

    @Test("Study refuses unsupported grids and motion beyond its contained-box envelope")
    func studyConfiguration() throws {
        #expect(throws: ExperimentalTranslatingBoxGeometryStudy.Failure.invalidConfiguration) {
            try ExperimentalTranslatingBoxGeometryStudy.run(cellSizes: [0.3])
        }
        #expect(throws: ExperimentalTranslatingBoxGeometryStudy.Failure.invalidConfiguration) {
            try ExperimentalTranslatingBoxGeometryStudy.run(duration: 0.09)
        }
    }
}
