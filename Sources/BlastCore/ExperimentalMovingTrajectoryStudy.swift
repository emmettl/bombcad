import Foundation
import simd

/// Repeated interval geometry, grouping, paired Euler flux and endpoint scatter. The
/// trajectory is prescribed and gas moves with the box at constant pressure. Uniform and
/// analytic density-advection probes share the driver; free-body/nonuniform loads are separate.
public enum ExperimentalMovingTrajectoryStudy {
    public struct Transport: Codable, Sendable {
        /// Extensive L1 mass error divided by the exact excess mass above ambient density.
        public let relativeDensityL1: Double
        /// Maximum density error divided by rho0 times the profile amplitude.
        public let relativeDensityLInf: Double
        public let referenceMass: Double
        public let referenceEnergy: Double
        public let relativeGlobalMassError: Double
        public let referenceQuadratureMassResidual: Double
        public let maximumNewlyWetRelativeDensityError: Double
        public let minimumDensity: Double
    }
    public struct Frame: Codable, Sendable {
        public let time: Double
        public let steps: Int
        public let rejectedSteps: Int
        public let dryToWetCells: Int
        public let wetToDryCells: Int
        public let partitionChangedSteps: Int
        public let maximumRelativeDensityError: Double
        public let maximumRelativePressureError: Double
        public let maximumVelocityError: Double
        public let minimumPressure: Double
        public let massBudgetResidual: Double
        public let momentumBudgetResidual: SIMD3<Double>
        public let energyBudgetResidual: Double
        public let volumeResidual: Double
        public let bodyImpulse: SIMD3<Double>
        public let bodyAngularImpulse: SIMD3<Double>
        public let bodyWork: Double
        public let impulseWorkResidual: Double
        public let transport: Transport?
        public let scatterLimitedGroups: Int
        public let scatterPositivityReducedGroups: Int
        public let scatterRankDeficientGroups: Int
        public let wallSampleFallbacks: Int
    }
    public struct Result: Codable, Sendable {
        public let cellSize: Double
        public let rotation: Double
        public let cfl: Double
        public let startPathTime: Double
        public let duration: Double
        public let velocity: SIMD3<Double>
        public let densityProfile: String
        public let densityAmplitude: Double?
        public let reconstruction: String
        public let timeIntegration: String
        public let wallIntegration: String
        public let displacement: SIMD3<Double>
        public let referenceDryToWetCells: Int
        public let referenceWetToDryCells: Int
        public let maximumMembers: Int
        public let minimumOldGroupFraction: Double
        public let minimumFinalGroupFraction: Double
        public let maximumRelativeGeometryResidual: Double
        public let computeSeconds: Double
        public let frames: [Frame]
    }
    enum Failure: Error { case invalidConfiguration, stepLimit, retryLimit }
    /// Compensated sums keep diagnostic accumulation independent of cell/step count.
    private struct Sum {
        var value = SIMD8<Double>.zero
        private var correction = SIMD8<Double>.zero
        mutating func add(_ packet: SIMD8<Double>) {
            let increment = packet - correction
            let next = value + increment
            correction = (next - value) - increment
            value = next
        }
    }
    private static func total(_ cells: [FractionalGasTransport.Cell]) -> SIMD8<Double> {
        var sum = Sum()
        for cell in cells {
            var packet = cell.amount
            packet[5] = cell.volume  // Diagnostic lane only; stored gas packets retain zero reserved lanes.
            sum.add(packet)
        }
        return sum.value
    }
    public static func run(
        cellSizes: [Double] = [0.2, 0.1], rotations: [Double] = [0, 0.23],
        cfls: [Double] = [0.2], duration: Double = 0.0008, velocityScale: Double = 100,
        nearCrossing: Bool = false, maximumStep: Double = 0.000008,
        limited: Bool = false, secondOrder: Bool = false, surfaceQuadrature: Bool = false,
        progress: (Result) throws -> Void = { _ in }
    ) throws -> [Result] {
        guard duration.isFinite, duration > 0, duration <= 0.1,
            velocityScale.isFinite, velocityScale > 0, velocityScale <= 1000,
            duration * velocityScale <= 0.0800000001, maximumStep.isFinite && maximumStep > 0,
            cfls.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 0.5 }),
            !nearCrossing || (velocityScale == 1 && duration <= 0.0001)
        else { throw Failure.invalidConfiguration }
        var results: [Result] = []
        for h in cellSizes {
            guard h.isFinite, h >= 0.1, h <= 0.2, abs(2 / h - (2 / h).rounded()) < 1e-10 else {
                throw Failure.invalidConfiguration
            }
            for angle in rotations {
                guard angle.isFinite else { throw Failure.invalidConfiguration }
                let start =
                    nearCrossing
                    ? try ExperimentalMovingGroupsStudy.eventTime(h: h, angle: angle, opening: true)
                        - duration / 4
                    : 0
                for cfl in cfls {
                    let result = try solve(
                        h: h, angle: angle, start: start, duration: duration,
                        velocityScale: velocityScale, cfl: cfl, maximumStep: maximumStep, limited: limited,
                        secondOrder: secondOrder, surfaceQuadrature: surfaceQuadrature)
                    results.append(result)
                    try progress(result)
                }
            }
        }
        return results
    }
    /// Independent event-count oracle: a cell is fully inside the translating convex box
    /// on the intersection of six linear time inequalities. No clipped volume or flux is used.
    static func expectedTransitions(
        body: RigidBoxBody, velocity: SIMD3<Double>, cellSize h: Double, duration: Double
    ) -> (opening: Int, closing: Int) {
        let count = Int((2 / h).rounded())
        var opening = 0
        var closing = 0
        for z in 0..<count {
            for y in 0..<count {
                for x in 0..<count {
                    let centre = h * SIMD3(Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5)
                    var low = -Double.infinity
                    var high = Double.infinity
                    for axis in 0..<3 {
                        var unit = SIMD3<Double>.zero
                        unit[axis] = 1
                        for sign in [-1.0, 1.0] {
                            let normal = sign * body.orientation.act(unit)
                            let projected = abs(normal)
                            let residual =
                                simd_dot(normal, centre - body.worldPoint(.zero))
                                + h / 2 * (projected.x + projected.y + projected.z) - body.size[axis] / 2
                            let speed = simd_dot(normal, velocity)
                            if speed > 0 {
                                low = max(low, residual / speed)
                            } else if speed < 0 {
                                high = min(high, residual / speed)
                            } else if residual > 0 {
                                high = -.infinity
                            }
                        }
                    }
                    if max(low, 0) < min(high, duration) {
                        if low > 0 && low < duration { closing += 1 }
                        if high > 0 && high < duration { opening += 1 }
                    }
                }
            }
        }
        return (opening, closing)
    }
    static func solve(
        h: Double, angle: Double, start: Double, duration: Double, velocityScale: Double,
        cfl: Double, maximumStep: Double, reference: AdvectedQuadraticGas? = nil, limited: Bool = false,
        secondOrder: Bool = false, surfaceQuadrature: Bool = false
    ) throws -> Result {
        let clock = Date()
        let velocity = velocityScale * ExperimentalMovingGroupsStudy.velocity
        guard reference == nil || reference!.velocity == velocity else { throw Failure.invalidConfiguration }
        var body = try ExperimentalMovingGroupsStudy.body(angle: angle, time: start)
        let initialBody = body
        let initialPosition = body.position
        let transitions = expectedTransitions(body: body, velocity: velocity, cellSize: h, duration: duration)
        let geometry = FractionalBoxGeometry(body)
        let count = Int((2 / h).rounded())
        var cells: [FractionalGasTransport.Cell] = []
        for z in 0..<count {
            for y in 0..<count {
                for x in 0..<count {
                    let lower = h * SIMD3(Double(x), Double(y), Double(z))
                    let volume = geometry.gasVolume(lower: lower, cellSize: h)
                    if let reference {
                        cells.append(
                            try reference.cell(
                                geometry: geometry, lower: lower, cellSize: h,
                                time: 0, volume: volume))
                    } else {
                        cells.append(
                            .init(volume: volume, density: 1.225, velocity: velocity, pressure: 101325))
                    }
                }
            }
        }
        let before = total(cells)
        var reservoir = Sum()
        var loads = Sum()
        var elapsed = 0.0
        var hint = maximumStep
        var steps = 0
        var rejected = 0
        var opened = 0
        var closed = 0
        var changed = 0
        var maximumMembers = 0
        var minimumOld = Double.infinity
        var minimumFinal = Double.infinity
        var geometryResidual = 0.0
        var densityError = 0.0
        var pressureError = 0.0
        var velocityError = 0.0
        var minimumPressure = Double.infinity
        var lastPartition: [Int]?
        var frames: [Frame] = []
        var newlyWetError = 0.0
        var scatterLimited = 0
        var scatterReduced = 0
        var scatterDeficient = 0
        var wallSampleFallbacks = 0
        for target in [0.25, 0.5, 0.75, 1.0].map({ $0 * duration }) {
            while elapsed < target {
                guard steps < 10000 else { throw Failure.stepLimit }
                var step = min(hint, target - elapsed)
                var accepted = false
                for _ in 0..<24 {
                    let domain = try ExperimentalMovingGroupsStudy.domain(
                        h: h, angle: angle,
                        start: 0, duration: step, previous: cells, prescribedBody: body,
                        prescribedVelocity: velocity, reconstruct: limited,
                        surfaceQuadrature: surfaceQuadrature)
                    do {
                        let r: MovingGroupedGasFlux.Result
                        if let reference {
                            r = try MovingGroupedGasFlux.advance(
                                domain.plan,
                                exteriorAt: { boundary in
                                    try reference.exterior(
                                        boundary: boundary, cellSize: h, start: elapsed, duration: step)
                                }, cfl: cfl, limited: limited,
                                reconstructionExteriorAt: limited
                                    ? { _, point in
                                        .init(
                                            volume: 1, density: reference.density(at: point, time: elapsed),
                                            velocity: velocity, pressure: reference.pressure)
                                    } : nil,
                                reconstructionExteriorAtEnd: limited && secondOrder
                                    ? { _, point in
                                        .init(
                                            volume: 1,
                                            density: reference.density(at: point, time: elapsed + step),
                                            velocity: velocity, pressure: reference.pressure)
                                    } : nil, timeIntegration: secondOrder ? .heun : .euler)
                        } else {
                            r = try MovingGroupedGasFlux.advance(
                                domain.plan,
                                exterior: .init(
                                    volume: 1, density: 1.225, velocity: velocity, pressure: 101325),
                                cfl: cfl,
                                limited: limited, timeIntegration: secondOrder ? .heun : .euler
                            )
                        }
                        let plan = domain.plan
                        let nextBody = body.translated(by: step * velocity)
                        let nextTime = step == target - elapsed ? target : elapsed + step
                        if let reference {
                            let nextGeometry = FractionalBoxGeometry(nextBody)
                            for n in cells.indices where cells[n].volume == 0 && r.cells[n].volume > 0 {
                                let lower =
                                    h
                                    * SIMD3(
                                        Double(n % count), Double((n / count) % count),
                                        Double(n / (count * count)))
                                let exact = try reference.cell(
                                    geometry: nextGeometry, lower: lower,
                                    cellSize: h, time: nextTime, volume: r.cells[n].volume)
                                newlyWetError = max(
                                    newlyWetError, abs(r.cells[n].amount[0] / exact.amount[0] - 1))
                            }
                        }
                        opened +=
                            cells.indices.filter { cells[$0].volume == 0 && r.cells[$0].volume > 0 }.count
                        closed +=
                            cells.indices.filter { cells[$0].volume > 0 && r.cells[$0].volume == 0 }.count
                        let partition = plan.cellToGroup.map { $0 < 0 ? -1 : plan.members[$0].first! }
                        if let lastPartition, lastPartition != partition { changed += 1 }
                        lastPartition = partition
                        maximumMembers = max(maximumMembers, plan.members.map(\.count).max()!)
                        minimumOld = min(minimumOld, plan.cells.map { $0.volume / (h * h * h) }.min()!)
                        minimumFinal = min(minimumFinal, plan.finalVolumes.map { $0 / (h * h * h) }.min()!)
                        geometryResidual = max(geometryResidual, plan.maximumVolumeResidual)
                        scatterLimited += r.scatterLimitedGroups
                        scatterReduced += r.scatterPositivityReducedGroups
                        scatterDeficient += r.scatterRankDeficientGroups
                        wallSampleFallbacks += r.wallSampleFallbacks
                        var packet = SIMD8<Double>.zero
                        for n in r.wallImpulses.indices {
                            let impulse = r.wallImpulses[n]
                            let angular = r.wallMomentImpulses[n] - simd_cross(body.position, impulse)
                            packet += SIMD8(
                                0, impulse.x, impulse.y, impulse.z, r.wallWork[n],
                                angular.x, angular.y, angular.z)
                        }
                        loads.add(packet)
                        reservoir.add(r.reservoirExchange)
                        cells = r.cells
                        body = nextBody
                        elapsed = nextTime
                        steps += 1
                        hint = min(maximumStep, 0.9 * r.maximumStep)
                        for cell in cells where cell.volume > 0 {
                            if reference == nil {
                                densityError = max(
                                    densityError, abs(cell.amount[0] / cell.volume / 1.225 - 1))
                            }
                            pressureError = max(pressureError, abs(cell.pressure() / 101325 - 1))
                            velocityError = max(velocityError, simd_distance(cell.velocity, velocity))
                            minimumPressure = min(minimumPressure, cell.pressure())
                        }
                        accepted = true
                        break
                    } catch FractionalEulerFlux.Failure.unstableStep {
                        rejected += 1
                        step /= 2
                    } catch FractionalGasTransport.Failure.invalidState {
                        rejected += 1
                        step /= 2
                    }
                }
                guard accepted else { throw Failure.retryLimit }
            }
            let after = total(cells)
            var transport: Transport?
            if let reference {
                let measured = try measureTransport(
                    reference: reference, cells: cells, body: body,
                    initialBody: initialBody, h: h, time: elapsed, newlyWetError: newlyWetError, after: after)
                transport = measured.diagnostics
                // Nonuniform density errors are sampled at matched output times; uniform
                // preservation above is sampled after every accepted interval.
                densityError = max(densityError, measured.relativeDensityError)
            }
            let residual = after - before - reservoir.value
            let impulse = SIMD3(loads.value[1], loads.value[2], loads.value[3])
            frames.append(
                Frame(
                    time: elapsed, steps: steps, rejectedSteps: rejected,
                    dryToWetCells: opened, wetToDryCells: closed, partitionChangedSteps: changed,
                    maximumRelativeDensityError: densityError, maximumRelativePressureError: pressureError,
                    maximumVelocityError: velocityError, minimumPressure: minimumPressure,
                    massBudgetResidual: residual[0],
                    momentumBudgetResidual: SIMD3(residual[1], residual[2], residual[3]) + impulse,
                    energyBudgetResidual: residual[4] + loads.value[4], volumeResidual: after[5] - before[5],
                    bodyImpulse: impulse,
                    bodyAngularImpulse: SIMD3(loads.value[5], loads.value[6], loads.value[7]),
                    bodyWork: loads.value[4],
                    impulseWorkResidual: loads.value[4] - simd_dot(velocity, impulse), transport: transport,
                    scatterLimitedGroups: scatterLimited, scatterPositivityReducedGroups: scatterReduced,
                    scatterRankDeficientGroups: scatterDeficient, wallSampleFallbacks: wallSampleFallbacks))
        }
        return Result(
            cellSize: h, rotation: angle, cfl: cfl, startPathTime: start, duration: duration,
            velocity: velocity, densityProfile: reference == nil ? "uniform" : "quadratic-advection",
            densityAmplitude: reference?.amplitude, reconstruction: limited ? "limited" : "constant",
            timeIntegration: secondOrder ? "heun" : "euler",
            wallIntegration: surfaceQuadrature ? "surfaceTimeQuadrature" : "centroid",
            displacement: body.position - initialPosition,
            referenceDryToWetCells: transitions.opening, referenceWetToDryCells: transitions.closing,
            maximumMembers: maximumMembers,
            minimumOldGroupFraction: minimumOld, minimumFinalGroupFraction: minimumFinal,
            maximumRelativeGeometryResidual: geometryResidual,
            computeSeconds: Date().timeIntervalSince(clock), frames: frames)
    }

    private static func measureTransport(
        reference: AdvectedQuadraticGas, cells: [FractionalGasTransport.Cell], body: RigidBoxBody,
        initialBody: RigidBoxBody, h: Double, time: Double, newlyWetError: Double, after: SIMD8<Double>
    ) throws -> (diagnostics: Transport, relativeDensityError: Double) {
        let count = Int((2 / h).rounded())
        let geometry = FractionalBoxGeometry(body)
        var exact = Sum()
        var errors = Sum()
        var maximumError = 0.0
        var relativeError = 0.0
        var minimumDensity = Double.infinity
        for n in cells.indices where cells[n].volume > 0 {
            let lower = h * SIMD3(Double(n % count), Double((n / count) % count), Double(n / (count * count)))
            let expected = try reference.cell(
                geometry: geometry, lower: lower, cellSize: h,
                time: time, volume: cells[n].volume)
            exact.add(expected.amount)
            errors.add(SIMD8(abs(cells[n].amount[0] - expected.amount[0]), 0, 0, 0, 0, 0, 0, 0))
            let density = cells[n].amount[0] / cells[n].volume
            let exactDensity = expected.amount[0] / expected.volume
            maximumError = max(maximumError, abs(density - exactDensity))
            relativeError = max(relativeError, abs(density / exactDensity - 1))
            minimumDensity = min(minimumDensity, density)
        }
        let mass = reference.domainMass(initialBody: initialBody, time: time)
        let solidVolume = body.size.x * body.size.y * body.size.z
        let excess = mass - reference.density * (8 - solidVolume)
        return (
            Transport(
                relativeDensityL1: errors.value[0] / excess,
                relativeDensityLInf: maximumError / (reference.density * reference.amplitude),
                referenceMass: mass,
                referenceEnergy: reference.pressure / (1.4 - 1) * (8 - solidVolume)
                    + 0.5 * simd_length_squared(reference.velocity) * mass,
                relativeGlobalMassError: (after[0] - mass) / excess,
                referenceQuadratureMassResidual: exact.value[0] - mass,
                maximumNewlyWetRelativeDensityError: newlyWetError, minimumDensity: minimumDensity),
            relativeError
        )
    }
}
