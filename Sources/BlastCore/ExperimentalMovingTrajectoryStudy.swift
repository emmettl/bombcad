import Foundation
import simd

/// Repeated interval geometry, grouping, paired Euler flux and endpoint scatter. The
/// trajectory is prescribed and gas initially moves with the box; this is a constant-state
/// and cumulative-budget stress test, not free-body or nonuniform-load validation.
public enum ExperimentalMovingTrajectoryStudy {
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
    }
    public struct Result: Codable, Sendable {
        public let cellSize: Double
        public let rotation: Double
        public let cfl: Double
        public let startPathTime: Double
        public let duration: Double
        public let velocity: SIMD3<Double>
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
                        velocityScale: velocityScale, cfl: cfl, maximumStep: maximumStep)
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
    private static func solve(
        h: Double, angle: Double, start: Double, duration: Double, velocityScale: Double,
        cfl: Double, maximumStep: Double
    ) throws -> Result {
        let clock = Date()
        let velocity = velocityScale * ExperimentalMovingGroupsStudy.velocity
        var body = try ExperimentalMovingGroupsStudy.body(angle: angle, time: start)
        let initialPosition = body.position
        let reference = expectedTransitions(body: body, velocity: velocity, cellSize: h, duration: duration)
        let geometry = FractionalBoxGeometry(body)
        let count = Int((2 / h).rounded())
        var cells: [FractionalGasTransport.Cell] = []
        for z in 0..<count {
            for y in 0..<count {
                for x in 0..<count {
                    cells.append(
                        .init(
                            volume: geometry.gasVolume(
                                lower: h * SIMD3(Double(x), Double(y), Double(z)), cellSize: h),
                            density: 1.225, velocity: velocity, pressure: 101325))
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
        for target in [0.25, 0.5, 0.75, 1.0].map({ $0 * duration }) {
            while elapsed < target {
                guard steps < 10000 else { throw Failure.stepLimit }
                var step = min(hint, target - elapsed)
                var accepted = false
                for _ in 0..<24 {
                    let domain = try ExperimentalMovingGroupsStudy.domain(
                        h: h, angle: angle,
                        start: 0, duration: step, previous: cells, prescribedBody: body,
                        prescribedVelocity: velocity)
                    do {
                        let r = try MovingGroupedGasFlux.advance(
                            domain.plan,
                            exterior: .init(volume: 1, density: 1.225, velocity: velocity, pressure: 101325),
                            cfl: cfl)
                        let plan = domain.plan
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
                        var packet = SIMD8<Double>.zero
                        for (n, boundary) in plan.boundaries.filter({ $0.geometry.owner == 1 }).enumerated() {
                            let impulse = r.wallImpulses[n]
                            let angular = simd_cross(
                                boundary.geometry.centroid - body.position
                                    - boundary.meanTime * velocity, impulse)
                            packet += SIMD8(
                                0, impulse.x, impulse.y, impulse.z, r.wallWork[n],
                                angular.x, angular.y, angular.z)
                        }
                        loads.add(packet)
                        reservoir.add(r.reservoirExchange)
                        cells = r.cells
                        body = body.translated(by: step * velocity)
                        elapsed = step == target - elapsed ? target : elapsed + step
                        steps += 1
                        hint = min(maximumStep, 0.9 * r.maximumStep)
                        for cell in cells where cell.volume > 0 {
                            densityError = max(densityError, abs(cell.amount[0] / cell.volume / 1.225 - 1))
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
                    impulseWorkResidual: loads.value[4] - simd_dot(velocity, impulse)))
        }
        return Result(
            cellSize: h, rotation: angle, cfl: cfl, startPathTime: start, duration: duration,
            velocity: velocity, displacement: body.position - initialPosition,
            referenceDryToWetCells: reference.opening, referenceWetToDryCells: reference.closing,
            maximumMembers: maximumMembers,
            minimumOldGroupFraction: minimumOld, minimumFinalGroupFraction: minimumFinal,
            maximumRelativeGeometryResidual: geometryResidual,
            computeSeconds: Date().timeIntervalSince(clock), frames: frames)
    }
}
