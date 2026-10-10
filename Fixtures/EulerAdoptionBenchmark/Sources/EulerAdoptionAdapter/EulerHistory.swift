import Foundation
import simd

@testable import BlastCore

struct EulerLoad: Codable {
    let impulse: [Double]
    let work: Double
    let bits: [UInt64]
    init(_ impulse: SIMD3<Double>, _ work: Double) {
        self.impulse = [impulse.x, impulse.y, impulse.z]
        self.work = work
        bits = (self.impulse + [work]).map(\.bitPattern)
    }
}
struct EulerResult: Codable {
    let cells: [PacketCell]
    let loads: [EulerLoad]
    init(_ r: FractionalEulerFlux.Result) {
        cells = r.cells.map(PacketCell.init)
        loads = r.wallImpulses.indices.map { EulerLoad(r.wallImpulses[$0], r.wallWork[$0]) }
    }
}
struct EulerFace: Codable {
    let a, b: Int
    let normal: [Double]
    let area: Double
    let left, right: PacketCell?
    init(_ f: FractionalEulerFlux.Face) {
        a = f.a
        b = f.b
        normal = [f.normal.x, f.normal.y, f.normal.z]
        area = f.area
        left = f.leftState.map(PacketCell.init)
        right = f.rightState.map(PacketCell.init)
    }
}
struct EulerWall: Codable {
    let cell: Int
    let normal, velocity: [Double]
    let area: Double
    let state: PacketCell?
    init(_ w: FractionalEulerFlux.Wall) {
        cell = w.cell
        normal = [w.normal.x, w.normal.y, w.normal.z]
        velocity = [w.velocity.x, w.velocity.y, w.velocity.z]
        area = w.area
        state = w.state.map(PacketCell.init)
    }
}
struct EulerFrame: Codable {
    let time, duration, limit: Double
    let stageLimit: Double?
    let input: [PacketCell]
    let scattered: [PacketCell]?
    let faces: [EulerFace], walls: [EulerWall]
    let first: EulerResult, second: EulerResult?, result: EulerResult
    let secondFaces: [EulerFace]?, secondWalls: [EulerWall]?
}
struct EulerRun: Codable {
    let kind, integration, profile: String
    let resolution, rotation, wallSpeed: Double
    let members: [[Int]]
    let nativeGrid: [PacketCell]?
    let frames: [EulerFrame]
}
struct EulerReport: Codable {
    let schemaVersion: Int
    let runs: [EulerRun]
    let fractionalFlux: [ExperimentalFractionalFluxStudy.Result]
}
enum EulerHistory {
    enum Failure: Error { case replay, output }
    static func checkReplay(
        _ old: [FractionalGasTransport.Cell], first: FractionalEulerFlux.Result,
        second: FractionalEulerFlux.Result?, actual: FractionalEulerFlux.Result
    ) throws {
        let expected =
            second.map { s in
                old.indices.map { n in
                    FractionalGasTransport.Cell(
                        volume: (old[n].volume + s.cells[n].volume) / 2,
                        amount: (old[n].amount + s.cells[n].amount) / 2)
                }
            } ?? first.cells
        guard expected.map(PacketCell.init).map(\.bits) == actual.cells.map(PacketCell.init).map(\.bits)
        else { throw Failure.replay }
        for n in actual.wallImpulses.indices {
            let expectedImpulse =
                second.map { (first.wallImpulses[n] + $0.wallImpulses[n]) / 2 }
                ?? first.wallImpulses[n]
            let expectedWork =
                second.map { (first.wallWork[n] + $0.wallWork[n]) / 2 }
                ?? first.wallWork[n]
            guard
                EulerLoad(expectedImpulse, expectedWork).bits
                    == EulerLoad(actual.wallImpulses[n], actual.wallWork[n]).bits
            else { throw Failure.replay }
        }
    }
    static func write(output: String) throws {
        var runs: [EulerRun] = []
        // The actual app-owned tube limiter and SSPRK2 method receive each input.
        // Replayed stages capture their full traces/results and must reproduce its output bits.
        for n in [16, 32] {
            for speed in [-3.0, 0, 3] {
                for profile in ["uniform", "pulse"] {
                    for integration in ["euler", "ssprk2"] {
                        let area = 0.01
                        let h = 0.64 / Double(n)
                        var cells = (0..<n).map { i in
                            FractionalGasTransport.Cell(
                                volume: area * h * (i == 0 ? 0.125 : 1), density: 1.225,
                                pressure: profile == "pulse" && i == n / 2 ? 150000 : 101325)
                        }
                        let walls = [
                            FractionalEulerFlux.Wall(cell: 0, normal: SIMD3(-1, 0, 0), area: area),
                            .init(
                                cell: n - 1, normal: SIMD3(1, 0, 0), area: area,
                                velocity: SIMD3(speed, 0, 0)),
                        ]
                        var frames: [EulerFrame] = []
                        var time = 0.0
                        for _ in 0..<6 {
                            let faces = LimitedTubeFlux.faces(cells, area: area)
                            let limit = try FractionalEulerFlux.maximumStep(
                                cells, faces: faces, walls: walls, cfl: 0.2)
                            let dt = 0.02 * limit
                            let first = try FractionalEulerFlux.advanceWithWalls(
                                cells, faces: faces, walls: walls, duration: dt, cfl: 0.2)
                            let secondFaces =
                                integration == "ssprk2" ? LimitedTubeFlux.faces(first.cells, area: area) : nil
                            let secondLimit = try secondFaces.map {
                                try FractionalEulerFlux.maximumStep(
                                    first.cells, faces: $0, walls: walls, cfl: 0.2)
                            }
                            let second = try secondFaces.map {
                                try FractionalEulerFlux.advanceWithWalls(
                                    first.cells, faces: $0,
                                    walls: walls, duration: dt, cfl: 0.2)
                            }
                            let actual =
                                integration == "ssprk2"
                                ? try LimitedTubeFlux.advance(
                                    cells, area: area, walls: walls, duration: dt, cfl: 0.2)
                                : first
                            try checkReplay(cells, first: first, second: second, actual: actual)
                            frames.append(
                                EulerFrame(
                                    time: time, duration: dt, limit: limit,
                                    stageLimit: secondLimit, input: cells.map(PacketCell.init),
                                    scattered: nil,
                                    faces: faces.map(EulerFace.init), walls: walls.map(EulerWall.init),
                                    first: EulerResult(first), second: second.map(EulerResult.init),
                                    result: EulerResult(actual),
                                    secondFaces: secondFaces.map { $0.map(EulerFace.init) },
                                    secondWalls: second.map { _ in walls.map(EulerWall.init) }))
                            cells = actual.cells
                            time += dt
                        }
                        runs.append(
                            EulerRun(
                                kind: "tube", integration: integration, profile: profile,
                                resolution: Double(n), rotation: 0, wallSpeed: speed,
                                members: [], nativeGrid: nil, frames: frames))
                    }
                }
            }
        }
        for h in [0.4, 0.2] {
            for angle in [0.0, 0.23] {
                for profile in ["uniform", "pulse"] {
                    let domain = try ExperimentalConnectedGasStudy.domain(
                        cellSize: h, rotation: angle,
                        pressureAt: { p in
                            profile == "uniform"
                                ? 101325
                                : 101325 * (1 + 0.02 * exp(-simd_length_squared(p - SIMD3(0.5, 1, 1)) / 0.1))
                        })
                    let plan = try ConnectedGasGroups.build(
                        cells: domain.cells, centres: domain.centres,
                        nominalVolume: h * h * h, faces: domain.faces, boundaries: domain.boundaries)
                    let geometry = try LimitedGroupedGasFlux.Geometry(
                        centres: plan.groups.map(\.centre),
                        faces: plan.faces, boundaries: plan.boundaries)
                    for integration in ["euler", "ssprk2"] {
                        var cells = plan.groups.map(\.cell)
                        var frames: [EulerFrame] = []
                        var time = 0.0
                        for _ in 0..<2 {
                            let traces = try geometry.traces(cells)
                            let limit = try FractionalEulerFlux.maximumStep(
                                cells, faces: traces.faces,
                                walls: traces.walls, cfl: 0.2)
                            let dt = 0.02 * limit
                            let first = try FractionalEulerFlux.advanceWithWalls(
                                cells, faces: traces.faces,
                                walls: traces.walls, duration: dt, cfl: 0.2)
                            let next = integration == "ssprk2" ? try geometry.traces(first.cells) : nil
                            let secondLimit = try next.map {
                                try FractionalEulerFlux.maximumStep(
                                    first.cells, faces: $0.faces, walls: $0.walls, cfl: 0.2)
                            }
                            let second = try next.map {
                                try FractionalEulerFlux.advanceWithWalls(
                                    first.cells, faces: $0.faces,
                                    walls: $0.walls, duration: dt, cfl: 0.2)
                            }
                            let actual =
                                integration == "ssprk2"
                                ? try geometry.advance(cells, traces: traces, duration: dt, cfl: 0.2) : first
                            try checkReplay(cells, first: first, second: second, actual: actual)
                            frames.append(
                                EulerFrame(
                                    time: time, duration: dt, limit: limit,
                                    stageLimit: secondLimit, input: cells.map(PacketCell.init),
                                    scattered: try plan.scatter(actual.cells).map(PacketCell.init),
                                    faces: traces.faces.map(EulerFace.init),
                                    walls: traces.walls.map(EulerWall.init),
                                    first: EulerResult(first), second: second.map(EulerResult.init),
                                    result: EulerResult(actual),
                                    secondFaces: next.map { $0.faces.map(EulerFace.init) },
                                    secondWalls: next.map { $0.walls.map(EulerWall.init) }))
                            cells = actual.cells
                            time += dt
                        }
                        runs.append(
                            EulerRun(
                                kind: "group", integration: integration, profile: profile,
                                resolution: h, rotation: angle, wallSpeed: 0,
                                members: plan.groups.map(\.members),
                                nativeGrid: domain.cells.map(PacketCell.init), frames: frames))
                    }
                }
            }
        }
        let report = EulerReport(
            schemaVersion: 1, runs: runs,
            fractionalFlux: try ExperimentalFractionalFluxStudy.run()
                + ExperimentalFractionalFluxStudy.run(reflectingWalls: true))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(report).write(
            to: URL(fileURLWithPath: output).appending(path: "euler-report.json"))
        print("PASS produced 24 tube and 16 grouped complete Euler/staged histories")
    }
}
