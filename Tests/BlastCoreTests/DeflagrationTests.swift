import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// A premixed gas cloud burning behind a flame front, and vent panels.
@Suite("Deflagration", .gpuThreads)
struct DeflagrationTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    @Test("An ignition point on a cell's corner lights one cell, whichever way the float rounds")
    func ignitionOnACorner() throws {
        // On 5 cm cells the middle of a 1 m box is a corner of eight cells.
        func burnt(length: Float) throws -> Double {
            var scenario = Scenario(
                name: "Ball", domainSize: SIMD3(repeating: length), boxes: [],
                charge: Charge(mass: 0, position: .zero))
            scenario.reflectiveFaces = .all
            scenario.deflagration = Deflagration(
                gas: .methane, region: Box(min: .zero, max: SIMD3(repeating: length)),
                ignition: SIMD3(repeating: length / 2), acceleration: .laminar)
            let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.05)
            solver.advance(until: 0.05)
            return try #require(solver.deflagrationState()).burntFraction * Double(length * length * length)
        }
        let small = try burnt(length: 1)
        let large = try burnt(length: 2)
        #expect(small > 0, "nothing burnt")
        #expect(abs(small / large - 1) < 0.02, "\(small) m³ against \(large) m³ of mixture burnt")
    }

    @Test(
        "A closed sphere burns to the AICC pressure, conserving energy, a little behind the thin-flame model")
    func closedVessel() throws {
        let study = ClosedVesselStudy(radius: 0.5, cellsPerRadius: 10)
        let result = try study.run(device: device)
        #expect(result.burntFraction > 0.995)
        #expect(abs(result.peakPressure / result.modelAICC - 1) < 0.01, "\(result.peakPressure)")
        #expect(abs(result.energyError) < 1e-3)
        // The front is a few cells thick, which delays a coarse flame.
        let lag = result.halfRise / result.referenceHalfRise
        #expect(
            lag > 1 && lag < 1.4,
            "half rise at \(result.halfRise) s, thin flame \(result.referenceHalfRise) s")
    }

    @Test(
        "A flame lit at the closed end of a tube runs at the expansion ratio times the burning velocity",
        arguments: [FlameAcceleration.laminar, FlameAcceleration(instability: nil)])
    func tubeFlameSpeed(acceleration: FlameAcceleration) throws {
        let dx: Float = 0.02
        let length: Float = 1.2
        let width = 4 * dx
        var scenario = Scenario(
            name: "Tube", domainSize: SIMD3(length, width, width), boxes: [],
            charge: Charge(mass: 0, position: .zero))
        scenario.reflectiveFaces = BoundaryFaces.all.subtracting(.xMax)
        scenario.deflagration = Deflagration(
            gas: .methane, region: Box(min: .zero, max: SIMD3(length, width, width)),
            ignition: SIMD3(0, width / 2, width / 2), acceleration: acceleration)
        // A flame in a narrow tube is one-dimensional, where the σ-model sees no turbulence (the
        // cellular instability, of a spherical flame, is left out).
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: dx)
        let grid = solver.grid
        func front() throws -> Float {
            let share = try #require(solver.unburntShare())
            let row = (0..<grid.nx).map { share[grid.index($0, 1, 1)] }
            let i = try #require(row.firstIndex { $0 >= 0.5 })
            let below = row[i - 1]
            return (Float(i) - 0.5 + (0.5 - below) / (row[i] - below)) * dx
        }
        solver.advance(until: 0.1)
        let first = try front()
        solver.advance(until: 0.2)
        let speed = (try front() - first) / 0.1
        let expected =
            scenario.deflagration!.modelExpansionRatio(
                atmosphere: Atmosphere(), airModel: .idealGas, gamma: 1.4)
            * scenario.deflagration!.laminarBurningVelocity
        #expect(abs(speed / expected - 1) < 0.1, "\(speed) m/s, expected \(expected)")
    }

    @Test(
        "The stall's options, an initial u' and the young flame's correction, each burn a young ball faster")
    func stallOptions() throws {
        func burnt(_ change: (inout FlameAcceleration) -> Void) throws -> Double {
            var scenario = Scenario(
                name: "Ball", domainSize: SIMD3(repeating: 1), boxes: [],
                charge: Charge(mass: 0, position: .zero))
            scenario.reflectiveFaces = .all
            var flame = FlameAcceleration(instability: nil)
            change(&flame)
            scenario.deflagration = Deflagration(
                gas: .methane, region: Box(min: .zero, max: SIMD3(repeating: 1)),
                ignition: SIMD3(repeating: 0.5), acceleration: flame)
            let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.05)
            solver.advance(until: 0.05)
            return try #require(solver.deflagrationState()).burntFraction
        }
        let plain = try burnt { _ in }
        let floored = try burnt { $0.initialTurbulence = 0.1 }
        let young = try burnt { $0.youngFlame = 0.75 }
        #expect(plain > 0, "nothing burnt")
        #expect(floored > 1.2 * plain, "\(floored) against \(plain)")
        #expect(young > 1.2 * plain, "\(young) against \(plain)")
    }

    @Test("A deflagration takes the species from afterburning and keeps the air awake")
    func deflagrationSetUp() throws {
        var scenario = Scenario(
            name: "Room", domainSize: SIMD3(2, 2, 2), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(1, 1, 1)))
        var configuration = SolverConfiguration()
        configuration.afterburning = true
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.25, configuration: configuration)
        #expect(solver.deflagrationStage == nil)
        #expect(solver.speciesHoldDetonationProducts)
        scenario.deflagration = Deflagration(
            region: Box(min: .zero, max: SIMD3(2, 2, 1)), ignition: SIMD3(1, 1, 0.5))
        try solver.load(scenario)
        #expect(solver.hasFlame)
        #expect(!solver.configuration.afterburning)
        // The default flame's sub-grid turbulence comes from the air's mixing, by the σ-model.
        #expect(solver.configuration.mixing?.model == .sigma)
        #expect(!solver.speciesHoldDetonationProducts)
        // Half the room is filled, at the air's density; no charge is fired.
        let state = try #require(solver.deflagrationState())
        #expect(abs(state.initialUnburnt - 2 * 2 * 1 * 1.225) < 1e-3)
        #expect(solver.totals().energy < 1.01 * Double(101_325 / 0.4 * 8))
    }

    @Test("A vent panel holds until the overpressure beside it reaches its release pressure")
    func ventPanelReleases() throws {
        // A charge in a closed room, its east wall a panel that releases at 20 kPa.
        var scenario = Scenario(
            name: "Room", domainSize: SIMD3(4, 2, 2), boxes: [],
            charge: Charge(mass: 0.02, position: SIMD3(1, 1, 1)))
        scenario.reflectiveFaces = BoundaryFaces.all.subtracting(.xMax)
        scenario.ventPanels = [
            VentPanel(box: Box(min: SIMD3(2, 0, 0), max: SIMD3(2.2, 2, 2)), releasePressure: 20_000)
        ]
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.1)
        #expect(solver.isSolid(20, 10, 10))
        #expect(solver.isSolid(21, 10, 10))
        #expect(!solver.isSolid(22, 10, 10))
        let before = try #require(solver.deflagrationState())
        #expect(before.panelOpenTimes == [nil])
        solver.advance(until: 0.01)
        let after = try #require(solver.deflagrationState())
        let opened = try #require(after.panelOpenTimes.first ?? nil)
        // The shock reaches the panel about 1 m / 400 m/s after the charge fires.
        #expect(opened > 0.001 && opened < 0.004, "opened at \(opened) s")
        #expect(!solver.isSolid(20, 10, 10))
        #expect(!solver.isSolid(21, 10, 10))
        // The blast has gone through the opening; a panel too strong to release holds it back.
        #expect(solver.peakOverpressure(30, 10, 10) > 10_000)
        scenario.ventPanels![0].releasePressure = 1e7
        try solver.load(scenario)
        solver.advance(until: 0.01)
        #expect(solver.deflagrationState()?.panelOpenTimes == [nil])
        #expect(solver.isSolid(20, 10, 10))
        #expect(solver.peakOverpressure(30, 10, 10) == 0)
    }

    @Test("A vent panel holds beside a deformable structure until it releases, and then stays open")
    func ventPanelBesideStructure() throws {
        // As above, with a concrete block in the room's far corner: its remasking starts from the
        // rigid mask, which the panel, placed after the structure, must be in too.
        var scenario = Scenario(
            name: "Room", domainSize: SIMD3(4, 2, 2), boxes: [],
            charge: Charge(mass: 0.02, position: SIMD3(1, 1, 1)),
            structure: StructureModel(
                solids: [Box(min: SIMD3(3.2, 0.2, 0), max: SIMD3(3.6, 0.6, 0.4))], elementSize: 0.1,
                fixedBase: true))
        scenario.reflectiveFaces = BoundaryFaces.all.subtracting(.xMax)
        scenario.ventPanels = [
            VentPanel(box: Box(min: SIMD3(2, 0, 0), max: SIMD3(2.2, 2, 2)), releasePressure: 20_000)
        ]
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.1)
        solver.advance(until: 0.0008)
        #expect(solver.deflagrationState()?.panelOpenTimes == [nil])
        #expect(solver.isSolid(20, 10, 10))
        #expect(solver.isSolid(21, 10, 10))
        solver.advance(until: 0.01)
        let opened = try #require(solver.deflagrationState()?.panelOpenTimes.first ?? nil)
        #expect(opened > 0.001 && opened < 0.004, "opened at \(opened) s")
        solver.advance(until: 0.02)
        #expect(!solver.isSolid(20, 10, 10))
        #expect(!solver.isSolid(21, 10, 10))
        #expect(solver.peakOverpressure(30, 10, 10) > 10_000)
    }

    @Test("A cloud lit in a small room opens its vent panel, which then holds the pressure down")
    func ventedRoom() throws {
        var study = VentedRoomStudy()
        study.room = SIMD3(2, 2, 2)
        study.ventArea = 1
        study.wallThickness = 0.25
        study.cellSize = 0.25
        study.releasePressure = 1000
        study.maximumTime = 1.5
        let result = try study.run(device: device)
        let opened = try #require(result.ventOpened)
        // When it opened, the back wall's pressure had about reached the release pressure.
        let index = try #require(result.times.firstIndex { $0 >= opened })
        #expect(result.overpressures[index] > 700, "\(result.overpressures[index]) Pa at \(opened) s")
        // Above the release pressure, far below a closed room's 8 bar.
        #expect(result.rawPeak > 1000 && result.reducedPressure < 50_000, "\(result.reducedPressure) Pa")
        #expect(result.burntFraction > 0.9)
    }
}
