import Foundation
import Testing
import simd

@testable import BlastCore

@Suite("Independent initial wall pressure traces")
struct InitialWallTraceTests {
    @Test("Positive Gauss rule reproduces polynomial moments independently")
    func gaussMoments() throws {
        let rule = try BoxSurfacePressureReference.rule(order: 8)
        #expect(rule.allSatisfy { $0.weight > 0 && abs($0.point) < 1 })
        for degree in 0..<16 {
            let value = rule.reduce(0) { $0 + $1.weight * pow($1.point, Double(degree)) }
            let exact = degree % 2 == 0 ? 2 / Double(degree + 1) : 0
            #expect(abs(value - exact) < 1e-13)
        }
        #expect(throws: BoxSurfacePressureReference.Failure.invalidOrder) {
            try BoxSurfacePressureReference.rule(order: 1)
        }
    }

    @Test("Aligned Gaussian surface loads agree with closed-form erf and first moments")
    func gaussian() throws {
        let body = try ExperimentalMovingGroupsStudy.body(angle: 0, time: 0)
        let centre = ExperimentalMovingLoadStudy.pulseCentre
        let width = ExperimentalMovingLoadStudy.pulseWidth
        let amplitude = 42000.0
        let low = body.position - body.size / 2
        let high = body.position + body.size / 2
        var integral = SIMD3<Double>.zero
        var moment = SIMD3<Double>.zero
        func gaussian(_ x: Double, _ axis: Int) -> Double {
            exp(-0.5 * pow((x - centre[axis]) / width[axis], 2))
        }
        for axis in 0..<3 {
            integral[axis] =
                width[axis] * sqrt(.pi / 2)
                * (erf((high[axis] - centre[axis]) / (sqrt(2) * width[axis]))
                    - erf((low[axis] - centre[axis]) / (sqrt(2) * width[axis])))
            moment[axis] =
                (centre[axis] - body.position[axis]) * integral[axis]
                + width[axis] * width[axis] * (gaussian(low[axis], axis) - gaussian(high[axis], axis))
        }
        var force = SIMD3<Double>.zero
        var torque = SIMD3<Double>.zero
        for axis in 0..<3 {
            let a = (axis + 1) % 3
            let b = (axis + 2) % 3
            for sign in [-1.0, 1.0] {
                let face = body.position[axis] + sign * body.size[axis] / 2
                let p = amplitude * gaussian(face, axis)
                var normal = SIMD3<Double>.zero
                normal[axis] = sign
                force -= p * integral[a] * integral[b] * normal
                var weightedPosition = SIMD3<Double>.zero
                weightedPosition[axis] = sign * body.size[axis] / 2 * integral[a] * integral[b]
                weightedPosition[a] = moment[a] * integral[b]
                weightedPosition[b] = moment[b] * integral[a]
                torque -= p * simd_cross(weightedPosition, normal)
            }
        }
        let load = try BoxSurfacePressureReference.integrate(body: body, order: 32) { point in
            let q = (point - centre) / width
            return amplitude * exp(-0.5 * simd_length_squared(q))
        }
        #expect(simd_distance(load.force, force) / simd_length(force) < 1e-12)
        #expect(simd_distance(load.torque, torque) / simd_length(torque) < 1e-12)
    }

    @Test("Rotated affine pressure reproduces divergence-theorem force and offset-COM torque")
    func affine() throws {
        let body = try RigidBoxBody(
            mass: 2, size: SIMD3(0.8, 0.6, 0.4), position: SIMD3(1.013, 1.027, 1.041),
            orientation: simd_quatd(angle: 0.23, axis: simd_normalize(SIMD3(1, 2, 3))),
            centreOfMass: SIMD3(0.07, -0.04, 0.03), inertia: SIMD3(0.1, 0.15, 0.2))
        let gradient = SIMD3<Double>(230, -170, 310)
        let exact = -(body.size.x * body.size.y * body.size.z) * gradient
        let load = try BoxSurfacePressureReference.integrate(body: body, order: 4) { point in
            101325 + simd_dot(gradient, point - body.position)
        }
        #expect(simd_distance(load.force, exact) < 1e-8)
        #expect(simd_distance(load.torque, simd_cross(body.worldPoint(.zero) - body.position, exact)) < 1e-8)
        #expect(throws: BoxSurfacePressureReference.Failure.invalidPressure) {
            try BoxSurfacePressureReference.integrate(body: body, order: 4) { _ in Double.nan }
        }
    }

    @Test("Diagnostic traces reproduce the actual Euler wall packets before any gas advance")
    func sameNumericalTraces() throws {
        let initial = try ExperimentalMovingLoadStudy.initialState(h: 0.2, angle: 0.23, targetEnergy: 6400)
        let velocity = SIMD3<Double>(300, 100, -40)
        let dt = 2e-10
        let domain = try ExperimentalMovingGroupsStudy.domain(
            h: 0.2, angle: 0.23, start: 0, duration: dt,
            previous: initial.cells, prescribedVelocity: velocity,
            reconstruct: true, surfaceQuadrature: true)
        let exterior = FractionalGasTransport.Cell(
            volume: 1, density: 1.225, velocity: velocity, pressure: 101325)
        for limited in [false, true] {
            let traces = try MovingGroupedGasFlux.initialWallTraces(
                domain.plan, exterior: exterior, limited: limited)
            var force = SIMD3<Double>.zero
            var torque = SIMD3<Double>.zero
            for trace in traces {
                let state = try IdealGasWallRiemann.solve(
                    density: trace.state.amount[0] / trace.state.volume,
                    pressure: trace.state.pressure(),
                    normalVelocity: simd_dot(trace.state.velocity - trace.velocity, trace.normal))
                let applied = trace.area * state.pressure * trace.normal
                force += applied
                torque += simd_cross(trace.point - trace.time * velocity - domain.body.position, applied)
            }
            let update = try MovingGroupedGasFlux.advance(domain.plan, exterior: exterior, limited: limited)
            let impulse = update.wallImpulses.reduce(SIMD3<Double>.zero, +)
            let angular = update.wallMomentImpulses.indices.reduce(SIMD3<Double>.zero) {
                $0 + update.wallMomentImpulses[$1] - simd_cross(domain.body.position, update.wallImpulses[$1])
            }
            #expect(simd_distance(force, impulse / dt) < 1e-7)
            #expect(simd_distance(torque, angular / dt) < 1e-7)
        }
    }

    @Test("Probe separates supplied pressure from numerical traces with negligible duration effects")
    func probe() throws {
        let rows = try ExperimentalInitialWallTraceStudy.run(cellSizes: [0.2, 0.1])
        #expect(rows.count == 4)
        for r in rows {
            #expect(r.referenceOrderDifference < 1e-8)
            #expect(r.supplied.relativeForceError < 0.05 && r.supplied.relativeTorqueError < 0.05)
            #expect(r.supplied.relativeForceError < r.limited.relativeForceError)
            #expect(r.supplied.relativePressureL1 == 0 && r.limited.relativePressureL1 > 0)
            #expect(
                simd_distance(r.limited.force, r.halfDurationLimited.force) / simd_length(r.referenceForce)
                    < 1e-5)
            #expect(
                simd_distance(r.limited.torque, r.halfDurationLimited.torque) / simd_length(r.referenceTorque)
                    < 1e-5)
        }
    }
}
