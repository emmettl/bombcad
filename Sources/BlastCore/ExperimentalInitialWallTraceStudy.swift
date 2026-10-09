import Foundation
import simd

/// Instantaneous-limit Gaussian pressure loads. Whole uncut faces supply an independent
/// reference; known sampled pressure isolates quadrature from numerical reconstruction.
/// No gas state is advanced, and this is not a reference for the evolved Euler solution.
public enum ExperimentalInitialWallTraceStudy {
    public struct Loads: Codable, Sendable {
        public let force: SIMD3<Double>
        public let torque: SIMD3<Double>
        public let power: Double
        public let relativeForceError: Double
        public let relativeTorqueError: Double
        public let relativePressureL1: Double
    }
    public struct DiagnosticMode: Codable, Sendable {
        public let kind: String
        public let loads: Loads
        public let minimumPressure: Double
        public let maximumPressure: Double
        public let nonpositivePressureSamples: Int
        public let negativeExcessAreaFraction: Double
        public let outsideStencilAreaFraction: Double
    }
    public struct ReconstructionDiagnostics: Codable, Sendable {
        public let modes: [DiagnosticMode]
        public let meanPressureLimiterFactor: Double
        public let limiterActiveAreaFraction: Double
        public let rankDeficientAreaFraction: Double
        public let centroidDataLimiterFactor: Double
    }
    public struct VolumeBoundDiagnostics: Codable, Sendable {
        public let kind: String
        public let meanFactor: Double
        public let activeAreaFraction: Double
        public let maximumRelativeAverageResidual: Double
        public let maximumRelativeBoundViolation: Double
    }
    public struct VolumeFitDiagnostics: Codable, Sendable {
        public let modes: [DiagnosticMode]
        public let quadraticFallbackAreaFraction: Double
        public let pointQuadraticFallbackAreaFraction: Double
        public let linearFallbackAreaFraction: Double
        public let meanStencilSize: Double
        public let maximumMomentResidual: Double
        public var bounds: [VolumeBoundDiagnostics]? = nil
        public var stencilRings: Int? = nil
    }
    public struct Result: Codable, Sendable {
        public let cellSize: Double
        public let rotation: Double
        public let duration: Double
        public let velocity: SIMD3<Double>
        public let targetPulseEnergy: Double
        public let pulseAmplitude: Double
        public let pulseCentre: SIMD3<Double>
        public let pulseWidth: SIMD3<Double>
        public let boxSize: SIMD3<Double>
        public let bodyCentre: SIMD3<Double>
        public let wallSamples: Int
        public let groups: Int
        public let maximumMembers: Int
        public let referenceForce: SIMD3<Double>
        public let referenceTorque: SIMD3<Double>
        public let referenceOrderDifference: Double
        public let supplied: Loads
        public let constant: Loads
        public let limited: Loads
        public let halfDurationSupplied: Loads
        public let halfDurationConstant: Loads
        public let halfDurationLimited: Loads
        public let computeSeconds: Double
        public var decomposition: ReconstructionDiagnostics? = nil
        public var halfDurationDecomposition: ReconstructionDiagnostics? = nil
        public var volumeFits: VolumeFitDiagnostics? = nil
        public var halfDurationVolumeFits: VolumeFitDiagnostics? = nil
    }
    enum Failure: Error { case invalidConfiguration, invalidReference }
    private struct Probe {
        let supplied: Loads
        let constant: Loads
        let limited: Loads
        let samples: Int
        let groups: Int
        let maximumMembers: Int
        var decomposition: ReconstructionDiagnostics? = nil
        var volumeFits: VolumeFitDiagnostics? = nil
    }
    public static func run(
        cellSizes: [Double] = [0.2, 0.1, 0.05], rotations: [Double] = [0, 0.23],
        targetPulseEnergy: Double = 6400, decompose: Bool = false, volumeFits: Bool = false,
        stencilRings: Int = 2,
        progress: (Result) throws -> Void = { _ in }
    ) throws -> [Result] {
        guard !cellSizes.isEmpty && !rotations.isEmpty, targetPulseEnergy.isFinite && targetPulseEnergy > 0,
            (1...3).contains(stencilRings)
        else {
            throw Failure.invalidConfiguration
        }
        var rows: [Result] = []
        for h in cellSizes {
            for angle in rotations {
                let clock = Date()
                let initial = try ExperimentalMovingLoadStudy.initialState(
                    h: h, angle: angle, targetEnergy: targetPulseEnergy)
                let body = try ExperimentalMovingGroupsStudy.body(angle: angle, time: 0)
                func pressure(_ point: SIMD3<Double>) -> Double {
                    let q =
                        (point - ExperimentalMovingLoadStudy.pulseCentre)
                        / ExperimentalMovingLoadStudy.pulseWidth
                    return initial.amplitude * exp(-0.5 * simd_length_squared(q))
                }
                let low = try BoxSurfacePressureReference.integrate(body: body, order: 16, pressure: pressure)
                let reference = try BoxSurfacePressureReference.integrate(
                    body: body, order: 32, pressure: pressure)
                guard simd_length(reference.force) > 0 && simd_length(reference.torque) > 0 else {
                    throw Failure.invalidReference
                }
                let difference = max(
                    simd_distance(low.force, reference.force) / simd_length(reference.force),
                    simd_distance(low.torque, reference.torque) / simd_length(reference.torque))
                guard difference < 1e-8 else { throw Failure.invalidReference }
                // Small displacement bounds finite-interval contamination. Every case
                // repeats at half duration; interpret these as t=0 limiting traces.
                let dt = h * 1e-9
                let velocity = 100 * ExperimentalMovingGroupsStudy.velocity
                let full = try probe(
                    h: h, angle: angle, body: body, velocity: velocity, duration: dt,
                    initial: initial.cells, reference: reference, pressure: pressure, decompose: decompose,
                    volumeFits: volumeFits, stencilRings: stencilRings)
                let half = try probe(
                    h: h, angle: angle, body: body, velocity: velocity, duration: dt / 2,
                    initial: initial.cells, reference: reference, pressure: pressure, decompose: decompose,
                    volumeFits: volumeFits, stencilRings: stencilRings)
                let row = Result(
                    cellSize: h, rotation: angle, duration: dt, velocity: velocity,
                    targetPulseEnergy: targetPulseEnergy, pulseAmplitude: initial.amplitude,
                    pulseCentre: ExperimentalMovingLoadStudy.pulseCentre,
                    pulseWidth: ExperimentalMovingLoadStudy.pulseWidth,
                    boxSize: body.size, bodyCentre: body.position, wallSamples: full.samples,
                    groups: full.groups,
                    maximumMembers: full.maximumMembers, referenceForce: reference.force,
                    referenceTorque: reference.torque,
                    referenceOrderDifference: difference, supplied: full.supplied, constant: full.constant,
                    limited: full.limited,
                    halfDurationSupplied: half.supplied, halfDurationConstant: half.constant,
                    halfDurationLimited: half.limited,
                    computeSeconds: Date().timeIntervalSince(clock),
                    decomposition: full.decomposition, halfDurationDecomposition: half.decomposition,
                    volumeFits: full.volumeFits, halfDurationVolumeFits: half.volumeFits)
                rows.append(row)
                try progress(row)
            }
        }
        return rows
    }
    private static func probe(
        h: Double, angle: Double, body: RigidBoxBody, velocity: SIMD3<Double>, duration: Double,
        initial: [FractionalGasTransport.Cell], reference: BoxSurfacePressureReference.Load,
        pressure: @escaping (SIMD3<Double>) -> Double, decompose: Bool, volumeFits: Bool, stencilRings: Int
    ) throws -> Probe {
        let domain = try ExperimentalMovingGroupsStudy.domain(
            h: h, angle: angle, start: 0, duration: duration, previous: initial, prescribedBody: body,
            prescribedVelocity: velocity, reconstruct: true, surfaceQuadrature: true)
        let exterior = FractionalGasTransport.Cell(
            volume: 1, density: 1.225, velocity: velocity, pressure: 101325)
        func loads(_ traces: [MovingGroupedGasFlux.InitialWallTrace], known: Bool) throws -> Loads {
            var force = SIMD3<Double>.zero
            var torque = SIMD3<Double>.zero
            var error = 0.0
            var scale = 0.0
            for trace in traces {
                let point = trace.point - trace.time * velocity
                let exact = pressure(point)
                let value: Double
                if known {
                    value = exact
                } else {
                    let wall = try IdealGasWallRiemann.solve(
                        density: trace.state.amount[0] / trace.state.volume, pressure: trace.state.pressure(),
                        normalVelocity: simd_dot(trace.state.velocity - trace.velocity, trace.normal))
                    value = wall.pressure - 101325
                }
                // Ambient pressure integrates to zero on the closed box. Subtract it
                // here to avoid cancellation obscuring the much smaller pulse load.
                let packet = trace.area * value * trace.normal
                force += packet
                torque += simd_cross(point - body.position, packet)
                error += trace.area * abs(value - exact)
                scale += trace.area * exact
            }
            guard scale > 0 else { throw Failure.invalidReference }
            return .init(
                force: force, torque: torque, power: simd_dot(velocity, force),
                relativeForceError: simd_distance(force, reference.force) / simd_length(reference.force),
                relativeTorqueError: simd_distance(torque, reference.torque) / simd_length(reference.torque),
                relativePressureL1: error / scale)
        }
        let constant = try MovingGroupedGasFlux.initialWallTraces(
            domain.plan, exterior: exterior, limited: false)
        let limited = try MovingGroupedGasFlux.initialWallTraces(
            domain.plan, exterior: exterior, limited: true, recordPressureDiagnostics: decompose)
        var decomposition: ReconstructionDiagnostics?
        if decompose {
            let points = domain.plan.oldCentres!
            let pointValues = points.map(pressure)
            let exactGradients = points.indices.map { n in
                -(points[n] - ExperimentalMovingLoadStudy.pulseCentre)
                    / (ExperimentalMovingLoadStudy.pulseWidth * ExperimentalMovingLoadStudy.pulseWidth)
                    * pointValues[n]
            }
            let centroid = try MovingGroupedGasFlux.initialWallTraces(
                domain.plan, exterior: exterior, limited: true, recordPressureDiagnostics: true,
                diagnosticPressureAt: { 101325 + pressure($0) })
            let kinds = [
                "supplied", "constant", "leastSquares", "limited", "centroidConstant",
                "centroidLeastSquares", "centroidLimited", "analyticTaylor", "averageAnalyticGradient",
            ]
            var modes: [DiagnosticMode] = []
            var totalArea = 0.0
            var weightedFactor = 0.0
            var pointFactor = 0.0
            var activeArea = 0.0
            var deficientArea = 0.0
            for n in limited.indices {
                let trace = limited[n]
                let fit = trace.pressureReconstruction!
                totalArea += trace.area
                weightedFactor += trace.area * fit.factor
                pointFactor += trace.area * centroid[n].pressureReconstruction!.factor
                if fit.factor < 1 - 1e-12 { activeArea += trace.area }
                if fit.rankDeficient { deficientArea += trace.area }
            }
            for kind in kinds {
                var force = SIMD3<Double>.zero
                var torque = SIMD3<Double>.zero
                var error = 0.0
                var scale = 0.0
                var negativeArea = 0.0
                var outsideArea = 0.0
                var minimum = Double.infinity
                var maximum = -Double.infinity
                var nonpositive = 0
                for n in limited.indices {
                    let trace = limited[n]
                    let fit = trace.pressureReconstruction!
                    let pointFit = centroid[n].pressureReconstruction!
                    let c = points[trace.cell]
                    let offset = trace.point - c
                    let point = trace.point - trace.time * velocity
                    let exact = pressure(point)
                    let value: Double  // Signed EXCESS pressure; no diagnostic floor or gas advance.
                    switch kind {
                    case "supplied": value = exact
                    case "constant": value = fit.value - 101325
                    case "leastSquares": value = fit.value - 101325 + simd_dot(fit.gradient, offset)
                    case "limited": value = trace.state.pressure() - 101325
                    case "centroidConstant": value = pointValues[trace.cell]
                    case "centroidLeastSquares":
                        value = pointFit.value - 101325 + simd_dot(pointFit.gradient, offset)
                    case "centroidLimited": value = centroid[n].state.pressure() - 101325
                    case "analyticTaylor":
                        value = pointValues[trace.cell] + simd_dot(exactGradients[trace.cell], offset)
                    default: value = fit.value - 101325 + simd_dot(exactGradients[trace.cell], offset)
                    }
                    let absolute = 101325 + value
                    minimum = min(minimum, absolute)
                    maximum = max(maximum, absolute)
                    if absolute <= 0 { nonpositive += 1 }
                    if value < -1e-5 { negativeArea += trace.area }
                    let bounds = kind.hasPrefix("centroid") || kind == "analyticTaylor" ? pointFit : fit
                    let tolerance = 1e-10 * max(abs(bounds.lower), abs(bounds.upper), 1)
                    if absolute < bounds.lower - tolerance || absolute > bounds.upper + tolerance {
                        outsideArea += trace.area
                    }
                    let applied = trace.area * value * trace.normal
                    force += applied
                    torque += simd_cross(point - body.position, applied)
                    error += trace.area * abs(value - exact)
                    scale += trace.area * exact
                }
                modes.append(
                    .init(
                        kind: kind,
                        loads: .init(
                            force: force, torque: torque, power: simd_dot(velocity, force),
                            relativeForceError: simd_distance(force, reference.force)
                                / simd_length(reference.force),
                            relativeTorqueError: simd_distance(torque, reference.torque)
                                / simd_length(reference.torque),
                            relativePressureL1: error / scale),
                        minimumPressure: minimum, maximumPressure: maximum,
                        nonpositivePressureSamples: nonpositive,
                        negativeExcessAreaFraction: negativeArea / totalArea,
                        outsideStencilAreaFraction: outsideArea / totalArea))
            }
            decomposition = .init(
                modes: modes, meanPressureLimiterFactor: weightedFactor / totalArea,
                limiterActiveAreaFraction: activeArea / totalArea,
                rankDeficientAreaFraction: deficientArea / totalArea,
                centroidDataLimiterFactor: pointFactor / totalArea)
        }
        let fits =
            volumeFits
            ? try ExperimentalVolumePressureFitStudy.evaluate(
                plan: domain.plan, body: body, h: h, traces: limited, reference: reference,
                pressure: pressure, stencilRings: stencilRings) : nil
        return try .init(
            supplied: loads(constant, known: true), constant: loads(constant, known: false),
            limited: loads(limited, known: false), samples: limited.count, groups: domain.plan.cells.count,
            maximumMembers: domain.plan.members.map(\.count).max()!, decomposition: decomposition,
            volumeFits: fits)
    }
}
