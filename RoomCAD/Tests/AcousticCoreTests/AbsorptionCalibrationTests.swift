import Foundation
import Testing

@testable import AcousticCore

@Suite("Absorption calibration")
struct AbsorptionCalibrationTests {
    @Test("Scaling absorption reaches a target reverberation time that Eyring's formula misses")
    func reachesTarget() throws {
        // Absorption concentrated on the floor, as an audience's is, with little scattering: the room
        // decays more slowly than Eyring's formula says.
        var room = ShoeboxRoom(size: [9, 6, 4], material: .uniform(0.05, scattering: 0.1, name: "Plaster"))
        room.floor = .uniform(0.5, scattering: 0.3, name: "Audience")
        let settings = RoomResponseSettings(
            room: room, source: RoomPoint(name: "S", position: [2, 3, 1.5]),
            receivers: [RoomPoint(name: "R", position: [6.5, 2.2, 1.2])], airAbsorption: false, duration: 1.2,
            maximumReflectionOrder: 12, diffuseRays: 10_000)
        // As given it decays in about 1.5 s, against Eyring's 0.9 s.
        let target: [Double?] = [nil, nil, 1.2, 1.2, 1.2, 1.2, nil, nil]
        let (fitted, steps, best) = try AbsorptionCalibration.fit(settings, to: target, tolerance: 0.03)
        let first = try #require(steps.first)
        let last = best
        // The room as given decays well away from the target, and the fit brings it within 3%.
        #expect(abs(try #require(first.reverberationTime[4]) / 1.2 - 1) > 0.1)
        for band in 2...5 {
            let time = try #require(last.reverberationTime[band])
            #expect(abs(time / 1.2 - 1) <= 0.03, "band \(band): \(time) s after \(steps.count) steps")
        }
        #expect(steps.count <= 6)
        // Proportions are kept: the floor and the walls scale by the same factor; bands without a
        // target keep their absorption.
        #expect(abs(fitted.floor.absorption[4] / fitted.west.absorption[4] - 10) < 1e-9)
        #expect(fitted.floor.absorption[0] == 0.5 && fitted.floor.absorption[7] == 0.5)
        // Eyring's formula, given the fitted absorption, says the room decays faster than it does.
        let eyring = try #require(
            fitted.eyringReverberationTime(atmosphere: .standard, airAbsorption: false)[4])
        #expect(eyring < 1.2 * 0.97)
    }

    @Test("Each band keeps its best step, even where its time answers the absorption erratically")
    func bestStepPerBand() throws {
        let room = ShoeboxRoom(size: [8, 6, 4], material: .uniform(0.2, name: "Plaster"))
        let settings = RoomResponseSettings(
            room: room, source: RoomPoint(name: "S", position: [2, 3, 1.5]),
            receivers: [RoomPoint(name: "R", position: [6, 2.5, 1.2])], airAbsorption: false, duration: 2)
        // Octave-band noise, filtered once, to shape into decays.
        var random = SplitMix(seed: 5)
        let noise = (0..<96_000).map { _ in Float(random.nextUnit() * 2 - 1) }
        let bands = (0..<OctaveBands.count).map {
            DecayAnalysis.octaveBand(noise, sampleRate: 48_000, band: $0)
        }
        // A stand-in for the model: from 500 Hz up the time falls with absorption as Sabine says; at
        // 63 Hz it jumps about, as a band held by the wave solver can. Neighbouring bands leak into each
        // other through the filters, so the bands with targets share one.
        var calls = 0
        func time(band: Int, factor: Double) -> Double {
            band == 0 ? [1.6, 0.9, 1.7, 1.25, 2.0, 1.4][min(calls - 1, 5)] : band >= 3 ? 1.5 / factor : 1.5
        }
        let (_, steps, best) = try AbsorptionCalibration.fit(
            settings, to: [1.2, nil, nil, 1, 1, 1, 1, 1], tolerance: 0.01
        ) { trial in
            calls += 1
            let factors = trial.room.west.absorption.map { $0 / 0.2 }
            var channel = [Float](repeating: 0, count: noise.count)
            for band in 0..<OctaveBands.count {
                let t = time(band: band, factor: factors[band])
                for i in channel.indices {
                    channel[i] += bands[band][i] * Float(exp(-3 * log(10) * Double(i) / 48_000 / t))
                }
            }
            return [channel]
        }
        // 2 kHz converges; 63 Hz keeps whichever step came closest to 1.2 s, not its last.
        #expect(abs(try #require(best.reverberationTime[5]) - 1) < 0.03)
        let errors = steps.compactMap { $0.reverberationTime[0].map { abs($0 / 1.2 - 1) } }
        let chosen = abs(try #require(best.reverberationTime[0]) / 1.2 - 1)
        #expect(chosen <= errors.min()! + 1e-12)
        #expect(best.factors[1] == 1 && best.factors[2] == 1)
    }
}
