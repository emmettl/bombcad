import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

@Suite("Congestion below the grid", .serialized, .gpuThreads)
struct CongestionTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// A rig's lattice: 43 mm pipes at 0.2 m along all three axes (MERGE's array A).
    static let lattice = CongestionArray(
        name: "Lattice", region: Box(min: SIMD3(1, 1, 1), max: SIMD3(3, 3, 3)), diameter: 0.043, pitch: 0.2,
        axes: [0, 1, 2])

    private func solver(_ scenario: Scenario, cellSize: Float, periodic: Bool = false) throws -> BlastSolver {
        var configuration = SolverConfiguration()
        configuration.skipStillAir = false
        configuration.periodicSides = periodic
        return try BlastSolver(
            device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
    }

    private func closedBox(_ arrays: [CongestionArray]) -> Scenario {
        var scenario = Scenario(
            name: "Box", domainSize: SIMD3(4, 4, 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(0.5, 0.5, 0.5)))
        scenario.reflectiveFaces = .all
        scenario.congestion = arrays
        return scenario
    }

    @Test("The array's fields: its volume blockage, drag, turbulence generation, length scale and counts")
    func fields() {
        let array = Self.lattice
        // Three sets of 43 mm pipes at 0.2 m: 3 × π 0.043² / 4 / 0.2² = 10.9%, MERGE's 10%
        // nominal less the joints counted twice.
        #expect(abs(array.volumeBlockage - 0.1089) < 0.001)
        let field = CongestionField(arrays: [array], grid: Grid(nx: 16, ny: 16, nz: 16, cellSize: 0.25))
        let index = 8 + 16 * (8 + 16 * 8)
        let inside = field.porosityDrag[index]
        #expect(abs(inside.x - (1 - array.volumeBlockage)) < 1e-5)
        // Across x, the pipes along y and z: 2 × 0.043 / 0.2² m⁻¹ of frontal area; the row's
        // blockage, as PDRsetFields idealises a cell's obstacles, 2 × 0.043 / (√3 × 0.2) = 0.248,
        // so its factor (1 − 0.124)/(0.752)² = 1.550; C_D 1.2, and ½.
        let area = 2 * 0.043 / 0.04
        let factor = 1.550
        #expect(abs(inside.y / Float(0.5 * 1.2 * factor * area) - 1) < 0.002, "\(inside.y)")
        #expect(inside.y == inside.z && inside.z == inside.w)
        // CT, C_b 0.035 of the drag; L_obs the pipes' diameter, the blockage per obstacle across
        // the flow (2 × 0.043 × 0.25 / 0.04 over 2 × 1.25²) times the cell's width.
        let made = field.generation[index]
        #expect(abs(made.x / Float(0.035 * 1.2 * factor * area) - 1) < 0.002, "\(made.x)")
        #expect(abs(made.w - 0.043) < 1e-5, "\(made.w)")
        // B across x, 0.5375; the count crossing the cell, 3 × 1.25² less the 1.25² all three axes
        // share, which leaves none counted along any one.
        #expect(abs(field.blockage[index].x - 0.5375) < 1e-4)
        #expect(abs(field.blockage[index].w - 3.125) < 1e-4)
        #expect(field.parallel[index].x == 0 && field.parallel[index].y == 0)
        #expect(abs(field.parallel[index].w - Float(3 * Double.pi * 0.043 / 0.04)) < 1e-3)
        // Outside the region, nothing; the length scale the cell's size.
        #expect(field.porosityDrag[0] == SIMD4(1, 0, 0, 0))
        #expect(field.generation[0] == SIMD4(0, 0, 0, 0.25))
        // A rack's tier, pipes along x only: a flow along them meets none.
        let tier = CongestionArray(
            region: Box(min: .zero, max: SIMD3(4, 4, 1)), diameter: 0.1, pitch: 0.5, axes: [0])
        let rack = CongestionField(arrays: [tier], grid: Grid(nx: 8, ny: 8, nz: 4, cellSize: 0.5))
        #expect(rack.porosityDrag[0].y == 0 && rack.porosityDrag[0].z > 0)
        #expect(rack.parallel[0].x == 1 && rack.blockage[0].w == 1)
    }

    @Test("On cells smaller than the pitch the counts and blockage are a pitch's, not the cell's")
    func countsOverAPitch() {
        let field = CongestionField(arrays: [Self.lattice], grid: Grid(nx: 40, ny: 40, nz: 40, cellSize: 0.1))
        let index = 20 + 40 * (20 + 40 * 20)
        // Over a 0.2 m unit cell: one pipe of each set crosses it, the three counts sharing one, so
        // two across any flow; each crossing set blocks 0.043 / 0.2 of its face.
        #expect(abs(field.blockage[index].w - 2) < 1e-4)
        #expect(abs(field.blockage[index].x - 2 * 0.043 / 0.2) < 1e-4)
        #expect(field.unitWidth[index] == 0.2)
        #expect(abs(field.generation[index].w - 0.043) < 1e-5)
        // The drag and generation per volume do not depend on the cell.
        let coarse = CongestionField(
            arrays: [Self.lattice], grid: Grid(nx: 16, ny: 16, nz: 16, cellSize: 0.25))
        let inside = 8 + 16 * (8 + 16 * 8)
        #expect(abs(field.porosityDrag[index].y / coarse.porosityDrag[inside].y - 1) < 1e-5)
        #expect(abs(field.generation[index].x / coarse.generation[inside].x - 1) < 1e-5)
    }

    @Test("MERGE's rigs: their lattices hold a tenth of their volume, the scene its cloud and gauges")
    func mergeRigs() {
        for rig in MergeRig.allCases {
            let lattice = rig.congestion(at: .zero)
            #expect(abs(lattice.volumeBlockage - 0.1) < 0.012, "\(rig.name) \(lattice.volumeBlockage)")
            let study = CongestedRigStudy(rig: rig, gas: .methane, cellSize: rig.pitch)
            let scenario = study.scenario()
            #expect(scenario.congestion?.count == 1)
            #expect(scenario.deflagration?.region == scenario.congestion?.first?.region)
            #expect(scenario.gauges.count == 8)
        }
    }

    @Test("Still air in and around porous cells stays still")
    func stillAirStaysStill() throws {
        let solver = try solver(closedBox([Self.lattice]), cellSize: 0.25)
        solver.fill(uniform: Primitive(density: 1.225, pressure: 101_325))
        solver.restart()
        solver.advance(steps: 60)
        var fastest: Float = 0
        var furthest: Float = 0
        for k in 0..<16 {
            for j in 0..<16 {
                for i in 0..<16 {
                    let air = solver.primitive(i, j, k)
                    fastest = max(fastest, simd_length(air.velocity))
                    furthest = max(furthest, abs(air.pressure - 101_325))
                }
            }
        }
        #expect(fastest < 1e-4, "\(fastest) m/s")
        #expect(furthest < 0.05, "\(furthest) Pa")
    }

    @Test("The porous cells conserve the air's mass, β_v ρ summed, as a pulse crosses them")
    func massConserved() throws {
        let scenario = closedBox([Self.lattice])
        let solver = try solver(scenario, cellSize: 0.25)
        solver.mutateState { cells in
            for k in 0..<16 {
                for j in 0..<16 {
                    for i in 0..<16 {
                        let high = i < 4
                        cells[solver.grid.index(i, j, k)] = CellState(
                            Primitive(density: high ? 2.0 : 1.225, pressure: high ? 300_000 : 101_325),
                            gamma: 1.4)
                    }
                }
            }
        }
        solver.restart()
        // The totals count each porous cell's open share.
        func mass() -> Double { solver.totals().mass }
        let before = mass()
        let result = solver.advance(steps: 80)
        #expect(result.isStable)
        #expect(abs(mass() / before - 1) < 2e-6, "\(mass() / before - 1)")
    }

    @Test("A uniform stream through the obstacles slows as their drag has it, u = u₀ / (1 + ½ CR u₀ t / β_v)")
    func dragSlowsStream() throws {
        var scenario = Scenario(
            name: "Stream", domainSize: SIMD3(2, 2, 1), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(0.1, 0.1, 0.1)))
        scenario.reflectiveFaces = .all
        scenario.congestion = [
            CongestionArray(
                region: Box(min: .zero, max: SIMD3(2, 2, 1)), diameter: 0.02, pitch: 0.2, axes: [2])
        ]
        let solver = try solver(scenario, cellSize: 0.25, periodic: true)
        let speed: Float = 20
        solver.fill(uniform: Primitive(density: 1.225, velocity: SIMD3(speed, 0, 0), pressure: 101_325))
        solver.restart()
        let field = CongestionField(arrays: scenario.congestion!, grid: solver.grid)
        let cell = field.porosityDrag[solver.grid.index(4, 4, 2)]
        solver.advance(until: 0.05)
        // Over the cell's open volume, β_v.
        let expected = speed / (1 + cell.y / cell.x * speed * Float(solver.time))
        let measured = solver.primitive(4, 4, 2).velocity.x
        #expect(abs(measured / expected - 1) < 0.01, "\(measured) against \(expected) m/s")
        #expect(measured < 0.99 * speed)
    }

    /// The obstacle turbulence's equations (PDRFoam's PDRkEpsilon with its obstacle terms) for a
    /// uniform stream, integrated finely here: k and ε at `time`, the stream's speed `speed(t)`.
    private func integrated(
        _ cell: (porosity: Float, generation: SIMD4<Float>, wall: Float), until time: Double,
        speed: (Double) -> Double
    ) -> SIMD2<Double> {
        var k = 1e-6
        var epsilon = 1e-7
        let steps = 200_000
        let dt = time / Double(steps)
        let porosity = Double(cell.porosity)
        let wall = Double(cell.wall)
        for n in 0..<steps {
            let u = speed((Double(n) + 0.5) * dt)
            let nu = 1.5e-5 + 0.09 * k * k / epsilon
            let made =
                (0.5 * u * u * u * Double(cell.generation.x) + 0.05 * porosity * nu * wall * wall * u * u)
                / porosity
            let epsilonMade =
                1.5 * pow(0.09, 0.75) * made * k.squareRoot() / (0.1 * Double(cell.generation.w))
            let rate = epsilon / k
            k = (k + dt * made) / (1 + dt * rate)
            epsilon = (epsilon + dt * epsilonMade) / (1 + dt * 1.92 * rate)
        }
        return SIMD2(k, epsilon)
    }

    @Test("A stream through a rack makes obstacle turbulence as PDRFoam's k-ε has it, near its equilibrium")
    func turbulenceInStream() throws {
        var scenario = Scenario(
            name: "Stream", domainSize: SIMD3(2, 2, 1), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(0.1, 0.1, 0.1)))
        scenario.reflectiveFaces = .all
        scenario.congestion = [
            CongestionArray(
                region: Box(min: .zero, max: SIMD3(2, 2, 1)), diameter: 0.005, pitch: 0.2, axes: [2])
        ]
        let solver = try solver(scenario, cellSize: 0.25, periodic: true)
        let speed: Float = 20
        solver.fill(uniform: Primitive(density: 1.225, velocity: SIMD3(speed, 0, 0), pressure: 101_325))
        solver.restart()
        let field = CongestionField(arrays: scenario.congestion!, grid: solver.grid)
        let index = solver.grid.index(4, 4, 2)
        let porosity = field.porosityDrag[index].x
        let drag = Double(field.porosityDrag[index].y / porosity)
        solver.advance(until: 0.05)
        let measured = try #require(solver.obstacleTurbulence())[index]
        let time = solver.time
        let expected = integrated(
            (porosity, field.generation[index], field.parallel[index].w), until: time,
            speed: { Double(speed) / (1 + drag * Double(speed) * $0) })
        #expect(abs(Double(measured.x) / expected.x - 1) < 0.03, "k \(measured.x) against \(expected.x)")
        #expect(abs(Double(measured.y) / expected.y - 1) < 0.05, "ε \(measured.y) against \(expected.y)")
        // Near the generation's equilibrium at the stream's speed now, where ε is G_R and
        // 1.5 C_μ^(3/4) k^(3/2) / (C_2 C_4 L_obs): k as (G_R C_2 C_4 L_obs / (1.5 C_μ^(3/4)))^(2/3).
        let now = Double(solver.primitive(4, 4, 2).velocity.x)
        let made = 0.5 * now * now * now * Double(field.generation[index].x) / Double(porosity)
        let equilibrium = pow(
            made * 1.92 * 0.1 * Double(field.generation[index].w) / (1.5 * pow(0.09, 0.75)), 2.0 / 3)
        #expect(abs(Double(measured.x) / equilibrium - 1) < 0.2, "k \(measured.x) against \(equilibrium)")
    }

    @Test("The obstacles' turbulence is carried downstream of them and decays there")
    func turbulenceCarried() throws {
        var scenario = Scenario(
            name: "Stream", domainSize: SIMD3(4, 1, 1), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(0.1, 0.1, 0.1)))
        scenario.reflectiveFaces = .all
        scenario.congestion = [
            CongestionArray(
                region: Box(min: .zero, max: SIMD3(0.5, 1, 1)), diameter: 0.02, pitch: 0.1, axes: [1, 2])
        ]
        let solver = try solver(scenario, cellSize: 0.125, periodic: true)
        solver.fill(uniform: Primitive(density: 1.225, velocity: SIMD3(20, 0, 0), pressure: 101_325))
        solver.restart()
        solver.advance(until: 0.06)
        let turbulence = try #require(solver.obstacleTurbulence())
        let row = (0..<solver.grid.nx).map { turbulence[solver.grid.index($0, 4, 4)].x }
        // The rack holds cells 0–3; its gas has moved on about 1.1 m (9 cells) since.
        let inRack = row[3]
        #expect(inRack > 1, "\(row)")
        #expect(row[6] > 1e-3 * inRack, "\(row)")
        #expect(row[6] < inRack && row[9] < row[6], "\(row)")
        // Far ahead of where the rack's gas has reached, little more than the scheme's diffusion
        // carries.
        #expect(row[24] < 1e-3 * inRack, "\(row)")
    }

    @Test(
        "A flame burning through a lattice runs faster than in the open, by the obstacles' turbulence and folding"
    )
    func flameInLattice() throws {
        func burnt(congested: Bool) throws -> Double {
            var scenario = Scenario(
                name: "Channel", domainSize: SIMD3(3, 1, 1), boxes: [],
                charge: Charge(mass: 0, position: .zero))
            scenario.reflectiveFaces = BoundaryFaces.all.subtracting(.xMax)
            scenario.deflagration = Deflagration(
                gas: .methane, region: Box(min: .zero, max: SIMD3(2, 1, 1)), ignition: SIMD3(0, 0.5, 0.5))
            if congested {
                scenario.congestion = [
                    CongestionArray(
                        region: Box(min: .zero, max: SIMD3(2, 1, 1)), diameter: 0.02, pitch: 0.1,
                        axes: [1, 2])
                ]
            }
            let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.05)
            solver.advance(until: 0.2)
            return try #require(solver.deflagrationState()).burntFraction
        }
        let open = try burnt(congested: false)
        let lattice = try burnt(congested: true)
        // Over 0.2 s the lattice's flame burns nearly the whole cloud, the open one a fiftieth of it.
        #expect(lattice > 10 * open, "\(lattice) burnt in the lattice, \(open) in the open")
    }
}
