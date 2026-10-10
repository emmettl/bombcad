import Foundation
import simd

@testable import BlastCore

struct PacketCell: Codable {
    let volume: Double
    let amount: [Double]
    let velocity: [Double]
    let pressure: Double
    let bits: [UInt64]
    init(_ cell: FractionalGasTransport.Cell) {
        volume = cell.volume
        amount = (0..<8).map { cell.amount[$0] }
        velocity = [cell.velocity.x, cell.velocity.y, cell.velocity.z]
        pressure = cell.pressure()
        bits = ([volume] + amount + velocity + [pressure]).map(\.bitPattern)
    }
}
struct RemapFrame: Codable {
    let start, end, maximumOutflowFraction: Double
    let transfers: Int
    let cells: [PacketCell]
}
struct RemapHistory: Codable {
    let profile: String
    let initial: [PacketCell]
    let frames: [RemapFrame]
    let final: [PacketCell]
    let rejectedIntervals: Int
}
struct MovingFrame: Codable {
    let time, duration, maximumStep: Double
    let groupCount: Int
    let members: [[Int]]
    let cells: [PacketCell]
    let reservoirExchange: [Double]
    let wallImpulses, wallMoments: [[Double]]
    let wallWork: [Double]
    let wallSampleFallbacks, scatterLimitedGroups, scatterPositivityReducedGroups,
        scatterRankDeficientGroups: Int
}
struct MovingHistory: Codable {
    let spacing, rotation: Double
    let integration, profile: String
    let quadratic: Bool
    let velocity: [Double]
    let initial: [PacketCell]
    let frames: [MovingFrame]
}
struct PacketReport: Codable {
    let schemaVersion: Int
    let remaps: [RemapHistory]
    let moving: [MovingHistory]
    let fractionalGas: [ExperimentalFractionalGasStudy.Result]
    let geometryRemap: [ExperimentalFractionalRemapStudy.Result]
    let connectedGas: [ExperimentalConnectedGasStudy.Result]
    let pistonCrossing: [ExperimentalPistonCrossingStudy.Result]
}
enum PacketHistory {
    static func write(output: String) throws {
        var remaps: [RemapHistory] = []
        for profile in ["uniform", "nonuniform"] {
            func volumes(_ t: Double) -> [Double] { [0.02 * (1 - t), 0.001, 0.02 * t] }
            let faces = [FractionalVolumeRemap.Face(a: 0, b: 1, openArea: 1), .init(a: 1, b: 2, openArea: 1)]
            let initial = volumes(0).enumerated().map { n, v in
                FractionalGasTransport.Cell(
                    volume: v, density: profile == "uniform" ? 1.225 : [2.0, 1.0, 0.5][n],
                    velocity: SIMD3(1, 2, -3),
                    pressure: profile == "uniform" ? 101325 : [120000.0, 90000, 60000][n])
            }
            let result = try FractionalRemapStepper.advance(
                initial, duration: 1, volumesAt: volumes, facesBetween: { _, _ in faces })
            var cells = initial
            var frames: [RemapFrame] = []
            // Replay every actual accepted interval to retain its complete native packet.
            for step in result.steps {
                let plan = try FractionalVolumeRemap.build(
                    old: cells.map(\.volume), new: volumes(step.end), faces: faces)
                cells = try FractionalGasTransport.advance(
                    cells, newVolumes: volumes(step.end), transfers: plan.transfers)
                frames.append(
                    RemapFrame(
                        start: step.start, end: step.end,
                        maximumOutflowFraction: step.maximumOutflowFraction, transfers: step.transfers,
                        cells: cells.map(PacketCell.init)))
            }
            guard cells.map(PacketCell.init).map(\.bits) == result.cells.map(PacketCell.init).map(\.bits)
            else { throw Failure.replay }
            remaps.append(
                RemapHistory(
                    profile: profile, initial: initial.map(PacketCell.init), frames: frames,
                    final: result.cells.map(PacketCell.init), rejectedIntervals: result.rejectedIntervals))
        }
        var moving: [MovingHistory] = []
        let dt = 2e-7
        let velocity = 10 * ExperimentalMovingGroupsStudy.velocity
        for h in [0.4, 0.2] {
            for angle in [0.0, 0.23] {
                for integration in [MovingGroupedGasFlux.TimeIntegration.euler, .heun] {
                    for quadratic in [false, true] {
                        for profile in ["uniform", "nonuniform"] {
                            let event = try ExperimentalMovingGroupsStudy.eventTime(
                                h: h, angle: angle, opening: profile == "uniform")
                            var body = try ExperimentalMovingGroupsStudy.body(
                                angle: angle, time: event - 20 * dt)
                            let first = try ExperimentalMovingGroupsStudy.domain(
                                h: h, angle: angle, start: 0,
                                duration: dt, prescribedBody: body, prescribedVelocity: velocity,
                                reconstruct: true, surfaceQuadrature: true, conservedQuadratic: quadratic)
                            let count = Int((2 / h).rounded())
                            var cells = first.old.enumerated().map { n, c -> FractionalGasTransport.Cell in
                                guard profile != "uniform", c.volume > 0 else { return c }
                                let x = h * (Double(n % count) + 0.5)
                                return .init(
                                    volume: c.volume, density: 1.225 * (1 + 0.02 * x),
                                    velocity: velocity, pressure: 101325 + 2000 * x)
                            }
                            let initial = cells.map(PacketCell.init)
                            var frames: [MovingFrame] = []
                            for step in 0..<4 {
                                let plan = try ExperimentalMovingGroupsStudy.domain(
                                    h: h, angle: angle,
                                    start: Double(step) * dt, duration: dt, previous: cells,
                                    prescribedBody: body, prescribedVelocity: velocity, reconstruct: true,
                                    surfaceQuadrature: true, conservedQuadratic: quadratic
                                ).plan
                                let result = try MovingGroupedGasFlux.advance(
                                    plan,
                                    exterior: .init(
                                        volume: 1, density: 1.225, velocity: velocity, pressure: 101325),
                                    limited: true, timeIntegration: integration, conservedQuadratic: quadratic
                                )
                                cells = result.cells
                                frames.append(
                                    MovingFrame(
                                        time: Double(step) * dt, duration: dt,
                                        maximumStep: result.maximumStep, groupCount: plan.cells.count,
                                        members: plan.members, cells: cells.map(PacketCell.init),
                                        reservoirExchange: (0..<8).map { result.reservoirExchange[$0] },
                                        wallImpulses: result.wallImpulses.map { [$0.x, $0.y, $0.z] },
                                        wallMoments: result.wallMomentImpulses.map { [$0.x, $0.y, $0.z] },
                                        wallWork: result.wallWork,
                                        wallSampleFallbacks: result.wallSampleFallbacks,
                                        scatterLimitedGroups: result.scatterLimitedGroups,
                                        scatterPositivityReducedGroups: result.scatterPositivityReducedGroups,
                                        scatterRankDeficientGroups: result.scatterRankDeficientGroups))
                                body = body.translated(by: dt * velocity)
                            }
                            moving.append(
                                MovingHistory(
                                    spacing: h, rotation: angle,
                                    integration: integration.rawValue, profile: profile, quadratic: quadratic,
                                    velocity: [velocity.x, velocity.y, velocity.z], initial: initial,
                                    frames: frames))
                        }
                    }
                }
            }
        }
        let report = PacketReport(
            schemaVersion: 1, remaps: remaps, moving: moving,
            fractionalGas: try ExperimentalFractionalGasStudy.run(),
            geometryRemap: try ExperimentalFractionalRemapStudy.run(),
            connectedGas: try ExperimentalConnectedGasStudy.run(),
            pistonCrossing: try ExperimentalPistonCrossingStudy.run())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: URL(fileURLWithPath: output).appendingPathComponent("packet-report.json"))
        print(
            "PASS complete remap replays, 32 moving-reservoir histories and public gas/remap/crossing studies"
        )
    }
    enum Failure: Error { case replay }
}
