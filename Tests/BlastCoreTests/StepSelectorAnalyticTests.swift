import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// The predeclared experiment writes full states externally; ordinary CI skips it.
@Suite(
    "Step selector independent analytic controls", .serialized, .gpuThreads,
    .enabled(if: ProcessInfo.processInfo.environment["BOMBCAD_SELECTOR_ANALYTIC_OUT"] != nil))
struct StepSelectorAnalyticTests {
    func state(_ solver: BlastSolver, to url: URL, measure: Double) throws -> [String: Double] {
        let data = solver.withState { cells in
            Data(bytes: cells.baseAddress!, count: cells.count * MemoryLayout<CellState>.stride)
        }
        try data.write(to: url, options: .withoutOverwriting)
        return solver.withState { cells in
            var mass = 0.0
            var energy = 0.0
            for cell in cells {
                mass += Double(cell.density)
                energy += Double(cell.energy)
            }
            return ["mass": mass * measure, "energy": energy * measure]
        }
    }

    @Test("Sod400/800 HLL/HLLC and Sedov80/120 retain independent bounds in both modes")
    func independentMatrix() throws {
        let root = URL(
            filePath: try #require(ProcessInfo.processInfo.environment["BOMBCAD_SELECTOR_ANALYTIC_OUT"]))
        let device = try #require(MTLCreateSystemDefaultDevice())
        try #require(MemoryLayout<CellState>.stride == 20)
        var rows: [[String: Any]] = []
        func number(_ value: Double) -> Any { value.isFinite ? value : String(describing: value) }
        func totals(_ value: [String: Double]) -> [String: Any] { value.mapValues(number) }
        func folder(_ name: String) throws -> URL {
            let url = root.appending(path: name)
            try #require(
                !FileManager.default.fileExists(atPath: url.path), "Retain each physical control once")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func record(_ row: [String: Any]) throws {
            rows.append(row)
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appending(path: "metrics.json"))
        }
        for precise in [false, true] {
            for riemann in RiemannSolver.allCases {
                for cells in [400, 800] {
                    let name = "sod-\(cells)-\(riemann.rawValue)-\(precise ? "precise" : "original")"
                    let output = try folder(name)
                    var configuration = SolverConfiguration()
                    configuration.reflectiveFaces = []
                    configuration.riemannSolver = riemann
                    configuration.pressureFloor = 1e-6
                    let dx = 1 / Float(cells)
                    let solver = try BlastSolver(
                        device: device, grid: Grid(nx: cells, ny: 1, nz: 1, cellSize: dx),
                        configuration: configuration)
                    solver.fill { i, _, _ in
                        i < cells / 2
                            ? Primitive(density: 1, pressure: 1) : Primitive(density: 0.125, pressure: 0.1)
                    }
                    if precise { try solver.configureStepSelectorDiagnostics() }
                    let initial = try state(
                        solver, to: output.appending(path: "initial.bin"), measure: Double(dx))
                    let result = solver.advance(until: 0.2)
                    let final = try state(
                        solver, to: output.appending(path: "final.bin"), measure: Double(dx))
                    let error = solver.withState { state in
                        (0..<cells).reduce(0.0) { sum, i in
                            let x = (Double(i) + 0.5) / Double(cells)
                            return sum
                                + abs(
                                    Double(state[i].density)
                                        - SolverVerificationTests.sodDensity(x: x, t: solver.time))
                        } / Double(cells)
                    }
                    try record([
                        "id": name, "problem": "sod", "preciseSelector": precise,
                        "cells": cells, "riemann": riemann.rawValue, "shape": [1, 1, cells, 5],
                        "dtype": "<f4",
                        "fields": ["density", "momentumX", "momentumY", "momentumZ", "energy"],
                        "time": solver.time, "steps": solver.stepCount, "stable": result.isStable,
                        "densityL1": number(error), "bound": 0.004, "initialTotals": totals(initial),
                        "finalTotals": totals(final),
                        "passed": result.isStable && abs(solver.time - 0.2) < 1e-5 && error < 0.004,
                    ])
                    #expect(result.isStable && abs(solver.time - 0.2) < 1e-5)
                    #expect(error < 0.004, "\(name): existing Sod L1 bound, actual \(error)")
                }
            }
        }
        for precise in [false, true] {
            for cells in [80, 120] {
                let name = "sedov-\(cells)-\(precise ? "precise" : "original")"
                let output = try folder(name)
                let dx = 1 / Float(cells)
                var configuration = SolverConfiguration()
                configuration.reflectiveFaces = [.xMin, .yMin, .zMin]
                configuration.pressureFloor = 1e-9
                configuration.ambientPressure = 1e-4
                let grid = Grid(nx: cells, ny: cells, nz: cells, cellSize: dx)
                let solver = try BlastSolver(device: device, grid: grid, configuration: configuration)
                let energy: Float = 1
                let radius = 3.5 * dx
                var sourceCells = 0
                for k in 0..<8 {
                    for j in 0..<8 {
                        for i in 0..<8 where simd_length(grid.cellCentre(i, j, k)) < radius {
                            sourceCells += 1
                        }
                    }
                }
                let sourcePressure = (energy / 8) * 0.4 / (Float(sourceCells) * dx * dx * dx)
                solver.fill { i, j, k in
                    Primitive(
                        density: 1,
                        pressure: simd_length(grid.cellCentre(i, j, k)) < radius ? sourcePressure : 1e-4)
                }
                if precise { try solver.configureStepSelectorDiagnostics() }
                let measure = pow(Double(dx), 3)
                let initial = try state(solver, to: output.appending(path: "initial.bin"), measure: measure)
                let target = 0.6
                let time = (pow(target / 1.033, 5)).squareRoot()
                let result = solver.advance(until: time)
                let final = try state(solver, to: output.appending(path: "final.bin"), measure: measure)
                func shockRadius(_ direction: SIMD3<Int>) -> Double {
                    var front = 0
                    for n in 0..<cells
                    where solver.primitive(n * direction.x, n * direction.y, n * direction.z).density > 2 {
                        front = n
                    }
                    let step = simd_length(
                        SIMD3<Float>(Float(direction.x), Float(direction.y), Float(direction.z)))
                    return Double((Float(front) + 0.5) * dx * step)
                }
                let axis = shockRadius(SIMD3(1, 0, 0))
                let diagonal = shockRadius(SIMD3(1, 1, 1))
                let axisError = abs(axis - target) / target
                let diagonalError = abs(diagonal - target) / target
                let peak = (0..<cells).map { solver.primitive($0, 0, 0).density }.max() ?? 0
                try record([
                    "id": name, "problem": "sedov", "preciseSelector": precise,
                    "cells": cells, "shape": [cells, cells, cells, 5], "dtype": "<f4",
                    "fields": ["density", "momentumX", "momentumY", "momentumZ", "energy"],
                    "time": solver.time, "requestedTime": time, "steps": solver.stepCount,
                    "stable": result.isStable,
                    "axisRadius": number(axis), "diagonalRadius": number(diagonal),
                    "axisRelativeError": number(axisError), "diagonalRelativeError": number(diagonalError),
                    "peakDensity": number(Double(peak)), "radiusRelativeBound": 0.04,
                    "initialTotals": totals(initial), "finalTotals": totals(final),
                    "passed": result.isStable && axisError < 0.04 && diagonalError < 0.04 && peak > 2.5
                        && peak < 6.5,
                ])
                #expect(result.isStable)
                #expect(axisError < 0.04 && diagonalError < 0.04, "\(name): original Sedov radius bounds")
                #expect(peak > 2.5 && peak < 6.5, "\(name): original peak-density bounds")
            }
        }
    }
}
