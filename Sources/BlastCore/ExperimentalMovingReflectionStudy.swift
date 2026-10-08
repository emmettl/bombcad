import simd

/// Prescribed translating piston struck by a normal shock. Uses the existing conservative
/// tube merge/split reference; this is not moving 3D cut-cell or free-body simulation.
public enum ExperimentalMovingReflectionStudy {
    public struct Frame: Codable, Sendable {
        public let time: Double
        public let arrivalFraction: Double
        public let pistonImpulse: Double
        public let exactPistonImpulse: Double
        public let impulseError: Double
        public let pistonWork: Double
        public let exactPistonWork: Double
        public let workError: Double
        public let impulseWorkResidual: Double
        public let relativeMassChange: Double
        public let energyBudgetResidual: Double
        public let momentumBudgetResidual: SIMD3<Double>
        public let volumeResidual: Double
    }
    public struct Result: Codable, Sendable {
        public let cellLength: Double
        public let cfl: Double
        public let mach: Double
        public let pistonVelocity: Double
        public let reconstruction: String
        public let arrivalTime: Double
        public let interactionTime: Double
        public let steps: Int
        public let rejectedSteps: Int
        public let gridCrossings: Int
        public let remeshes: Int
        public let relativePressureHistoryL1: Double
        public let frames: [Frame]
    }
    enum Failure: Error { case invalidConfiguration }
    public static func run(
        cellLengths: [Double] = [0.05, 0.025, 0.0125, 0.00625],
        cfls: [Double] = [0.2, 0.1], machNumbers: [Double] = [1.2, 2],
        velocities: [Double] = [-20, 20], limited: Bool = true,
        progress: (Result) throws -> Void = { _ in }
    ) throws -> [Result] {
        guard velocities.allSatisfy({ $0.isFinite && $0 != 0 }) else { throw Failure.invalidConfiguration }
        let area = 0.01
        var results: [Result] = []
        for h in cellLengths {
            for mach in machNumbers {
                for velocity in velocities {
                    let reference = try MovingShockReflection(mach: mach, velocity: velocity)
                    let times = [0.8, 1.0, 1.2, 1.4].map { $0 * reference.stationary.arrivalTime }
                    let duration = times.last!
                    let exactExcess =
                        try reference.wallImpulse(time: duration, area: area)
                        - area * reference.stationary.pressure * duration
                    for cfl in cfls {
                        var historyError = 0.0
                        let run = try PrescribedPistonTube.run(
                            cellLength: h, area: area,
                            length: reference.stationary.length, pistonVelocity: velocity, duration: duration,
                            cfl: cfl, outputTimes: times, reconstruction: limited ? .minmod : .constant,
                            initialState: { low, high in
                                try reference.cell(lower: low, upper: high, time: 0, area: area)
                            },
                            onAcceptedStep: { step in
                                // Arrival is an output event; every exact interval stays on one pressure branch.
                                let exact =
                                    try reference.wallImpulse(time: step.time + step.duration, area: area)
                                    - reference.wallImpulse(time: step.time, area: area)
                                historyError += abs(step.pistonImpulse - exact)
                            })
                        let frames = try run.snapshots.map { snapshot in
                            let after = total(snapshot.cells)
                            let exactImpulse = try reference.wallImpulse(time: snapshot.time, area: area)
                            let exactWork = try reference.wallWork(time: snapshot.time, area: area)
                            return Frame(
                                time: snapshot.time,
                                arrivalFraction: snapshot.time / reference.stationary.arrivalTime,
                                pistonImpulse: snapshot.pistonImpulse, exactPistonImpulse: exactImpulse,
                                impulseError: (snapshot.pistonImpulse - exactImpulse) / exactExcess,
                                pistonWork: snapshot.wallWork, exactPistonWork: exactWork,
                                workError: (snapshot.wallWork - exactWork) / (abs(velocity) * exactExcess),
                                impulseWorkResidual: snapshot.wallWork - velocity * snapshot.pistonImpulse,
                                relativeMassChange: after[0] / run.initialAmount[0] - 1,
                                energyBudgetResidual: after[4] - run.initialAmount[4] + snapshot.wallWork,
                                momentumBudgetResidual: SIMD3(
                                    after[1] - run.initialAmount[1], after[2] - run.initialAmount[2],
                                    after[3] - run.initialAmount[3]) + snapshot.wallImpulse,
                                volumeResidual: snapshot.cells.reduce(0) { $0 + $1.volume }
                                    - area * (reference.stationary.length + velocity * snapshot.time))
                        }
                        let result = Result(
                            cellLength: h, cfl: cfl, mach: mach, pistonVelocity: velocity,
                            reconstruction: limited ? "minmodSSPRK2" : "constantEuler",
                            arrivalTime: reference.stationary.arrivalTime,
                            interactionTime: reference.stationary.interactionTime, steps: run.steps,
                            rejectedSteps: run.rejectedSteps, gridCrossings: run.gridCrossings,
                            remeshes: run.remeshes, relativePressureHistoryL1: historyError / exactExcess,
                            frames: frames)
                        results.append(result)
                        try progress(result)
                    }
                }
            }
        }
        return results
    }
    private static func total(_ cells: [FractionalGasTransport.Cell]) -> SIMD8<Double> {
        var sum = SIMD8<Double>.zero
        var correction = SIMD8<Double>.zero
        for cell in cells {
            let term = cell.amount - correction
            let next = sum + term
            correction = (next - sum) - term
            sum = next
        }
        return sum
    }
}
