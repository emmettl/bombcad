import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// A premixed gas cloud burning behind a flame front, and vent panels.
@Suite("Deflagration")
struct DeflagrationTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    @Test(
        "The heat released takes a closed volume of stoichiometric mixture to its AICC pressure",
        arguments: [FlammableGas.methane, .propane], [AirModel.idealGas, .thermallyPerfect])
    func heatReachesAICC(gas: FlammableGas, air: AirModel) {
        let atmosphere = Atmosphere()
        let cloud = Deflagration(gas: gas, region: Box(min: .zero, max: .one), ignition: .zero)
        let pressure = cloud.modelAICCPressure(atmosphere: atmosphere, airModel: air, gamma: 1.4)
        let expected = Float(gas.stoichiometricAICCRatio) * atmosphere.pressure
        #expect(abs(pressure / expected - 1) < 0.005, "\(pressure) Pa")
        // Less of the heat of combustion is needed than all of it, and less again for an ideal gas.
        let share = Deflagration.heatShare(gas: gas, atmosphere: atmosphere, airModel: air, gamma: 1.4)
        #expect(share > 0.5 && share < 1, "\(share)")
    }

    @Test("Burning velocities follow Gülder's fit and vanish outside the flammable range")
    func burningVelocities() {
        let methane = FlammableGas.methane
        #expect(abs(methane.stoichiometricFraction - 0.095) < 0.001)
        #expect(abs(methane.laminarBurningVelocity(fraction: 0.095) - 0.41) < 0.01)
        #expect(methane.laminarBurningVelocity(fraction: 0.045) == 0)
        #expect(methane.laminarBurningVelocity(fraction: 0.16) == 0)
        #expect(abs(FlammableGas.propane.laminarBurningVelocity(fraction: 0.0403) - 0.43) < 0.01)
        let ideal = Deflagration(gas: .methane, region: Box(min: .zero, max: .one), ignition: .zero)
            .modelExpansionRatio(atmosphere: Atmosphere(), airModel: .idealGas, gamma: 1.4)
        // An ideal gas with gamma 1.4: 1 + (8.9 - 1) / 1.4.
        #expect(abs(ideal - 6.64) < 0.05, "\(ideal)")
    }

    @Test("The thin-flame model's steepest rise is the deflagration index's formula")
    func thinFlameIndex() {
        let r = 0.5
        let history = DeflagrationReference.closedSphere(
            radius: r, initialPressure: 1e5, maximumPressure: 8e5, gamma: 1.4, burningVelocity: 0.4)
        let index = DeflagrationReference.deflagrationIndex(
            initialPressure: 1e5, maximumPressure: 8e5, gamma: 1.4, burningVelocity: 0.4)
        let volume = 4 / 3 * Double.pi * r * r * r
        #expect(abs(history.peakRate * cbrt(volume) / index - 1) < 0.01)
        #expect(abs(history.pressures.last! - 8e5) < 1)
    }

    @Test("The vent correlations agree with hand working for FM Global's chamber")
    func ventCorrelations() {
        // Bauwens et al.'s test 1: 63.7 m³, a 5.4 m² open vent, methane.
        let c = VentCorrelations(
            volume: 4.6 * 4.6 * 3, surfaceArea: 2 * (4.6 * 4.6 + 2 * 4.6 * 3), ventArea: 5.4,
            releasePressure: 0,
            gas: .methane)
        // NFPA 68 (2002): (0.037 x 97.52 / 5.4)^2 bar.
        #expect(abs(c.nfpa68 / 1e5 - 0.4465) < 0.001)
        // Bartknecht with K_G 55: 5.4 = (0.1265 log 55 - 0.0567) P^-0.5817 V^(2/3).
        #expect(abs((c.bartknecht ?? 0) / 1e5 - 0.285) < 0.002)
        // Molkov: Br 44.0, chi/mu 10.6, Br_t 2.0, so pi_red 0.18.
        #expect(abs(c.molkov / 1e5 - 0.185) < 0.005, "\(c.molkov)")
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
        arguments: [FlameAcceleration.laminar, FlameAcceleration()])
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
        // A flame in a narrow tube is one-dimensional, where the σ-model sees no turbulence.
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

    @Test("Saves with a deflagration and vent panels round-trip, and older saves still open")
    func coding() throws {
        var scenario = Scenario(
            name: "Room", domainSize: SIMD3(4, 4, 3), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(2, 2, 1)))
        let plain = try JSONEncoder().encode(scenario)
        #expect(!String(decoding: plain, as: UTF8.self).contains("deflagration"))
        #expect(try JSONDecoder().decode(Scenario.self, from: plain).deflagration == nil)
        scenario.deflagration = Deflagration(
            gas: .propane, concentration: 0.05, region: Box(min: .zero, max: SIMD3(4, 4, 1)),
            ignition: SIMD3(2, 2, 0.5),
            acceleration: FlameAcceleration(
                factor: 2, wrinklingRadius: 1, turbulence: FlameTurbulence(scale: 1)))
        scenario.ventPanels = [
            VentPanel(box: Box(min: SIMD3(3.9, 1, 1), max: SIMD3(4, 2, 2)), releasePressure: 5000)
        ]
        let decoded = try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(scenario))
        #expect(decoded.deflagration == scenario.deflagration)
        #expect(decoded.ventPanels == scenario.ventPanels)
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
