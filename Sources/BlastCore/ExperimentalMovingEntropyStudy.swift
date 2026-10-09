import simd

/// First-order moving transport compared with an exact advected quadratic density profile.
/// Pressure and velocity are constant, isolating mass transport and wet/dry state accuracy
/// from nonuniform pressure loads, shocks and free-body feedback.
public enum ExperimentalMovingEntropyStudy {
    enum Failure: Error { case invalidConfiguration }
    public static func run(
        cellSizes: [Double] = [0.4, 0.2, 0.1], rotations: [Double] = [0, 0.23],
        cfls: [Double] = [0.2, 0.1], amplitude: Double = 0.2, limited: Bool = false,
        progress: (ExperimentalMovingTrajectoryStudy.Result) throws -> Void = { _ in }
    ) throws -> [ExperimentalMovingTrajectoryStudy.Result] {
        guard cfls.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 0.5 }) else {
            throw Failure.invalidConfiguration
        }
        let reference = try AdvectedQuadraticGas(
            velocity: 100 * ExperimentalMovingGroupsStudy.velocity,
            amplitude: amplitude)
        var results: [ExperimentalMovingTrajectoryStudy.Result] = []
        for h in cellSizes {
            guard h.isFinite, h >= 0.1, h <= 0.4, abs(2 / h - (2 / h).rounded()) < 1e-10 else {
                throw Failure.invalidConfiguration
            }
            for angle in rotations {
                guard angle.isFinite else { throw Failure.invalidConfiguration }
                for cfl in cfls {
                    let r = try ExperimentalMovingTrajectoryStudy.solve(
                        h: h, angle: angle, start: 0,
                        duration: 0.0008, velocityScale: 100, cfl: cfl, maximumStep: h * 0.00008,
                        reference: reference, limited: limited)
                    results.append(r)
                    try progress(r)
                }
            }
        }
        return results
    }
}
