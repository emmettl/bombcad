import Foundation
import Testing
import simd

@testable import AcousticCore

@Suite("Microphones")
struct MicrophoneTests {
    let size: SIMD3<Double> = [6, 5, 3]
    let source = RoomPoint(name: "S", position: [1.5, 2.5, 1.5])

    @Test("First-order patterns have their textbook gains and diffuse-field energies")
    func patterns() {
        let cardioid = Microphone(pattern: .cardioid)  // aimed along +x
        #expect(abs(cardioid.gain(from: [1, 0, 0]) - 1) < 1e-12)
        #expect(abs(cardioid.gain(from: [0, 1, 0]) - 0.5) < 1e-12)
        #expect(abs(cardioid.gain(from: [-1, 0, 0])) < 1e-12)
        let eight = Microphone(pattern: .figureOfEight, azimuth: 90)
        #expect(abs(eight.gain(from: [0, 1, 0]) - 1) < 1e-12)
        #expect(abs(eight.gain(from: [0, -1, 0]) + 1) < 1e-12)  // inverted rear lobe
        #expect(abs(eight.gain(from: [1, 0, 0])) < 1e-12)
        let up = Microphone(pattern: .cardioid, azimuth: 0, elevation: 90)
        #expect(abs(up.gain(from: [0, 0, 1]) - 1) < 1e-12)
        #expect(abs(Microphone.Pattern.cardioid.diffuseEnergy - 1.0 / 3) < 1e-12)
        #expect(abs(Microphone.Pattern.figureOfEight.diffuseEnergy - 1.0 / 3) < 1e-12)
        #expect(Microphone.Pattern.omni.diffuseEnergy == 1)
    }

    private func direct(_ microphone: Microphone?) throws -> Double {
        let settings = RoomResponseSettings(
            room: ShoeboxRoom(size: size, material: .anechoic), source: source,
            receivers: [RoomPoint(name: "R", position: [4.5, 2.5, 1.5], microphone: microphone)],
            airAbsorption: false,
            duration: 0.05, lowFrequencyCutoff: 0)
        return try RoomResponseGenerator.generate(settings, cancellation: CancellationFlag()).response
            .channels[0]
            .reduce(0) { $0 + Double($1) * Double($1) }
    }

    @Test("A cardioid facing the source hears it as an omni does; facing away, not at all")
    func directSound() throws {
        let omni = try direct(nil)
        // The source is along -x from the receiver.
        #expect(abs(try direct(Microphone(pattern: .cardioid, azimuth: 180)) / omni - 1) < 1e-9)
        #expect(try direct(Microphone(pattern: .cardioid, azimuth: 0)) / omni < 1e-12)
        #expect(abs(try direct(Microphone(pattern: .cardioid, azimuth: 90)) / omni - 0.25) < 1e-9)
        #expect(try direct(.omni) == omni)
    }

    @Test("In a diffuse field a microphone picks up its pattern's share of the energy")
    func diffuseField() {
        let room = ShoeboxRoom(size: size, material: .uniform(0, scattering: 1, name: "Rigid"))
        let tracer = DiffuseRayTracer(
            room: room, source: source.position, atmosphere: .standard, airAbsorption: false,
            rayCount: 20_000, seed: 5)
        let position: SIMD3<Double> = [4.2, 1.8, 1.3]
        let patterns: [Microphone.Pattern] = [.omni, .cardioid, .hypercardioid, .figureOfEight]
        let energy = tracer.trace(
            receivers: patterns.map { (position, Microphone(pattern: $0, azimuth: 30, elevation: 20)) },
            duration: 0.5)
        let late = energy.map { $0[4][200..<500].reduce(0, +) }
        for (index, pattern) in patterns.enumerated() {
            #expect(abs(late[index] / late[0] / pattern.diffuseEnergy - 1) < 0.05, "\(pattern)")
        }
    }

    @Test("Stereo pairs sit around the pair's centre, face the source and put left on the left")
    func pairs() throws {
        let settings = RoomResponseSettings(
            room: ShoeboxRoom(size: size, material: .rigid), source: source,
            receivers: [
                RoomPoint(name: "L", position: [4.5, 2.0, 1.2]),
                RoomPoint(name: "R", position: [4.5, 3.0, 1.2]),
            ])
        let ortf = StereoPair.ortf.arranged(in: settings)
        let left = ortf.receivers[0]
        let right = ortf.receivers[1]
        #expect(abs(simd_distance(left.position, right.position) - 0.17) < 1e-9)
        #expect(simd_distance((left.position + right.position) / 2, [4.5, 2.5, 1.2]) < 1e-9)
        // Facing the source along -x, left is towards -y.
        #expect(left.position.y < right.position.y)
        #expect(
            abs((left.microphone?.azimuth ?? 0) - 235) < 1e-9
                || abs((left.microphone?.azimuth ?? 0) + 125) < 1e-9)
        #expect(abs(abs((left.microphone?.azimuth ?? 0) - (right.microphone?.azimuth ?? 0)) - 110) < 1e-9)
        #expect(left.microphone?.pattern == .cardioid)
        let xy = StereoPair.xy.arranged(in: settings)
        #expect(xy.receivers[0].position == xy.receivers[1].position)
        try StereoPair.blumlein.arranged(in: settings).validate()
        #expect(StereoPair.blumlein.arranged(in: settings).receivers[0].microphone?.pattern == .figureOfEight)
    }

    @Test("Receivers saved before microphones existed decode as omni")
    func compatibility() throws {
        let json = #"{"id":"6B1C1C6A-3D2B-4E0E-9B7E-2D1A8C1A7F10","name":"Old","position":[1,2,3]}"#
        let point = try JSONDecoder().decode(RoomPoint.self, from: Data(json.utf8))
        #expect(point.microphone == nil)
    }
}
