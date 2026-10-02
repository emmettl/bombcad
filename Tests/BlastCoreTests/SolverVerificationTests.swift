import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Verification of the Euler solver against problems with known solutions.
@Suite("Solver verification")
struct SolverVerificationTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    // MARK: Sod shock tube

    /// Exact density of Sod's problem (gamma = 1.4) at position `x` and time `t`, diaphragm at 0.5.
    private func sodDensity(x: Double, t: Double) -> Double {
        let gamma = 1.4
        let soundLeft = gamma.squareRoot()
        let starVelocity = 0.927_45
        let xi = (x - 0.5) / t
        if xi < -soundLeft { return 1 }
        if xi < -0.070_27 {
            let velocity = 2 / (gamma + 1) * (soundLeft + xi)
            let sound = soundLeft - 0.5 * (gamma - 1) * velocity
            return pow(sound / soundLeft, 2 / (gamma - 1))
        }
        if xi < starVelocity { return 0.426_32 }
        if xi < 1.752_16 { return 0.265_57 }
        return 0.125
    }

    @Test("Sod shock tube converges to the exact solution", arguments: RiemannSolver.allCases)
    func sodShockTube(riemannSolver: RiemannSolver) throws {
        let cells = 400
        var configuration = SolverConfiguration()
        configuration.reflectiveFaces = []
        configuration.riemannSolver = riemannSolver
        configuration.pressureFloor = 1e-6
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: cells, ny: 1, nz: 1, cellSize: 1 / Float(cells)),
            configuration: configuration)
        solver.fill { i, _, _ in
            i < cells / 2 ? Primitive(density: 1, pressure: 1) : Primitive(density: 0.125, pressure: 0.1)
        }

        let result = solver.advance(until: 0.2)
        #expect(result.isStable)
        #expect(abs(solver.time - 0.2) < 1e-5)

        let error = solver.withState { state in
            (0..<cells).reduce(0.0) { sum, i in
                let x = (Double(i) + 0.5) / Double(cells)
                return sum + abs(Double(state[i].density) - sodDensity(x: x, t: solver.time))
            } / Double(cells)
        }
        #expect(error < 0.004, "L1 density error \(error)")
    }

    @Test("Sod shock tube gives the same answer along every axis")
    func sodIsAxisIndependent() throws {
        let cells = 128
        var profiles: [[Float]] = []
        for axis in 0..<3 {
            var configuration = SolverConfiguration()
            configuration.reflectiveFaces = []
            let grid = Grid(
                nx: axis == 0 ? cells : 3, ny: axis == 1 ? cells : 3, nz: axis == 2 ? cells : 3,
                cellSize: 1 / Float(cells))
            let solver = try BlastSolver(device: device, grid: grid, configuration: configuration)
            solver.fill { i, j, k in
                [i, j, k][axis] < cells / 2
                    ? Primitive(density: 1, pressure: 1) : Primitive(density: 0.125, pressure: 0.1)
            }
            solver.advance(until: 0.15)
            profiles.append(
                (0..<cells).map { n in
                    let cell = [axis == 0 ? n : 1, axis == 1 ? n : 1, axis == 2 ? n : 1]
                    return solver.primitive(cell[0], cell[1], cell[2]).density
                })
        }
        for n in 0..<cells {
            #expect(abs(profiles[0][n] - profiles[1][n]) < 2e-3)
            #expect(abs(profiles[0][n] - profiles[2][n]) < 2e-3)
        }
    }

    // MARK: Rigid walls

    enum WallKind: CaseIterable {
        case solidCells
        case domainFace
    }

    @Test(
        "A shock reflecting off a rigid wall reaches the Rankine-Hugoniot pressure",
        arguments: WallKind.allCases)
    func normalShockReflection(wall: WallKind) throws {
        let gamma: Float = 1.4
        let ambient = Primitive(density: 1.225, pressure: 101_325)
        let ratio: Float = 3  // incident shock pressure ratio p1 / p0

        // Rankine-Hugoniot state behind a shock of that strength moving into still air.
        let sound = (gamma * ambient.pressure / ambient.density).squareRoot()
        let densityRatio = ((gamma + 1) * ratio + (gamma - 1)) / ((gamma - 1) * ratio + (gamma + 1))
        let speed = sound * (ratio - 1) * (2 / gamma / ((gamma + 1) * ratio + (gamma - 1))).squareRoot()
        let shocked = Primitive(
            density: ambient.density * densityRatio, velocity: SIMD3(speed, 0, 0),
            pressure: ambient.pressure * ratio)
        let reflectedRatio = ((3 * gamma - 1) * ratio - (gamma - 1)) / ((gamma - 1) * ratio + (gamma + 1))
        let expected = shocked.pressure * reflectedRatio

        let cells = 400
        let wallCells = wall == .solidCells ? 4 : 0
        var configuration = SolverConfiguration()
        configuration.reflectiveFaces = wall == .domainFace ? [.xMax] : []
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: cells, ny: 1, nz: 1, cellSize: 0.01), configuration: configuration)
        solver.mutateMask { mask in
            for i in (cells - wallCells)..<cells { mask[i] = 1 }
        }
        solver.fill { i, _, _ in i < 100 ? shocked : ambient }

        // The shock (561 m/s) reaches the wall after about 5.3 ms.
        solver.advance(until: 0.007)

        let wallCell = cells - wallCells - 1
        let atWall = solver.primitive(wallCell, 0, 0)
        #expect(abs(atWall.pressure - expected) / expected < 0.02, "wall pressure \(atWall.pressure)")
        #expect(abs(atWall.velocity.x) < 2, "gas at the wall should be at rest")
        // The recorded peak includes the brief numerical overshoot at the moment of reflection.
        let peak = solver.peakOverpressure(wallCell, 0, 0)
        let expectedPeak = expected - ambient.pressure
        #expect(peak >= expectedPeak * 0.98 && peak < expectedPeak * 1.1, "peak overpressure \(peak)")
    }

    @Test("Still air around obstacles stays still")
    func ambientIsPreserved() throws {
        var scenario = ScenarioPreset.streetCanyon.scenario
        scenario.charge.mass = 0
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 1)
        solver.advance(steps: 20)

        let (maxMomentum, maxPressureError) = solver.withState { state in
            var momentum: Float = 0
            var pressure: Float = 0
            for k in 0..<solver.grid.nz {
                for j in 0..<solver.grid.ny {
                    for i in 0..<solver.grid.nx where !solver.isSolid(i, j, k) {
                        let cell = state[solver.grid.index(i, j, k)]
                        momentum = max(
                            momentum, abs(cell.momentumX), abs(cell.momentumY), abs(cell.momentumZ))
                        pressure = max(
                            pressure, abs(cell.primitive(gamma: 1.4).pressure - scenario.atmosphere.pressure))
                    }
                }
            }
            return (momentum, pressure)
        }
        #expect(maxMomentum < 1e-3)
        #expect(maxPressureError < 0.1)
        #expect(solver.time > 0)
    }

    // MARK: Conservation and symmetry

    @Test("Mass and energy are conserved in a closed box with an obstacle")
    func conservation() throws {
        var scenario = Scenario(
            name: "Closed box", domainSize: SIMD3(24, 20, 16),
            boxes: [Box(x: 13...18, y: 6...14, height: 9)],
            charge: Charge(mass: 5, position: SIMD3(8, 10, 1)))
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)

        let before = solver.totals()
        let result = solver.advance(steps: 200)
        let after = solver.totals()

        #expect(result.isStable)
        #expect(result.steps == 200)
        #expect(abs(after.mass - before.mass) / before.mass < 1e-4)
        #expect(abs(after.energy - before.energy) / before.energy < 1e-4)
    }

    @Test("A centred burst in a closed cube stays mirror-symmetric")
    func mirrorSymmetry() throws {
        var scenario = Scenario(
            name: "Cube", domainSize: SIMD3(20, 20, 20), boxes: [],
            charge: Charge(mass: 2, position: SIMD3(10, 10, 10)))
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        solver.advance(steps: 80)

        let n = solver.grid.nx
        let worst = solver.withState { state in
            var worst: Float = 0
            for k in 0..<n {
                for j in 0..<n {
                    for i in 0..<n / 2 {
                        let here = state[solver.grid.index(i, j, k)].density
                        let mirrorX = state[solver.grid.index(n - 1 - i, j, k)].density
                        let mirrorY = state[solver.grid.index(i, n - 1 - j, k)].density
                        let mirrorZ = state[solver.grid.index(i, j, n - 1 - k)].density
                        worst = max(worst, abs(here - mirrorX) / here, abs(here - mirrorY) / here)
                        worst = max(worst, abs(here - mirrorZ) / here)
                    }
                }
            }
            return worst
        }
        #expect(worst < 1e-3, "largest relative asymmetry \(worst)")
    }

    // MARK: Sedov-Taylor point blast

    @Test("A strong point blast follows the Sedov-Taylor similarity law")
    func sedovTaylor() throws {
        // One octant of a spherical blast: symmetry planes on the low faces, outflow elsewhere.
        let cells = 80
        let dx = 1 / Float(cells)
        var configuration = SolverConfiguration()
        configuration.reflectiveFaces = [.xMin, .yMin, .zMin]
        configuration.pressureFloor = 1e-9
        configuration.ambientPressure = 1e-4
        let grid = Grid(nx: cells, ny: cells, nz: cells, cellSize: dx)
        let solver = try BlastSolver(device: device, grid: grid, configuration: configuration)

        let energy: Float = 1  // of the full sphere; the octant holds one eighth
        let radius = 3.5 * dx
        var sourceCells = 0
        for k in 0..<8 {
            for j in 0..<8 {
                for i in 0..<8 where simd_length(grid.cellCentre(i, j, k)) < radius { sourceCells += 1 }
            }
        }
        let sourcePressure = (energy / 8) * 0.4 / (Float(sourceCells) * dx * dx * dx)
        solver.fill { i, j, k in
            Primitive(
                density: 1,
                pressure: simd_length(grid.cellCentre(i, j, k)) < radius ? sourcePressure : 1e-4)
        }

        // R(t) = xi0 (E t^2 / rho)^(1/5) with xi0 = 1.033 for gamma = 1.4; pick t so that R = 0.6.
        let target = 0.6
        let time = (pow(target / 1.033, 5)).squareRoot()
        let result = solver.advance(until: time)
        #expect(result.isStable)

        /// Radius of the outermost point along a ray where the density exceeds 2.
        func shockRadius(direction: SIMD3<Int>) -> Double {
            var front = 0
            for n in 0..<cells
            where solver.primitive(n * direction.x, n * direction.y, n * direction.z).density > 2 {
                front = n
            }
            let step = simd_length(SIMD3<Float>(Float(direction.x), Float(direction.y), Float(direction.z)))
            return Double((Float(front) + 0.5) * dx * step)
        }
        let alongAxis = shockRadius(direction: SIMD3(1, 0, 0))
        let alongDiagonal = shockRadius(direction: SIMD3(1, 1, 1))
        #expect(abs(alongAxis - target) / target < 0.04, "axis radius \(alongAxis)")
        #expect(abs(alongDiagonal - target) / target < 0.04, "diagonal radius \(alongDiagonal)")

        // The strong-shock limit compresses the gas sixfold, but the density spike behind the
        // front is only a few cells wide at this resolution, so the captured peak is lower.
        let peakDensity = (0..<cells).map { solver.primitive($0, 0, 0).density }.max() ?? 0
        #expect(peakDensity > 2.5 && peakDensity < 6.5, "peak density \(peakDensity)")
    }
}
