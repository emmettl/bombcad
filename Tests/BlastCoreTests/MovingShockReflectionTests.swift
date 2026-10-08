import Testing
import simd

@testable import BlastCore

@Suite("Prescribed moving shock reflection")
struct MovingShockReflectionTests {
    @Test(
        "Galilean reflection preserves pressure and density while changing velocity",
        arguments: [-20.0, 20.0])
    func transformedStates(velocity: Double) throws {
        let r = try MovingShockReflection(mach: 2, velocity: velocity)
        let post = try r.cell(lower: 0, upper: 0.1, time: 0, area: 0.01)
        #expect(abs(post.amount[0] / post.volume - r.stationary.incidentDensity) < 1e-12)
        #expect(abs(post.pressure() / r.stationary.incidentPressure - 1) < 1e-12)
        #expect(abs(post.velocity.x - (velocity - r.stationary.incidentVelocity)) < 1e-12)
        let ambient = try r.cell(lower: 1.9, upper: 2, time: 0, area: 0.01)
        #expect(abs(ambient.pressure() / r.stationary.pressure - 1) < 1e-12)
        #expect(abs(ambient.velocity.x - velocity) < 1e-12)
        let time = 1.2 * r.stationary.arrivalTime
        let wall = r.stationary.length + velocity * time
        let reflected = try r.cell(lower: wall - 0.001, upper: wall, time: time, area: 0.01)
        #expect(abs(reflected.pressure() / r.stationary.reflectedPressure - 1) < 1e-12)
        #expect(abs(reflected.amount[0] / reflected.volume - r.stationary.reflectedDensity) < 1e-12)
        #expect(abs(reflected.velocity.x - velocity) < 1e-12)
        let impulse = try r.wallImpulse(time: time, area: 0.01)
        #expect(abs(try r.wallWork(time: time, area: 0.01) - velocity * impulse) < 1e-12)
    }
    @Test("Unsupported opposite-wall compression and invalid profiles are rejected")
    func invalidInputs() throws {
        let reference = try NormalShockReflection(mach: 1.2)
        #expect(throws: MovingShockReflection.Failure.self) {
            try MovingShockReflection(mach: 1.2, velocity: reference.incidentVelocity)
        }
        #expect(throws: PrescribedPistonTube.Failure.self) {
            try PrescribedPistonTube.run(
                cellLength: 0.1, area: 0.01, length: 2,
                pistonVelocity: 20, duration: 0.0001,
                initialState: { low, high in
                    .init(volume: 2 * (high - low) * 0.01, density: 1.225, pressure: 101325)
                })
        }
        #expect(throws: FractionalGasTransport.Failure.self) {
            try PrescribedPistonTube.run(
                cellLength: 0.1, area: 0.01, length: 2,
                pistonVelocity: 20, duration: 0.0001,
                initialState: { low, high in
                    .init(volume: (high - low) * 0.01, density: -1, pressure: 101325)
                })
        }
    }
    @Test("Custom uniform initialization reproduces the legacy default inventories")
    func uniformProfile() throws {
        let original = try PrescribedPistonTube.run(
            cellLength: 0.1, area: 0.01, length: 0.5,
            pistonVelocity: 20, duration: 0.0001)
        let supplied = try PrescribedPistonTube.run(
            cellLength: 0.1, area: 0.01, length: 0.5,
            pistonVelocity: 20, duration: 0.0001,
            initialState: { low, high in
                .init(volume: (high - low) * 0.01, density: 1.225, pressure: 101325)
            })
        #expect(
            simd_length(
                SIMD4(
                    original.initialAmount[0] - supplied.initialAmount[0],
                    original.initialAmount[1] - supplied.initialAmount[1],
                    original.initialAmount[4] - supplied.initialAmount[4], 0)) < 1e-10)
        #expect(abs(original.pistonImpulse - supplied.pistonImpulse) < 1e-10)
        #expect(abs(original.wallWork - supplied.wallWork) < 1e-10)
    }
    @Test("Accepted interval diagnostics sum to cumulative piston impulse and work")
    func intervalLoads() throws {
        var count = 0
        var impulse = 0.0
        var work = 0.0
        var end = 0.0
        let run = try PrescribedPistonTube.run(
            cellLength: 0.025, area: 0.01, length: 0.355,
            pistonVelocity: -20, duration: 0.0008, reconstruction: .minmod,
            onAcceptedStep: { step in
                #expect(step.time == end && step.duration > 0)
                end = step.time + step.duration
                impulse += step.pistonImpulse
                work += step.pistonWork
                count += 1
            })
        #expect(count == run.steps && abs(end - 0.0008) < 1e-12)
        #expect(abs(impulse - run.pistonImpulse) < 1e-12)
        #expect(abs(work - run.wallWork) < 1e-12)
    }
    @Test("Opposite piston motions preserve signed work, impulse pairing and inventories")
    func budgets() throws {
        let rows = try ExperimentalMovingReflectionStudy.run(
            cellLengths: [0.025], cfls: [0.2], machNumbers: [1.2])
        #expect(rows.count == 2)
        for row in rows {
            #expect(row.gridCrossings > 0 && row.remeshes > 0)
            #expect(row.relativePressureHistoryL1.isFinite && row.relativePressureHistoryL1 > 0)
            for frame in row.frames {
                #expect(abs(frame.relativeMassChange) < 1e-12)
                #expect(abs(frame.energyBudgetResidual) < 1e-8)
                #expect(simd_length(frame.momentumBudgetResidual) < 1e-10)
                #expect(abs(frame.volumeResidual) < 1e-12)
                #expect(abs(frame.impulseWorkResidual) < 1e-8)
                #expect(frame.pistonWork * row.pistonVelocity > 0)
                #expect(frame.exactPistonWork * row.pistonVelocity > 0)
                #expect(
                    abs(frame.workError - (row.pistonVelocity > 0 ? frame.impulseError : -frame.impulseError))
                        < 1e-12)
            }
            #expect(abs(row.frames.last!.impulseError) < 0.15)
        }
    }
}
