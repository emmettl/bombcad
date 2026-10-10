import Foundation
import simd

@testable import BlastCore

struct WallCase: Codable {
    let density, pressure, velocity, gamma: Double
    let wallPressure, signalSpeed: Double
    let pressureBits, signalBits: UInt64
    let vacuum: Bool
}
struct Cell: Codable {
    let volume: Double
    let amount: [Double]
    let pressure: Double
    init(_ cell: FractionalGasTransport.Cell) {
        volume = cell.volume
        amount = (0..<8).map { cell.amount[$0] }
        pressure = cell.pressure()
    }
}
struct Interval: Codable { let time, duration, impulse, work: Double }
struct Frame: Codable {
    let time, work, pistonImpulse: Double
    let impulse: [Double]
    let steps, rejections: Int
    let cells: [Cell]
}
struct Piston: Codable {
    let spacing, velocity, duration: Double
    let reconstruction: String
    let cells: [Cell]
    let initialAmount, impulse: [Double]
    let work, pistonImpulse: Double
    let steps, rejections, remeshes, crossings: Int
    let frames: [Frame]
    let intervals: [Interval]
}
struct Report: Codable {
    let schemaVersion: Int
    let wallCases: [WallCase]
    let wallStudy: [ExperimentalWallPressureStudy.Result]
    let reflection: [ExperimentalWallReflectionStudy.Result]
    let pistons: [Piston]
}
@main enum PacketAdoptionAdapter {
    static func main() throws {
        var walls: [WallCase] = []
        for gamma in [1.1, 1.4, 5.0 / 3, 3] {
            for rho in [0.25, 1.225, 7] {
                for p in [0.01, 101325, 1e7] {
                    let c = sqrt(gamma * p / rho)
                    for mach in [-8.0, -3, -1, -0.5, -0.1, 0, 0.001, 0.5, 1, 5] {
                        let u = mach * c
                        let r = try IdealGasWallRiemann.solve(
                            density: rho, pressure: p, normalVelocity: u, gamma: gamma)
                        walls.append(
                            WallCase(
                                density: rho, pressure: p, velocity: u, gamma: gamma,
                                wallPressure: r.pressure, signalSpeed: r.signalSpeed,
                                pressureBits: r.pressure.bitPattern,
                                signalBits: r.signalSpeed.bitPattern, vacuum: r.vacuum))
                    }
                }
            }
        }
        var pistons: [Piston] = []
        let duration = 0.0008
        for h in [0.05, 0.025, 0.0125] {
            for speed in [-20.0, 20.0] {
                for reconstruction in [PrescribedPistonTube.Reconstruction.constant, .minmod] {
                    var intervals: [Interval] = []
                    let result = try PrescribedPistonTube.run(
                        cellLength: h, area: 0.01, length: speed < 0 ? 0.355 : 0.655,
                        pistonVelocity: speed, duration: duration, cfl: 0.2,
                        outputTimes: (0...32).map { duration * Double($0) / 32 },
                        reconstruction: reconstruction,
                        onAcceptedStep: { s in
                            intervals.append(
                                Interval(
                                    time: s.time, duration: s.duration, impulse: s.pistonImpulse,
                                    work: s.pistonWork))
                        })
                    let frames = result.snapshots.map { s in
                        Frame(
                            time: s.time, work: s.wallWork, pistonImpulse: s.pistonImpulse,
                            impulse: [s.wallImpulse.x, s.wallImpulse.y, s.wallImpulse.z], steps: s.steps,
                            rejections: s.rejectedSteps, cells: s.cells.map(Cell.init))
                    }
                    pistons.append(
                        Piston(
                            spacing: h, velocity: speed, duration: duration,
                            reconstruction: reconstruction.rawValue,
                            cells: result.cells.map(Cell.init),
                            initialAmount: (0..<8).map { result.initialAmount[$0] },
                            impulse: [result.wallImpulse.x, result.wallImpulse.y, result.wallImpulse.z],
                            work: result.wallWork,
                            pistonImpulse: result.pistonImpulse, steps: result.steps,
                            rejections: result.rejectedSteps,
                            remeshes: result.remeshes, crossings: result.gridCrossings, frames: frames,
                            intervals: intervals))
                }
            }
        }
        var reflection: [ExperimentalWallReflectionStudy.Result] = []
        for quadratic in [false, true] {
            reflection += try ExperimentalWallReflectionStudy.run(
                cellLengths: [0.1, 0.05], cfls: [0.2], machNumbers: [1.2, 2], limited: true,
                conservedQuadratic: quadratic)
        }
        let report = Report(
            schemaVersion: 1, wallCases: walls, wallStudy: try ExperimentalWallPressureStudy.run(),
            reflection: reflection, pistons: pistons)
        guard let output = ProcessInfo.processInfo.environment["BOMBCAD_WALL_OUTPUT"] else {
            throw Failure.output
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: URL(fileURLWithPath: output).appendingPathComponent("report.json"))
        try PacketHistory.write(output: output)
        print("PASS produced 360 wall cases, 12 complete piston runs and 8 reflection histories")
    }
    enum Failure: Error { case output }
}
