import Testing
import simd

@testable import BlastCore

@Suite("Fractional rigid-box geometry")
struct FractionalBoxGeometryTests {
    @Test("Event-split translation conserves volume and work for crossings in either direction")
    func eventSplitTranslation() throws {
        let body = try RigidBoxBody(mass: 2, size: SIMD3(repeating: 0.8), position: SIMD3(1, 1, 1))
        for velocity in [SIMD3<Double>(2, 1.7, 0.6), SIMD3(-2, -1.7, -0.6), .zero] {
            for lower in [SIMD3<Double>(1.35, 1.35, 1.35), SIMD3(0.55, 0.55, 0.55)] {
                let r = try TranslatingBoxCellSweep.integrate(
                    body: body, velocity: velocity, lower: lower,
                    cellSize: 0.1, duration: 0.12, pressure: 101325)
                #expect(abs(r.sweptVolume - r.volumeChange) < 1e-12)
                #expect(abs(r.gasWork - 101325 * r.volumeChange) < 1e-8)
                #expect(abs(r.gasWork + r.bodyWork) < 1e-8)
            }
        }
        let rotated = try RigidBoxBody(
            mass: 2, size: SIMD3(repeating: 0.8), position: SIMD3(1, 1, 1),
            orientation: simd_quatd(angle: 0.37, axis: SIMD3(0, 0, 1)))
        #expect(throws: TranslatingBoxCellSweep.Failure.self) {
            try TranslatingBoxCellSweep.integrate(
                body: rotated, velocity: SIMD3(1, 0, 0), lower: .zero,
                cellSize: 0.2, duration: 0.01, pressure: 101325)
        }
    }
    @Test("Moving-wall pressure work is equal and opposite for gas and body")
    func pressureWork() throws {
        let body = try RigidBoxBody(
            mass: 2, size: SIMD3(repeating: 0.8), position: SIMD3(1, 1, 1),
            orientation: simd_quatd(angle: 0.37, axis: simd_normalize(SIMD3(1, 2, 3))))
        let walls = FractionalBoxGeometry(body).wallPatches(lower: SIMD3(1.3, 0.9, 0.9), cellSize: 0.2)
        #expect(!walls.isEmpty)
        let linear = SIMD3<Double>(2, -1, 0.5)
        let spin = SIMD3<Double>(0.7, -0.3, 0.2)
        func velocity(_ point: SIMD3<Double>) -> SIMD3<Double> {
            linear + simd_cross(spin, point - body.position)
        }
        func pressure(_ point: SIMD3<Double>) -> Double {
            101325 + simd_dot(SIMD3<Double>(1000, -200, 300), point)
        }
        for wall in walls {
            let load = wall.pressureLoad(about: body.position, pressure: pressure)
            let bodyPower = simd_dot(load.force, linear) + simd_dot(load.torque, spin)
            #expect(abs(bodyPower + wall.gasPressurePower(velocity: velocity, pressure: pressure)) < 1e-8)
        }
    }

    @Test("Swept-volume study resolves smooth motion and exposes cell-crossing quadrature error")
    func movingVolumes() throws {
        let results = try ExperimentalRigidBoxMotionStudy.run()
        for r in results {
            #expect(abs(r.workBalanceResidual) < 1e-8)
            #expect(abs(r.gasPressureWork - 101325 * r.sweptVolume) < 1e-8)
            if r.integration == .eventSplitGauss {
                #expect(abs(r.volumeResidual) < 1e-12)
                #expect(abs(r.gasPressureWork - r.endpointPressureWork) < 1e-8)
            }
            if r.kind == "ground-gap-opening" {
                #expect(abs(r.volumeResidual) < 1e-12)
                #expect(r.gasPressureWork < 0 && r.bodyPressureWork > 0)
                #expect(abs(r.gasPressureWork - r.endpointPressureWork) < 1e-8)
            }
        }
        for h in [0.1, 0.05] {
            let crossing = results.filter {
                $0.kind == "translation-crossing" && $0.cellSize == h && $0.integration == .midpoint
            }
            #expect(abs(crossing[2].volumeResidual) < abs(crossing[1].volumeResidual))
            #expect(abs(crossing[1].volumeResidual) < abs(crossing[0].volumeResidual))
            #expect(abs(crossing[2].volumeResidual) > 1e-8)
        }
        for h in [0.2, 0.1, 0.05] {
            let rotation = results.filter { $0.kind == "rotation" && $0.cellSize == h }
            #expect(abs(rotation[2].volumeResidual) < abs(rotation[0].volumeResidual))
        }
    }

    @Test(
        "Wall patches balance cell surfaces and integrate analytical pressure loads", arguments: [0.0, 0.37])
    func wallBalances(angle: Double) throws {
        let q = simd_quatd(angle: angle, axis: simd_normalize(SIMD3(1, 2, 3)))
        let offset = SIMD3<Double>(0.1, 0.05, -0.07)
        let geometricCentre = SIMD3<Double>(1, 1, 1)
        let body = try RigidBoxBody(
            mass: 2, size: SIMD3(0.8, 0.6, 0.4),
            position: geometricCentre + q.act(offset), orientation: q,
            centreOfMass: offset, inertia: SIMD3(repeating: 0.2))
        let geometry = FractionalBoxGeometry(body)
        let h = 0.2
        let low = body.corners.reduce(SIMD3<Double>(repeating: .infinity), simd_min)
        let high = body.corners.reduce(SIMD3<Double>(repeating: -.infinity), simd_max)
        let first = SIMD3<Int>((low / h).rounded(.down)) &- 1
        let last = SIMD3<Int>((high / h).rounded(.up)) &+ 1
        var area = 0.0
        var force = SIMD3<Double>.zero
        var torque = SIMD3<Double>.zero
        var gradientForce = SIMD3<Double>.zero
        var gradientTorque = SIMD3<Double>.zero
        let gradient = SIMD3<Double>(1000, -200, 300)
        for k in first.z...last.z {
            for j in first.y...last.y {
                for i in first.x...last.x {
                    let lower = h * SIMD3<Double>(Double(i), Double(j), Double(k))
                    let origin = lower + SIMD3(repeating: h / 2)
                    let walls = geometry.wallPatches(lower: lower, cellSize: h)
                    let faces = geometry.openFacePatches(lower: lower, cellSize: h)
                    var balance = SIMD3<Double>.zero
                    var moment = SIMD3<Double>.zero
                    var volume = 0.0
                    for face in faces {
                        let vector = face.area * face.normal
                        balance += vector
                        moment += simd_cross(face.centroid - origin, vector)
                        volume += simd_dot(face.centroid - origin, vector) / 3
                    }
                    for wall in walls {
                        let vector = wall.area * wall.normal
                        balance -= vector
                        moment -= simd_cross(wall.centroid - origin, vector)
                        volume -= simd_dot(wall.centroid - origin, vector) / 3
                        area += wall.area
                        force -= vector
                        torque -= simd_cross(wall.centroid - body.position, vector)
                        let load = wall.pressureLoad(about: body.position) { 101325 + simd_dot(gradient, $0) }
                        gradientForce += load.force
                        gradientTorque += load.torque
                    }
                    #expect(simd_length(balance) < 1e-11)
                    #expect(simd_length(moment) < 1e-11)
                    let expected = (1 - geometry.solidVolumeFraction(lower: lower, cellSize: h)) * h * h * h
                    #expect(abs(volume - expected) < 1e-11)
                }
            }
        }
        let boxVolume = 0.8 * 0.6 * 0.4
        #expect(abs(area - 2 * (0.8 * 0.6 + 0.6 * 0.4 + 0.4 * 0.8)) < 1e-10)
        #expect(simd_length(force) < 1e-10)
        #expect(simd_length(torque) < 1e-10)
        #expect(simd_length(gradientForce + boxVolume * gradient) < 1e-7)
        let expectedTorque = simd_cross(-q.act(offset), -boxVolume * gradient)
        #expect(simd_length(gradientTorque - expectedTorque) < 1e-7)
    }

    @Test("A grid-aligned wall belongs only to the fluid-side cell")
    func wallOwnership() throws {
        let geometry = FractionalBoxGeometry(
            try RigidBoxBody(mass: 1, size: SIMD3(repeating: 1), position: SIMD3(repeating: 0.5)))
        #expect(geometry.wallPatches(lower: .zero, cellSize: 1).isEmpty)
        let walls = geometry.wallPatches(lower: SIMD3(1, 0, 0), cellSize: 1)
        #expect(walls.count == 1)
        let wall = try #require(walls.first)
        #expect(abs(wall.area - 1) < 1e-12)
        #expect(simd_length(wall.centroid - SIMD3(1, 0.5, 0.5)) < 1e-12)
        #expect(wall.normal == SIMD3(1, 0, 0))
    }

    @Test("Partitioned volume is invariant under translation and rotation", arguments: [0.2, 0.1, 0.05])
    func partitionedVolume(cell: Double) throws {
        for offset in [0.0, 0.017, 0.119] {
            for angle in [0.0, 0.37] {
                let body = try RigidBoxBody(
                    mass: 2, size: SIMD3(repeating: 0.8), position: SIMD3(1 + offset, 1, 1),
                    orientation: simd_quatd(angle: angle, axis: simd_normalize(SIMD3(1, 2, 3))))
                let geometry = FractionalBoxGeometry(body)
                let low = body.corners.reduce(SIMD3<Double>(repeating: .infinity), simd_min)
                let high = body.corners.reduce(SIMD3<Double>(repeating: -.infinity), simd_max)
                let first = SIMD3<Int>((low / cell).rounded(.down))
                let last = SIMD3<Int>((high / cell).rounded(.up))
                var volume = 0.0
                for k in first.z...last.z {
                    for j in first.y...last.y {
                        for i in first.x...last.x {
                            volume +=
                                geometry.solidVolumeFraction(
                                    lower: cell * SIMD3<Double>(Double(i), Double(j), Double(k)),
                                    cellSize: cell)
                                * cell * cell * cell
                        }
                    }
                }
                #expect(abs(volume - 0.512) < 1e-10)
            }
        }
    }

    @Test("A centre-of-mass offset does not move the geometric box")
    func centreOffset() throws {
        let q = simd_quatd(angle: 0.37, axis: simd_normalize(SIMD3(1, 2, 3)))
        let centre = SIMD3<Double>(0.5, 0.5, 0.5)
        let offset = SIMD3<Double>(0.1, 0.2, 0.3)
        let first = FractionalBoxGeometry(
            try RigidBoxBody(mass: 1, size: SIMD3(repeating: 1), position: centre, orientation: q))
        let second = FractionalBoxGeometry(
            try RigidBoxBody(
                mass: 1, size: SIMD3(repeating: 1),
                position: centre + q.act(offset), orientation: q, centreOfMass: offset,
                inertia: SIMD3(repeating: 0.2)))
        #expect(
            abs(
                first.solidVolumeFraction(lower: .zero, cellSize: 1)
                    - second.solidVolumeFraction(lower: .zero, cellSize: 1)) < 1e-12)
        let a = first.openFaceFractions(lower: .zero, cellSize: 1)
        let b = second.openFaceFractions(lower: .zero, cellSize: 1)
        for n in 0..<6 { #expect(abs(a[n] - b[n]) < 1e-12) }
    }

    @Test("Axis-aligned intersections match exact volume and face areas")
    func axisAligned() throws {
        let body = try RigidBoxBody(mass: 1, size: SIMD3(repeating: 1), position: SIMD3(repeating: 0.5))
        let geometry = FractionalBoxGeometry(body)
        #expect(geometry.solidVolumeFraction(lower: .zero, cellSize: 1) == 1)
        #expect(geometry.solidVolumeFraction(lower: SIMD3(repeating: 2), cellSize: 1) == 0)
        #expect(abs(geometry.solidVolumeFraction(lower: SIMD3(repeating: -0.5), cellSize: 1) - 0.125) < 1e-12)
        let face = geometry.openFaceFractions(lower: SIMD3(repeating: -0.5), cellSize: 1)
        for n in 0..<6 { #expect(abs(face[n] - (n & 1 == 0 ? 1 : 0.75)) < 1e-12) }
    }

    @Test("A 45-degree cube has the analytical octagonal intersection")
    func rotatedIntersection() throws {
        let body = try RigidBoxBody(
            mass: 1, size: SIMD3(repeating: 1), position: SIMD3(repeating: 0.5),
            orientation: simd_quatd(angle: .pi / 4, axis: SIMD3(0, 0, 1)))
        let geometry = FractionalBoxGeometry(body)
        let fraction = 2 * sqrt(2.0) - 2
        #expect(abs(geometry.solidVolumeFraction(lower: .zero, cellSize: 1) - fraction) < 1e-12)
        let faces = geometry.openFaceFractions(lower: .zero, cellSize: 1)
        for n in 0..<4 { #expect(abs(faces[n] - (2 - sqrt(2.0))) < 1e-12) }
        for n in 4..<6 { #expect(abs(faces[n] - (1 - fraction)) < 1e-12) }
    }

    @Test("Adjacent cells agree on face apertures, including exact face contact")
    func sharedFaces() throws {
        let body = try RigidBoxBody(
            mass: 1, size: SIMD3(repeating: 0.8), position: SIMD3(0.41, 0.43, 0.45),
            orientation: simd_quatd(angle: 0.37, axis: simd_normalize(SIMD3(1, 2, 3))))
        let geometry = FractionalBoxGeometry(body)
        let lower = SIMD3<Double>(0.3, 0.3, 0.3)
        let faces = geometry.openFaceFractions(lower: lower, cellSize: 0.2)
        for axis in 0..<3 {
            var adjacent = lower
            adjacent[axis] += 0.2
            #expect(
                abs(
                    faces[2 * axis + 1] - geometry.openFaceFractions(lower: adjacent, cellSize: 0.2)[2 * axis]
                ) < 1e-12)
        }
        let touching = FractionalBoxGeometry(
            try RigidBoxBody(mass: 1, size: SIMD3(repeating: 1), position: SIMD3(repeating: 0.5)))
        #expect(abs(touching.solidVolumeFraction(lower: SIMD3(-1, 0, 0), cellSize: 1)) < 1e-12)
        #expect(abs(touching.openFaceFractions(lower: SIMD3(-1, 0, 0), cellSize: 1)[1]) < 1e-12)
    }

    @Test("Under-box air gaps remain measurable far below one cell")
    func thinGroundGaps() throws {
        for gap in [0.0, 0.00001, 0.001, 0.025] {
            let body = try RigidBoxBody(
                mass: 2, size: SIMD3(repeating: 0.8), position: SIMD3(2, 2, 0.4 + gap))
            let geometry = FractionalBoxGeometry(body)
            let lower = SIMD3<Double>(1.8, 1.8, 0)
            #expect(abs(1 - geometry.solidVolumeFraction(lower: lower, cellSize: 0.2) - gap / 0.2) < 1e-12)
            let faces = geometry.openFaceFractions(lower: lower, cellSize: 0.2)
            for n in 0..<4 { #expect(abs(faces[n] - gap / 0.2) < 1e-12) }
            #expect(abs(faces[4] - (gap == 0 ? 0 : 1)) < 1e-12)
        }
    }
}
