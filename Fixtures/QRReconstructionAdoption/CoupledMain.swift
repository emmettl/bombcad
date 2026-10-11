import Foundation
import simd

// Execute production study entry points. Reflection-based observations retain all stored
// fields, including the accepted inventories, geometry and prepared transport stages.
var cases: [[String: Any]] = []
@MainActor func capture(_ id: String, _ parameters: [String: Any], _ body: () throws -> Any) throws {
    QRCoupledTrace.reset()
    let result = try body()
    cases.append([
        "id": id, "parameters": QRCoupledTrace.tree(parameters),
        "events": QRCoupledTrace.events, "result": QRCoupledTrace.tree(result),
    ])
}
let velocity = SIMD3<Double>(300, 100, -40)
for angle in [0.23, 0.4] {
    for integration in [MovingGroupedGasFlux.TimeIntegration.euler, .heun] {
        try capture(
            "uniform-\(angle)-\(integration.rawValue)",
            [
                "cellSize": 0.4, "angle": angle, "duration": 2e-7,
                "velocity": velocity, "integration": integration.rawValue,
            ]
        ) {
            let domain = try ExperimentalMovingGroupsStudy.domain(
                h: 0.4, angle: angle, start: 0, duration: 2e-7,
                prescribedVelocity: velocity, reconstruct: true,
                surfaceQuadrature: true, conservedQuadratic: true)
            let result = try MovingGroupedGasFlux.advance(
                domain.plan,
                exterior: .init(volume: 1, density: 1.225, velocity: velocity, pressure: 101325),
                limited: true, timeIntegration: integration, conservedQuadratic: true)
            return [
                "old": domain.old, "plan": domain.plan, "body": domain.body,
                "update": result,
            ] as [String: Any]
        }
    }
}
for mach in [1.2, 2.0] {
    try capture("reflection-\(mach)", ["cellLength": 0.2, "cfl": 0.2, "mach": mach]) {
        try ExperimentalWallReflectionStudy.run(
            cellLengths: [0.2], cfls: [0.2], machNumbers: [mach],
            limited: true, conservedQuadratic: true)
    }
}
for rings in 1...3 {
    try capture("initial-wall-\(rings)", ["cellSize": 0.2, "angle": 0.23, "rings": rings]) {
        try ExperimentalInitialWallTraceStudy.run(
            cellSizes: [0.2], rotations: [0.23], decompose: true,
            volumeFits: true, stencilRings: rings)
    }
}
try capture(
    "moving-pulse",
    [
        "cellSize": 0.2, "angle": 0.23, "cfl": 0.2,
        "duration": 0.00002, "pulseEnergy": 6400.0,
    ]
) {
    try ExperimentalMovingLoadStudy.run(
        cellSizes: [0.2], rotations: [0.23], cfls: [0.2],
        duration: 0.00002, conservedQuadratic: true)
}
let report: [String: Any] = ["schemaVersion": 1, "cases": cases]
let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([10]))
