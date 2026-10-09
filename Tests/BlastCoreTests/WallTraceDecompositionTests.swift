import Testing
import simd

@testable import BlastCore

@Suite("Initial wall trace error decomposition")
struct WallTraceDecompositionTests {
    @Test("Pressure diagnostics preserve bounded traces and expose the actual raw fit and factor")
    func actualFit() throws {
        let centres = [
            SIMD3<Double>.zero, SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0),
            SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1),
        ]
        let p = [2.0, 100000, 1, 4000, 0.1, 80000, 3]
        let cells = p.map { FractionalGasTransport.Cell(volume: 1, density: 1, pressure: $0) }
        let faces = (1..<7).map {
            ConnectedGasGroups.Face(a: 0, b: $0, area: 1, normal: centres[$0], centroid: centres[$0] / 2)
        }
        let point = SIMD3<Double>(10, 3, -4)
        let geometry = try LimitedGroupedGasFlux.Geometry(
            centres: centres, faces: faces,
            boundaries: [.init(cell: 0, area: 1, normal: SIMD3(1, 0, 0), centroid: point)])
        let plain = try geometry.traces(cells)
        let recorded = try geometry.traces(cells, recordPressureDiagnostics: true)
        #expect(plain.pressureDiagnostics == nil)
        for (a, b) in zip(plain.faces, recorded.faces) {
            #expect(
                a.leftState!.amount == b.leftState!.amount && a.rightState!.amount == b.rightState!.amount)
        }
        #expect(plain.walls[0].state!.amount == recorded.walls[0].state!.amount)
        let fit = recorded.pressureDiagnostics![0]
        let exact = SIMD3<Double>((p[1] - p[2]) / 2, (p[3] - p[4]) / 2, (p[5] - p[6]) / 2)
        #expect(simd_distance(fit.gradient, exact) < 1e-10 && !fit.rankDeficient)
        #expect(fit.factor >= 0 && fit.factor < 1)
        let raw = fit.value + simd_dot(fit.gradient, point)
        #expect(raw > fit.upper)
        let bounded = min(fit.upper, max(fit.lower, fit.value + fit.factor * simd_dot(fit.gradient, point)))
        #expect(abs(recorded.walls[0].state!.pressure() - bounded) < 1e-10)
    }

    @Test("Rank-deficient diagnostics retain the constant-state policy")
    func rank() throws {
        let cells = [2.0, 5.0].map { FractionalGasTransport.Cell(volume: 1, density: 1, pressure: $0) }
        let g = try LimitedGroupedGasFlux.Geometry(
            centres: [.zero, SIMD3(1, 0, 0)],
            faces: [.init(a: 0, b: 1, area: 1, normal: SIMD3(1, 0, 0), centroid: SIMD3(0.5, 0, 0))],
            boundaries: [])
        let traces = try g.traces(cells, recordPressureDiagnostics: true)
        #expect(traces.pressureDiagnostics!.allSatisfy { $0.rankDeficient && $0.gradient == .zero })
        #expect(traces.faces[0].leftState!.amount == cells[0].amount)
    }

    @Test("Point-pressure substitution is read-only and does not change accepted inventories or later traces")
    func readOnly() throws {
        let initial = try ExperimentalMovingLoadStudy.initialState(h: 0.2, angle: 0.23, targetEnergy: 6400)
        let d = try ExperimentalMovingGroupsStudy.domain(
            h: 0.2, angle: 0.23, start: 0, duration: 2e-10,
            previous: initial.cells, prescribedVelocity: SIMD3(300, 100, -40), reconstruct: true,
            surfaceQuadrature: true)
        let old = d.plan.cells.map(\.amount)
        let exterior = FractionalGasTransport.Cell(
            volume: 1, density: 1.225, velocity: d.plan.velocity, pressure: 101325)
        let original = try MovingGroupedGasFlux.initialWallTraces(d.plan, exterior: exterior, limited: true)
        let modified = try MovingGroupedGasFlux.initialWallTraces(
            d.plan, exterior: exterior, limited: true,
            recordPressureDiagnostics: true,
            diagnosticPressureAt: { 101325 + 20 * $0.x - 10 * $0.y + 30 * $0.z })
        for trace in modified {
            let c = d.plan.oldCentres![trace.cell]
            #expect(
                abs(trace.pressureReconstruction!.value - (101325 + 20 * c.x - 10 * c.y + 30 * c.z)) < 1e-8)
        }
        #expect(d.plan.cells.map(\.amount) == old)
        let after = try MovingGroupedGasFlux.initialWallTraces(d.plan, exterior: exterior, limited: true)
        #expect(zip(original, after).allSatisfy { $0.state.amount == $1.state.amount })
        #expect(throws: MovingConnectedGasGroups.Failure.invalidState) {
            try MovingGroupedGasFlux.initialWallTraces(
                d.plan, exterior: exterior, limited: true,
                diagnosticPressureAt: { _ in -1 })
        }
    }

    @Test(
        "Analytic-gradient mode agrees with an independent finite-difference gradient of the pressure field")
    func gradientOracle() throws {
        let initial = try ExperimentalMovingLoadStudy.initialState(h: 0.2, angle: 0.23, targetEnergy: 6400)
        let d = try ExperimentalMovingGroupsStudy.domain(
            h: 0.2, angle: 0.23, start: 0, duration: 2e-10,
            previous: initial.cells, prescribedVelocity: SIMD3(300, 100, -40), reconstruct: true,
            surfaceQuadrature: true)
        let exterior = FractionalGasTransport.Cell(
            volume: 1, density: 1.225, velocity: d.plan.velocity, pressure: 101325)
        let traces = try MovingGroupedGasFlux.initialWallTraces(d.plan, exterior: exterior, limited: true)
        func pressure(_ point: SIMD3<Double>) -> Double {
            let q = (point - ExperimentalMovingLoadStudy.pulseCentre) / ExperimentalMovingLoadStudy.pulseWidth
            return initial.amplitude * exp(-0.5 * simd_length_squared(q))
        }
        var force = SIMD3<Double>.zero
        var torque = SIMD3<Double>.zero
        for trace in traces {
            let c = d.plan.oldCentres![trace.cell]
            var gradient = SIMD3<Double>.zero
            for axis in 0..<3 {
                var delta = SIMD3<Double>.zero
                delta[axis] = 1e-6
                gradient[axis] = (pressure(c + delta) - pressure(c - delta)) / 2e-6
            }
            let value = d.plan.cells[trace.cell].pressure() - 101325 + simd_dot(gradient, trace.point - c)
            let applied = trace.area * value * trace.normal
            force += applied
            torque += simd_cross(trace.point - trace.time * d.plan.velocity - d.body.position, applied)
        }
        let result = try ExperimentalInitialWallTraceStudy.run(
            cellSizes: [0.2], rotations: [0.23], decompose: true)[0]
        let oracle = result.decomposition!.modes.first { $0.kind == "averageAnalyticGradient" }!.loads
        #expect(simd_distance(force, oracle.force) < 1e-4)
        #expect(simd_distance(torque, oracle.torque) < 1e-4)
    }

    @Test("Controlled modes retain baseline loads and separate fitting, bounds and local curvature")
    func controlledModes() throws {
        let rows = try ExperimentalInitialWallTraceStudy.run(cellSizes: [0.2, 0.1], decompose: true)
        for r in rows {
            let d = r.decomposition!
            #expect(d.modes.count == 9)
            #expect(d.meanPressureLimiterFactor >= 0 && d.meanPressureLimiterFactor <= 1)
            #expect(d.limiterActiveAreaFraction >= 0 && d.limiterActiveAreaFraction <= 1)
            let modes = Dictionary(uniqueKeysWithValues: d.modes.map { ($0.kind, $0) })
            #expect(simd_distance(modes["limited"]!.loads.force, r.limited.force) < 1e-8)
            #expect(simd_distance(modes["constant"]!.loads.force, r.constant.force) < 1e-8)
            #expect(modes["leastSquares"]!.outsideStencilAreaFraction > 0)
            #expect(modes["limited"]!.outsideStencilAreaFraction < 1e-8)
            for (full, half) in zip(d.modes, r.halfDurationDecomposition!.modes) {
                #expect(
                    full.kind == half.kind && full.minimumPressure.isFinite && full.maximumPressure.isFinite)
                #expect(full.negativeExcessAreaFraction >= 0 && full.negativeExcessAreaFraction <= 1)
                #expect(
                    simd_distance(full.loads.force, half.loads.force) / simd_length(r.referenceForce) < 1e-5)
                #expect(
                    simd_distance(full.loads.torque, half.loads.torque) / simd_length(r.referenceTorque)
                        < 1e-5)
            }
        }
    }
}
