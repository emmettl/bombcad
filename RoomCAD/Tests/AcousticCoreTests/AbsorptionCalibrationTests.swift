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
            receivers: [RoomPoint(name: "R", position: [6.5, 2.2, 1.2])], airAbsorption: false, duration: 1.5,
            maximumReflectionOrder: 30, diffuseRays: 20_000)
        // As given it decays in about 1.5 s, against Eyring's 0.9 s.
        let target: [Double?] = [nil, nil, 1.2, 1.2, 1.2, 1.2, nil, nil]
        let (fitted, steps) = try AbsorptionCalibration.fit(settings, to: target, tolerance: 0.03)
        let first = try #require(steps.first)
        let last = try #require(steps.last)
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
}
