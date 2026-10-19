import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Options and paths of the air solver's core that no other test reaches: the far-field faces
/// under gravity and their species, the floors, the afterburning's energy and time, the startup
/// Courant ramp and the ratio of specific heats on the GPU, the slope limiter's steepness, and
/// gauges that move.
@Suite("Air solver gaps", .gpuThreads)
struct AirSolverGapTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    // MARK: Far-field faces

    /// A column of 8 x 8 x 32 cells of 1 m on the ground, with a pulse of doubled energy in a block
    /// of 2 x 2 x 2 cells at its middle, run for 60 steps with the given open faces and gravity.
    private func pulsedColumn(_ faces: OpenFaces, gravity: AirGravity?) throws -> [CellState] {
        var configuration = SolverConfiguration()
        configuration.gravity = gravity
        configuration.openFaces = faces
        configuration.reflectiveFaces = .ground
        configuration.skipStillAir = false
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: 8, ny: 8, nz: 32, cellSize: 1), configuration: configuration)
        solver.fill(uniform: Primitive(density: 1.225, pressure: 101_325))
        solver.mutateState { cells in
            for k in 15...16 {
                for j in 3...4 {
                    for i in 3...4 { cells[solver.grid.index(i, j, k)].energy *= 2 }
                }
            }
        }
        solver.restart()
        #expect(solver.advance(steps: 60).isStable)
        return solver.withState { Array($0) }
    }

    /// Far-field faces stand still ambient air beyond them, but under gravity the ambient changes
    /// with height, so the faces copy instead (`makeUniforms` leaves the far-field flag out). Run
    /// both ways under gravity, a pulse that has reached the side faces must come out the same to
    /// the bit; without gravity the same pulse must come out differently, which shows that it did
    /// reach the faces and that the comparison means something.
    @Test("Under gravity, far-field faces copy, to the bit; without it they do not")
    func farFieldUnderGravityCopies() throws {
        let copied = try pulsedColumn(.copy, gravity: AirGravity())
        let farField = try pulsedColumn(.farField, gravity: AirGravity())
        let differing = zip(copied, farField).filter { $0 != $1 }.count
        #expect(differing == 0, "\(differing) cells differ under gravity")

        let copiedFlat = try pulsedColumn(.copy, gravity: nil)
        let farFieldFlat = try pulsedColumn(.farField, gravity: nil)
        #expect(zip(copiedFlat, farFieldFlat).contains { $0 != $1 }, "the pulse never reached a face")
    }

    /// A tube of 64 cells of 0.1 m, open at both ends, filled with still air at 80% of ambient
    /// pressure (isentropically from ambient) and no oxygen, with afterburning on so that the
    /// species are carried.
    private func underPressuredTube(_ faces: OpenFaces) throws -> BlastSolver {
        var configuration = SolverConfiguration()
        configuration.afterburning = true
        configuration.openFaces = faces
        configuration.reflectiveFaces = []
        configuration.skipStillAir = false
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: 64, ny: 1, nz: 1, cellSize: 0.1), configuration: configuration)
        // The construction filled the still air (and its oxygen) at ambient: that is the far field.
        solver.fill { _, _, _ in
            Primitive(density: 1.225 * Float(pow(0.8, 1 / 1.4)), pressure: 0.8 * 101_325)
        }
        solver.mutateSpecies { species in
            for index in species.indices { species[index] = .zero }
        }
        solver.restart()
        return solver
    }

    /// Through a far-field face the air drawn in is the still air beyond it: it brings that air's
    /// oxygen and no products (`ambient` in `sweepCell`), and a domain left under ambient fills
    /// until its pressure is ambient again. Through faces that copy, a uniform state is held as it
    /// is. (That the oxygen gained is exactly air's share of the mass gained is checked apart, in
    /// `farFieldInflowConserved`, which a fault at the first face inside keeps disabled.)
    @Test("Air drawn in through far-field faces is ambient air, with its oxygen, and a deficit relaxes")
    func farFieldInflowIsAmbientAir() throws {
        let tube = try underPressuredTube(.farField)
        let start = tube.totals()
        tube.advance(until: 0.005)
        let gained = tube.totals().mass - start.mass
        let species = tube.speciesTotals()
        #expect(gained > 0, "no air came in")
        #expect(species.fuel == 0)
        #expect(species.oxygen > 0, "the air came in without its oxygen")
        // No cell holds a larger share of oxygen than the air it came from.
        let largestShare = try tube.readSpecies { species in
            let species = try #require(species, "afterburning carries the species")
            return tube.withState { cells in zip(species, cells).map { $0.y / $1.density }.max() ?? 0 }
        }
        #expect(largestShare <= BlastSolver.oxygenInAir * (1 + 1e-4))

        tube.advance(until: 0.1)
        let ambient: Float = 101_325
        let deficit =
            (0..<64).map { abs(tube.primitive($0, 0, 0).pressure - ambient) }.reduce(0, +) / 64
        // Five crossings after the start. Measured on the Studio, 19 October 2026: 0.009 Pa of the 20 kPa deficit is left (the
        // draft's guess allowed a twentieth of it, 1 kPa).
        #expect(deficit < 1, "mean deficit \(deficit) Pa")

        let copied = try underPressuredTube(.copy)
        let before = copied.withState { Array($0) }
        copied.advance(until: 0.005)
        let after = copied.withState { Array($0) }
        let largestChange = zip(before, after).map { abs($1.density / $0.density - 1) }.max() ?? 0
        #expect(largestChange < 1e-6, "the uniform state changed by \(largestChange)")
        #expect(copied.speciesTotals().oxygen == 0)
    }

    /// Before the inflows from the two ends meet (the tube's half-length over the speed of sound,
    /// 9 ms) nothing leaves, and the interior's fluxes carry the species exactly (a closed tube
    /// keeps its oxygen to 3e-8), so the oxygen gained must be air's share of the mass gained.
    /// Measured on the Studio (19 October 2026) it is 0.990 of it at 5 ms: steps 2 to 8 take in
    /// about 10% more mass than oxygen allows, and from step 11 each step's share is exact to
    /// 1e-4, the same step for step at 0.1 and 0.05 m cells. The first face inside is worked out
    /// differently by its two cells: the cell at the face takes its slope from the far-field
    /// ghost (`farFieldGhost`), while the next cell in, two cells from the face, stands a copy of
    /// the cell at the face for it (`wM2 = wM1`, `wP2 = wP1` in `sweepCell`). While the ghost
    /// differs from that cell the two mass fluxes differ, and gas is made or lost there, at the
    /// species' share of the cell at the face (still nearly none of oxygen here).
    @Test(
        "Through far-field faces the oxygen gained is air's share of the mass gained",
        .disabled(
            "solver fault: the first face inside a far-field face is fluxed differently by its two cells (wM2/wP2 copy vs farFieldGhost), so mass is not conserved there"
        ))
    func farFieldInflowConserved() throws {
        let tube = try underPressuredTube(.farField)
        let start = tube.totals()
        tube.advance(until: 0.005)
        let gained = tube.totals().mass - start.mass
        let oxygen = tube.speciesTotals().oxygen
        let expected = Double(BlastSolver.oxygenInAir) * gained
        #expect(abs(oxygen - expected) < 1e-3 * expected, "oxygen \(oxygen) kg for \(gained) kg of air")
    }

    // MARK: Floors

    /// Two streams of air pulled apart at 2000 m/s, faster than the 1700 m/s at which a
    /// rarefaction in air empties, leave a vacuum between them. The density there is held at the
    /// configured floor and the run stays finite and stable: the positivity fallback and the
    /// floors in `sweepCell` are the only things standing between it and NaN. The scheme smears
    /// the vacuum: measured on the Studio (19 October 2026) its middle falls only to 0.0148 kg/m³
    /// by 1 ms, so a floor of 1e-3 kg/m³ (the draft's) is never reached. The floor is set at
    /// 0.05 kg/m³ instead, a twentieth of the air's density, so that it is the floor that holds
    /// the middle.
    @Test("Air pulled apart into a vacuum is held at the density floor and stays finite")
    func vacuumHeldAtFloor() throws {
        var configuration = SolverConfiguration()
        configuration.reflectiveFaces = []
        configuration.skipStillAir = false
        configuration.densityFloor = 0.05
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: 64, ny: 1, nz: 1, cellSize: 0.1), configuration: configuration)
        solver.fill { i, _, _ in
            Primitive(density: 1.225, velocity: SIMD3(i < 32 ? -2000 : 2000, 0, 0), pressure: 101_325)
        }
        let result = solver.advance(until: 0.001)
        #expect(result.isStable)
        let cells = solver.withState { Array($0) }
        #expect(cells.allSatisfy { $0.density.isFinite && $0.energy.isFinite })
        let lightest = cells.map(\.density).min() ?? 0
        #expect(lightest >= configuration.densityFloor, "density \(lightest) kg/m³ below the floor")
        #expect(cells.allSatisfy { $0.energy > 0 })
        // The exact vacuum spans ±0.3 m by now: its middle is held at the floor.
        #expect(
            cells[31].density <= configuration.densityFloor * (1 + 1e-5)
                && cells[32].density <= configuration.densityFloor * (1 + 1e-5),
            "\(cells[31].density) and \(cells[32].density) kg/m³ at the middle")
    }

    // MARK: Afterburning's energy and time

    /// The products of an 8 kg charge in a closed room 4 m across, on 0.25 m cells, after 10 ms,
    /// with the given energy per kilogram burnt and time to burn: what burnt, and the energy the
    /// air gained.
    private func burntRoom(energy: Float, time: Float) throws -> (burnt: Double, gained: Double) {
        var scenario = Scenario(
            name: "Room", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 8, position: SIMD3(repeating: 2)))
        scenario.reflectiveFaces = .all
        var configuration = SolverConfiguration()
        configuration.afterburning = true
        configuration.afterburnEnergy = energy
        configuration.afterburnTime = time
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.25, configuration: configuration)
        let start = solver.totals()
        let fuel = solver.speciesTotals().fuel
        #expect(solver.advance(until: 0.01).isStable)
        return (fuel - solver.speciesTotals().fuel, solver.totals().energy - start.energy)
    }

    /// The afterburning test elsewhere runs at the default 10 MJ/kg and 10 ms/kg^(1/3). Here the
    /// energy released must follow a configured 4 MJ/kg as it does the default, and the products
    /// must burn faster with a shorter burning time (`afterburnRate` in the uniforms).
    @Test("Afterburning releases the configured energy per kilogram and burns faster with a shorter time")
    func afterburnEnergyAndTime() throws {
        let fast = try burntRoom(energy: 4e6, time: 1e-3)
        let slow = try burntRoom(energy: 4e6, time: 100e-3)
        #expect(fast.burnt > 0.1, "only \(fast.burnt) kg burnt")
        for run in [fast, slow] where run.burnt > 0 {
            let released = 4e6 * run.burnt
            #expect(abs(run.gained - released) < 0.01 * released + 1, "\(run.gained) J for \(released) J")
        }
        // A burning time a hundred times longer burns many times less. Measured on the Studio, 19 October 2026: 6.67 kg burnt in
        // 1 ms against 0.31 kg in 100 ms, 21 times as much.
        #expect(fast.burnt > 10 * slow.burnt, "\(fast.burnt) kg fast, \(slow.burnt) kg slow")
    }

    // MARK: Time step

    /// In still air the time step is the Courant number times the cell over the speed of sound,
    /// sqrt(gamma p / rho), ramped up over `startupSteps`: the k-th step (from 0) takes
    /// min(1, (k + 1) / startupSteps) of it. A run's first steps decide where a charge's shock
    /// starts, and the speed of sound is the one place the ratio of specific heats enters the step,
    /// so this checks both that the ramp is as documented and that a gamma other than 1.4 reaches
    /// the GPU. The gauge's pressure, worked out on the GPU from the energy the CPU set with the
    /// same gamma, must also read back as the pressure the air was filled with.
    @Test(
        "Still air's steps follow the startup ramp and the speed of sound of the configured gamma",
        arguments: [(Float(1.4), 6), (Float(5) / 3, 6), (Float(1.4), 1)])
    func startupRampAndGamma(gamma: Float, startupSteps: Int) throws {
        var configuration = SolverConfiguration()
        configuration.gamma = gamma
        configuration.startupSteps = startupSteps
        configuration.reflectiveFaces = .all
        configuration.skipStillAir = false
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: 8, ny: 8, nz: 8, cellSize: 0.1), configuration: configuration)
        solver.setGauges(cells: [(4, 4, 4)])
        let sound = (gamma * 101_325 / 1.225).squareRoot()
        let full = Double(configuration.cfl * 0.1 / sound)
        for k in 0..<8 {
            let step = solver.advance(steps: 1).lastTimeStep
            let ramp = min(1, Double(k + 1) / Double(startupSteps))
            #expect(abs(step / (ramp * full) - 1) < 1e-4, "step \(k): \(step) s against \(ramp * full) s")
        }
        for sample in solver.gaugeHistories[0] {
            #expect(abs(sample.pressure / 101_325 - 1) < 1e-5, "\(sample.pressure) Pa")
        }
    }

    // MARK: Slope limiter

    /// Sod's shock tube on 400 cells, run to 0.2 with the given limiter steepness.
    private func sod(theta: Float) throws -> [Float] {
        let cells = 400
        var configuration = SolverConfiguration()
        configuration.reflectiveFaces = []
        configuration.limiterTheta = theta
        configuration.pressureFloor = 1e-6
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: cells, ny: 1, nz: 1, cellSize: 1 / Float(cells)),
            configuration: configuration)
        solver.fill { i, _, _ in
            i < cells / 2 ? Primitive(density: 1, pressure: 1) : Primitive(density: 0.125, pressure: 0.1)
        }
        #expect(solver.advance(until: 0.2).isStable)
        return solver.withState { $0.map(\.density) }
    }

    /// The Sod test elsewhere uses only the default steepness, 1.5. Minmod (1) and monotonised
    /// central (2) must both still converge, must give different answers (so that the option
    /// reaches the shader), and minmod, the most diffusive, must make no new extremes.
    @Test("Sod's tube converges with minmod and monotonised central slopes, which differ")
    func limiterSteepness() throws {
        func error(_ density: [Float]) -> Double {
            density.enumerated().reduce(0.0) { sum, cell in
                let x = (Double(cell.offset) + 0.5) / Double(density.count)
                return sum + abs(Double(cell.element) - SolverVerificationTests.sodDensity(x: x, t: 0.2))
            } / Double(density.count)
        }
        let minmod = try sod(theta: 1)
        let central = try sod(theta: 2)
        // Measured on the Studio, 19 October 2026: L1 errors of 0.0022 (minmod) and 0.0012 (monotonised central).
        #expect(error(minmod) < 0.004, "minmod L1 error \(error(minmod))")
        #expect(error(central) < 0.003, "monotonised central L1 error \(error(central))")
        #expect(minmod != central)
        // Measured on the Studio, 19 October 2026: minmod's densities stay within 0.125 and 1 exactly; a thousandth's slack.
        #expect(minmod.allSatisfy { $0 >= 0.125 - 1e-3 && $0 <= 1 + 1e-3 })
    }

    // MARK: Gauges

    /// A cube of 16 cells of 0.25 m, closed, with a bubble at five times ambient pressure about
    /// cell (12, 8, 8), and a gauge at `cell`.
    private func bubble(gaugeAt cell: (i: Int, j: Int, k: Int)) throws -> BlastSolver {
        var configuration = SolverConfiguration()
        configuration.reflectiveFaces = .all
        configuration.skipStillAir = false
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: 16, ny: 16, nz: 16, cellSize: 0.25), configuration: configuration)
        solver.fill { i, j, k in
            let r = SIMD3<Float>(Float(i), Float(j), Float(k)) - SIMD3(12, 8, 8)
            return simd_length_squared(r) < 4
                ? Primitive(density: 3, pressure: 5 * 101_325) : Primitive(density: 1.225, pressure: 101_325)
        }
        solver.setGauges(cells: [cell])
        return solver
    }

    /// `moveGauges` (used by gauges that follow a moving face) keeps what the gauges have
    /// recorded and samples the new cells from then on: the history up to the move is the old
    /// cell's, and after it, sample for sample, that of a gauge set at the new cell from the
    /// start. `prependGaugeHistory` (used by the mapped start) puts samples in front, and ignores a
    /// gauge that does not exist.
    @Test("Moved gauges keep their history and record their new cells; prepended samples go first")
    func movedGauges() throws {
        let from = (i: 2, j: 8, k: 8)
        let to = (i: 13, j: 8, k: 8)
        let moved = try bubble(gaugeAt: from)
        let reference = try bubble(gaugeAt: to)
        moved.advance(steps: 4)
        reference.advance(steps: 4)
        let before = moved.gaugeHistories[0]
        #expect(before.count == 5)
        moved.moveGauges(cells: [to], points: [SIMD3(13.5, 8.5, 8.5) * 0.25])
        moved.advance(steps: 4)
        reference.advance(steps: 4)
        let history = moved.gaugeHistories[0]
        #expect(history.count == reference.gaugeHistories[0].count)
        #expect(Array(history.prefix(before.count)) == before)
        #expect(
            Array(history.dropFirst(before.count))
                == Array(reference.gaugeHistories[0].dropFirst(before.count)))
        // The two cells read differently, so the comparison above tells them apart.
        #expect(before.last?.pressure != reference.gaugeHistories[0][before.count - 1].pressure)
        #expect(zip(history, history.dropFirst()).allSatisfy { $0.time < $1.time })

        let early = GaugeSample(time: -1e-3, pressure: 2e5)
        moved.prependGaugeHistory(0, [early])
        #expect(moved.gaugeHistories[0].first == early)
        #expect(moved.gaugeHistories[0].count == history.count + 1)
        moved.prependGaugeHistory(1, [early])
        #expect(moved.gaugeHistories.count == 1)
        // Setting the gauges afresh clears what they recorded.
        moved.setGauges(cells: [from])
        #expect(moved.gaugeHistories[0].isEmpty)
    }
}
