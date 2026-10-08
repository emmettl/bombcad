import Foundation
import simd

/// Exact normal-shock wall-load history versus stationary 3D reference transport in a narrow
/// slip-wall channel. Three cells across each transverse axis provide full-rank stencils.
public enum ExperimentalWallReflectionStudy {
    public struct Frame: Codable, Sendable {
        public let time: Double
        public let arrivalFraction: Double
        public let excessImpulse: Double
        public let exactExcessImpulse: Double
        /// Error normalized by total exact excess impulse over the run, including at arrival.
        public let impulseError: Double
    }
    public struct Result: Codable, Sendable {
        public let cellLength: Double
        public let cfl: Double
        public let mach: Double
        public let transport: String
        public let arrivalTime: Double
        public let duration: Double
        public let interactionTime: Double
        public let reflectedPressure: Double
        public let steps: Int
        public let rejectedSteps: Int
        public let relativePressureHistoryL1: Double
        public let relativeMassChange: Double
        public let relativeEnergyChange: Double
        public let momentumBudgetResidual: SIMD3<Double>
        public let frames: [Frame]
    }
    enum Failure: Error { case invalidConfiguration, stepLimit }
    public static func run(
        cellLengths: [Double] = [0.1, 0.05, 0.025, 0.0125],
        cfls: [Double] = [0.2, 0.1], machNumbers: [Double] = [1.2, 2], limited: Bool = false,
        progress: (Result) throws -> Void = { _ in }
    ) throws -> [Result] {
        guard
            cellLengths.allSatisfy({
                $0.isFinite && $0 > 0 && 2 / $0 <= 400 && abs(2 / $0 - (2 / $0).rounded()) < 1e-10
            }),
            cfls.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 0.5 })
        else { throw Failure.invalidConfiguration }
        var results: [Result] = []
        for h in cellLengths {
            for mach in machNumbers {
                let reference = try NormalShockReflection(mach: mach)
                let duration = 1.4 * reference.arrivalTime
                guard duration < reference.interactionTime else { throw Failure.invalidConfiguration }
                let n = Int((2 / h).rounded())
                let transverse = 3
                let dy = 0.1
                let area = Double(transverse * transverse) * dy * dy
                func index(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * transverse + j) * n + i }
                var initial: [FractionalGasTransport.Cell] = []
                var centres: [SIMD3<Double>] = []
                var faces: [ConnectedGasGroups.Face] = []
                var boundaries: [ConnectedGasGroups.Boundary] = []
                for k in 0..<transverse {
                    for j in 0..<transverse {
                        for i in 0..<n {
                            let low = SIMD3<Double>(Double(i) * h, Double(j) * dy, Double(k) * dy)
                            let sizes = SIMD3<Double>(h, dy, dy)
                            let centre = low + sizes / 2
                            centres.append(centre)
                            initial.append(
                                try reference.cell(lower: low.x, upper: low.x + h, time: 0, area: dy * dy))
                            let a = index(i, j, k)
                            for axis in 0..<3 {
                                var normal = SIMD3<Double>.zero
                                normal[axis] = 1
                                let patchArea = axis == 0 ? dy * dy : h * dy
                                let coordinates = [i, j, k]
                                let counts = [n, transverse, transverse]
                                if coordinates[axis] + 1 < counts[axis] {
                                    var next = coordinates
                                    next[axis] += 1
                                    faces.append(
                                        .init(
                                            a: a, b: index(next[0], next[1], next[2]), area: patchArea,
                                            normal: normal, centroid: centre + normal * sizes[axis] / 2))
                                } else {
                                    boundaries.append(
                                        .init(
                                            cell: a, area: patchArea, normal: normal,
                                            centroid: centre + normal * sizes[axis] / 2))
                                }
                                if coordinates[axis] == 0 {
                                    boundaries.append(
                                        .init(
                                            cell: a, area: patchArea, normal: -normal,
                                            centroid: centre - normal * sizes[axis] / 2,
                                            owner: axis == 0 ? 1 : 0))
                                }
                            }
                        }
                    }
                }
                let geometry = try LimitedGroupedGasFlux.Geometry(
                    centres: centres, faces: faces, boundaries: boundaries)
                let constantFaces = faces.map {
                    FractionalEulerFlux.Face(a: $0.a, b: $0.b, normal: $0.normal, area: $0.area)
                }
                let constantWalls = boundaries.map {
                    FractionalEulerFlux.Wall(cell: $0.cell, normal: $0.normal, area: $0.area)
                }
                let before = total(initial)
                let exactFinal =
                    try reference.wallImpulse(time: duration, area: area) - area * reference.pressure
                    * duration
                for cfl in cfls {
                    var cells = initial
                    var elapsed = 0.0
                    var steps = 0
                    var rejected = 0
                    var wallImpulse = SIMD3<Double>.zero
                    var reflectingImpulse = 0.0
                    var historyError = 0.0
                    var frames: [Frame] = []
                    for fraction in [0.8, 1.0, 1.2, 1.4] {
                        let target = fraction * reference.arrivalTime
                        while elapsed < target {
                            let traces = limited ? try geometry.traces(cells) : nil
                            let limit = try FractionalEulerFlux.maximumStep(
                                cells, faces: traces?.faces ?? constantFaces,
                                walls: traces?.walls ?? constantWalls, cfl: cfl)
                            var dt = min(0.99 * limit, target - elapsed)
                            guard steps < 100000 && dt > 0 && elapsed + dt > elapsed else {
                                throw Failure.stepLimit
                            }
                            let update: FractionalEulerFlux.Result
                            if let traces {
                                var accepted: FractionalEulerFlux.Result?
                                for _ in 0..<24 {
                                    do {
                                        accepted = try geometry.advance(
                                            cells, traces: traces, duration: dt, cfl: cfl)
                                        break
                                    } catch LimitedGroupedGasFlux.Failure.stageLimit(let allowed) {
                                        dt = 0.99 * allowed
                                    } catch FractionalGasTransport.Failure.invalidState { dt /= 2 }
                                    rejected += 1
                                    guard dt > 0 && elapsed + dt > elapsed else { throw Failure.stepLimit }
                                }
                                guard let accepted else { throw Failure.stepLimit }
                                update = accepted
                            } else {
                                update = try FractionalEulerFlux.advanceWithWalls(
                                    cells, faces: constantFaces,
                                    walls: constantWalls, duration: dt, cfl: cfl)
                            }
                            let impulse = boundaries.indices.filter { boundaries[$0].owner == 1 }.reduce(0) {
                                $0 - update.wallImpulses[$1].x
                            }
                            let exact =
                                try reference.wallImpulse(time: elapsed + dt, area: area)
                                - reference.wallImpulse(time: elapsed, area: area)
                            // Before/after arrival are event-split, so the exact wall pressure is constant in this interval.
                            historyError += abs(impulse - exact)
                            reflectingImpulse += impulse
                            wallImpulse += update.wallImpulses.reduce(SIMD3<Double>.zero, +)
                            cells = update.cells
                            elapsed += dt
                            steps += 1
                        }
                        let excess = reflectingImpulse - area * reference.pressure * target
                        let exact =
                            try reference.wallImpulse(time: target, area: area) - area * reference.pressure
                            * target
                        frames.append(
                            .init(
                                time: target, arrivalFraction: fraction, excessImpulse: excess,
                                exactExcessImpulse: exact, impulseError: (excess - exact) / exactFinal))
                    }
                    let after = total(cells)
                    let result = Result(
                        cellLength: h, cfl: cfl, mach: mach,
                        transport: limited ? "limitedSSPRK2" : "constantEuler",
                        arrivalTime: reference.arrivalTime,
                        duration: duration, interactionTime: reference.interactionTime,
                        reflectedPressure: reference.reflectedPressure,
                        steps: steps, rejectedSteps: rejected,
                        relativePressureHistoryL1: historyError / exactFinal,
                        relativeMassChange: after[0] / before[0] - 1,
                        relativeEnergyChange: after[4] / before[4] - 1,
                        momentumBudgetResidual: SIMD3(
                            after[1] - before[1], after[2] - before[2], after[3] - before[3]) + wallImpulse,
                        frames: frames)
                    results.append(result)
                    try progress(result)
                }
            }
        }
        return results
    }
    private static func total(_ cells: [FractionalGasTransport.Cell]) -> SIMD8<Double> {
        var total = SIMD8<Double>.zero
        var correction = SIMD8<Double>.zero
        for cell in cells {
            let term = cell.amount - correction
            let next = total + term
            correction = (next - total) - term
            total = next
        }
        return total
    }
}
