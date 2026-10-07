import Foundation
import Testing
import simd

@testable import AcousticCore

@Suite("Wave solver")
struct WaveSolverTests {
    private func energy(_ x: some Collection<Float>) -> Double {
        x.reduce(0) { $0 + Double($1) * Double($1) }
    }

    @Test("Wall impedance reproduces the published random-incidence absorption")
    func impedance() {
        for alpha in stride(from: 0.02, through: 0.9, by: 0.04) {
            let xi = WaveSolver.impedance(forStatisticalAbsorption: alpha)
            #expect(abs(WaveSolver.statisticalAbsorption(xi) - alpha) < 1e-9)
        }
        let most = WaveSolver.statisticalAbsorption(WaveSolver.mostAbsorbingImpedance)
        #expect(abs(most - 0.951) < 0.001)
        #expect(
            abs(WaveSolver.impedance(forStatisticalAbsorption: 1) - WaveSolver.mostAbsorbingImpedance) < 1e-3)
    }

    /// A large, absorbent room, so the direct sound arrives well before any reflection.
    private func freeField(_ microphone: Microphone?, wave: Bool) throws -> [Float] {
        let settings = RoomResponseSettings(
            room: ShoeboxRoom(size: [16, 16, 16], material: .anechoic),
            source: RoomPoint(name: "S", position: [8, 8, 8]),
            receivers: [RoomPoint(name: "R", position: [11, 8, 8], microphone: microphone)],
            airAbsorption: false,
            duration: 0.06, maximumReflectionOrder: 0, lowFrequencyModel: wave, crossoverFrequency: 50)
        let channel = try RoomResponseGenerator.generate(settings, cancellation: CancellationFlag()).response
            .channels[0]
        // Below the crossover, where the wave solver applies.
        return RealFFT.zeroPhaseFilter(channel, sampleRate: 48_000) {
            1 - OctaveBands.rise($0, crossover: 50)
        }
    }

    @Test("In free field the wave solver matches the geometrical direct sound in level and time")
    func calibration() throws {
        let wave = try freeField(nil, wave: true)
        let geometrical = try freeField(nil, wave: false)
        // Before the first reflection, 29 ms after the direct sound.
        let window = 0..<Int(0.03 * 48_000)
        #expect(abs(10 * log10(energy(wave[window]) / energy(geometrical[window]))) < 0.25)
        let difference = window.map { wave[$0] - geometrical[$0] }
        #expect(energy(difference) < 0.01 * energy(geometrical[window]))
    }

    @Test("Directional microphones take their pattern from the simulated particle velocity")
    func directional() throws {
        // A room large enough that the direct pulse is over before the first reflection, with the receiver
        // far enough away (kr above 5 over the pulse's band) that the near field adds under 1%.
        let solver = WaveSolver(
            room: ShoeboxRoom(size: [6, 6, 6], material: .anechoic), sampleRate: 48_000, topFrequency: 300,
            atmosphere: .standard)
        let position: SIMD3<Double> = [4.5, 3, 3]
        // The source is along -x from the receiver.
        let microphones: [Microphone] = [
            .omni, Microphone(pattern: .cardioid, azimuth: 180), Microphone(pattern: .cardioid, azimuth: 0),
            Microphone(pattern: .figureOfEight, azimuth: 90),
        ]
        let steps = Int(0.016 / solver.timeStep)
        let result = solver.simulate(
            source: [3, 3, 3], receivers: microphones.map { (position, $0) }, steps: steps, stop: { false })
        let signals = try #require(result)
        let energies = signals.map { $0.reduce(0) { $0 + $1 * $1 } }
        #expect(abs(energies[1] / energies[0] - 1) < 0.1)  // facing the source
        #expect(energies[2] / energies[0] < 0.03)  // facing away
        #expect(energies[3] / energies[0] < 0.03)  // side-on figure of eight
    }

    @Test("A rigid room rings at its analytical mode frequencies to within 0.5%")
    func modes() throws {
        let size: SIMD3<Double> = [3, 2.5, 2]
        let solver = WaveSolver(
            room: ShoeboxRoom(size: size, material: .rigid), sampleRate: 48_000, topFrequency: 200,
            atmosphere: .standard)
        let steps = 16_384
        let result = solver.simulate(
            source: [0.3, 0.25, 0.2], receivers: [([2.8, 2.3, 1.85], .omni)], steps: steps, stop: { false })
        let signal = try #require(result)[0]
        let spectrum = RealFFT(length: steps).forward(signal)
        let magnitude = (0..<(steps / 2)).map { hypot(spectrum.real[$0], spectrum.imag[$0]) }
        let binWidth = 1 / (Double(steps) * solver.timeStep)
        let c = Atmosphere.standard.soundSpeed
        let expected = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (1, 0, 1)].map { l, m, n in
            c / 2
                * (pow(Double(l) / size.x, 2) + pow(Double(m) / size.y, 2) + pow(Double(n) / size.z, 2))
                .squareRoot()
        }
        for frequency in expected {
            let centre = Int(frequency / binWidth)
            let peak = try #require(((centre - 6)...(centre + 6)).max { magnitude[$0] < magnitude[$1] })
            let (a, b, c) = (log(magnitude[peak - 1]), log(magnitude[peak]), log(magnitude[peak + 1]))
            let measured = (Double(peak) + 0.5 * (a - c) / (a - 2 * b + c)) * binWidth
            #expect(abs(measured / frequency - 1) < 0.005, "\(frequency) Hz measured as \(measured) Hz")
        }
    }

    @Test("An axial mode between absorbing walls decays at the rate their reflection coefficient gives")
    func axialDecay() throws {
        var room = ShoeboxRoom(size: [4, 3, 2.5], material: .rigid)
        room.west = .uniform(0.3, name: "Absorber")
        room.east = .uniform(0.3, name: "Absorber")
        let solver = WaveSolver(room: room, sampleRate: 48_000, topFrequency: 120, atmosphere: .standard)
        // On the y and z centre lines, where modes odd in y or z are silent.
        let result = solver.simulate(
            source: [0.2, 1.5, 1.25], receivers: [([3.8, 1.5, 1.25], .omni)], steps: 16_384, stop: { false })
        let signal = try #require(result)[0]
        let c = Atmosphere.standard.soundSpeed
        let mode = c / 8
        let rate = 1 / solver.timeStep
        let band = RealFFT.zeroPhaseFilter(signal.map { Float($0) }, sampleRate: rate) {
            exp(-pow(($0 - mode) / 5, 2))
        }
        let window = Int(rate / mode)
        var points: [(Double, Double)] = []
        var start = Int(0.05 * rate)
        while start + window < Int(0.35 * rate) {
            points.append((Double(start) / rate, 10 * log10(energy(band[start..<(start + window)]))))
            start += window
        }
        let n = Double(points.count)
        let sx = points.reduce(0) { $0 + $1.0 }
        let sy = points.reduce(0) { $0 + $1.1 }
        let slope =
            (n * points.reduce(0) { $0 + $1.0 * $1.1 } - sx * sy)
            / (n * points.reduce(0) { $0 + $1.0 * $1.0 } - sx * sx)
        // Normal incidence: the reflection coefficient of the solver's impedance, twice per round trip.
        let xi = solver.impedance(.west)
        let reflection = (xi - 1) / (xi + 1)
        let expected = -20 * log10(reflection * reflection) / (2 * 4 / c)
        #expect(abs(-slope / expected - 1) < 0.1, "\(-slope) dB/s against \(expected) dB/s")
    }

    @Test("Rooms too large for the budget skip the wave solver and say why; settings default to off")
    func planning() throws {
        let church = RoomResponseSettings(
            room: ShoeboxRoom(size: [36, 14, 16], material: .uniform(0.05, name: "Stone")),
            source: RoomPoint(name: "S", position: [4, 7, 2]),
            receivers: [RoomPoint(name: "R", position: [18, 7, 1.2])],
            duration: 8, lowFrequencyModel: true)
        #expect(WavePlan(settings: church, schroeder: 59, fftLength: 1 << 19) == nil)
        let small = RoomResponseSettings(
            room: ShoeboxRoom(size: [5, 4, 3], material: .uniform(0.2, name: "Plaster")),
            source: RoomPoint(name: "S", position: [1, 1, 1]),
            receivers: [RoomPoint(name: "R", position: [3, 2, 1.2])],
            duration: 1, lowFrequencyModel: true)
        let plan = try #require(WavePlan(settings: small, schroeder: 200, fftLength: 1 << 16))
        #expect(plan.crossover == 250)
        #expect(plan.solver.cost(duration: Double(1 << 16) / 48_000) <= WavePlan.budget)
        #expect(
            !RoomResponseSettings(room: small.room, source: small.source, receivers: small.receivers)
                .lowFrequencyModel)
        var bad = small
        bad.crossoverFrequency = 1_000
        #expect(throws: AcousticError.self) { try bad.validate() }
    }
}

@Suite("Wave solver metadata")
struct WaveMetadataTests {
    @Test("A response with the wave solver says so and no longer calls its low end approximate")
    func describes() throws {
        let settings = RoomResponseSettings(
            room: ShoeboxRoom(size: [3, 2.5, 2.2], material: .uniform(0.2, name: "Plaster")),
            source: RoomPoint(name: "S", position: [0.8, 0.9, 1.1]),
            receivers: [RoomPoint(name: "R", position: [2.2, 1.6, 1.2])],
            duration: 0.2, maximumReflectionOrder: 20, lowFrequencyModel: true, crossoverFrequency: 100)
        let result = try RoomResponseGenerator.generate(settings, cancellation: CancellationFlag())
        #expect(result.diagnostics.waveCrossover == 100)
        #expect(result.response.metadata.approximateBelowHz == nil)
        #expect(result.response.metadata.model.hasPrefix("Finite-difference wave solver below 100 Hz"))
    }
}
