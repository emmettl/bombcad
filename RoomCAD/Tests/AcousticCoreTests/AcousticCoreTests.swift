import Foundation
import ImpulseResponseKit
import Testing
import simd

@testable import AcousticCore

@Suite("Room acoustics")
struct AcousticCoreTests {
    let size: SIMD3<Double> = [8, 6, 3]
    let source = RoomPoint(name: "Source", position: [2.1, 2.7, 1.4])
    let receiver = RoomPoint(name: "Receiver", position: [5.6, 3.4, 1.2])

    private func energy(_ samples: some Collection<Float>) -> Double {
        samples.reduce(0) { $0 + Double($1) * Double($1) }
    }

    private func peakIndex(_ samples: [Float]) -> Int {
        samples.indices.max { abs(samples[$0]) < abs(samples[$1]) }!
    }

    @Test("Band weights are a partition of unity at every frequency")
    func partitionOfUnity() {
        for f in stride(from: 0.0, through: 24_000, by: 7.3) {
            let weights = (0..<OctaveBands.count).map { OctaveBands.weight(band: $0, frequency: f) }
            #expect(weights.allSatisfy { $0 >= 0 && $0 <= 1 })
            #expect(abs(weights.reduce(0, +) - 1) < 1e-12)
        }
        #expect(OctaveBands.weight(band: 4, frequency: 1000) == 1)
    }

    @Test("Sound speed and ISO 9613-1 air absorption are plausible at 20 °C and 50% humidity")
    func atmosphere() {
        let air = Atmosphere.standard
        #expect(abs(air.soundSpeed - 343.2) < 0.1)
        let perKilometre = OctaveBands.centres.map { air.absorptionDecibelsPerMetre(frequency: $0) * 1000 }
        #expect(zip(perKilometre, perKilometre.dropFirst()).allSatisfy { $0 < $1 })
        #expect((3...7).contains(perKilometre[4]))  // 1 kHz: a few dB per km
        #expect((50...150).contains(perKilometre[7]))  // 8 kHz: around 100 dB per km
    }

    @Test("First-order images lie at the mirror positions with one reflection each")
    func firstOrderImages() {
        let room = ShoeboxRoom(size: size, material: .rigid)
        let model = ImageSourceModel(
            room: room, source: source.position, atmosphere: .standard, airAbsorption: false)
        var delays: [Double] = []
        let summary = model.forEachArrival(at: receiver.position, duration: 1, maximumOrder: 1) {
            delay, order, _ in
            if order == 1 { delays.append(delay) }
        }
        let s = source.position
        let mirrors: [SIMD3<Double>] = [
            [-s.x, s.y, s.z], [2 * size.x - s.x, s.y, s.z], [s.x, -s.y, s.z], [s.x, 2 * size.y - s.y, s.z],
            [s.x, s.y, -s.z], [s.x, s.y, 2 * size.z - s.z],
        ]
        let expected = mirrors.map { simd_distance($0, receiver.position) / Atmosphere.standard.soundSpeed }
        #expect(delays.count == 6)
        #expect(zip(delays.sorted(), expected.sorted()).allSatisfy { abs($0 - $1) < 1e-12 })
        #expect(summary.arrivals == 7)
        #expect(summary.orderLimitedAfter != nil)
    }

    @Test("Pruning by order finds exactly the arrivals and the earliest omission that brute force does")
    func pruning() {
        var room = ShoeboxRoom(size: [3.1, 2.3, 2.7], material: .uniform(0.2, name: "Test"))
        room.floor = .uniform(0.5, scattering: 0.3, name: "Floor")
        let model = ImageSourceModel(
            room: room, source: [0.7, 1.9, 1.1], atmosphere: .standard, airAbsorption: true)
        let listener: SIMD3<Double> = [2.6, 0.4, 2.2]
        for (duration, order) in [(0.08, 4), (0.12, 9), (0.05, 40)] {
            var found: [Double] = []
            let summary = model.forEachArrival(at: listener, duration: duration, maximumOrder: order) {
                delay, _, _ in found.append(delay)
            }
            // Every image within reach, with no pruning.
            let c = Atmosphere.standard.soundSpeed
            let reach = duration * c
            let axes = [
                model.axisImages(
                    length: room.size.x, source: 0.7, receiver: listener.x, reach: reach,
                    low: room.west.reflection,
                    high: room.east.reflection),
                model.axisImages(
                    length: room.size.y, source: 1.9, receiver: listener.y, reach: reach,
                    low: room.south.reflection,
                    high: room.north.reflection),
                model.axisImages(
                    length: room.size.z, source: 1.1, receiver: listener.z, reach: reach,
                    low: room.floor.reflection,
                    high: room.ceiling.reflection),
            ]
            var expected: [Double] = []
            var omitted = Double.infinity
            for x in axes[0] {
                for y in axes[1] {
                    for z in axes[2] {
                        let r = (x.offset * x.offset + y.offset * y.offset + z.offset * z.offset).squareRoot()
                        guard r <= reach else { continue }
                        if x.order + y.order + z.order > order {
                            omitted = min(omitted, r)
                        } else {
                            expected.append(r / c)
                        }
                    }
                }
            }
            #expect(found.sorted() == expected.sorted(), "duration \(duration), order \(order)")
            #expect(summary.orderLimitedAfter == (omitted.isFinite ? omitted / c : nil))
        }
    }

    @Test("Reflection gains multiply the coefficients of the surfaces met")
    func reflectionGains() {
        var room = ShoeboxRoom(size: size, material: .anechoic)
        room.floor = .uniform(0.36, name: "Floor")  // reflection 0.8
        room.ceiling = .uniform(0.75, name: "Ceiling")  // reflection 0.5
        let model = ImageSourceModel(
            room: room, source: source.position, atmosphere: .standard, airAbsorption: false)
        var found: [(Double, Double)] = []
        model.forEachArrival(at: receiver.position, duration: 1, maximumOrder: 2, includeDirect: false) {
            delay, order, gains in
            if order == 2 { found.append((delay * Atmosphere.standard.soundSpeed, gains[0])) }
        }
        // Floor then ceiling, and ceiling then floor: product 0.4 over distance.
        #expect(found.count == 2)
        #expect(found.allSatisfy { abs($0.1 * $0.0 - 0.4) < 1e-12 })
    }

    @Test("Rendered peaks fall within one sample of the analytical direct and first-reflection delays")
    func arrivalTiming() throws {
        for surface in [nil] + Surface.allCases.map(Optional.some) {
            var room = ShoeboxRoom(size: size, material: .anechoic)
            if let surface { room[surface] = .rigid }
            let settings = RoomResponseSettings(
                room: room, source: source, receivers: [receiver], airAbsorption: false, duration: 0.1,
                maximumReflectionOrder: surface == nil ? 0 : 1,
                content: surface == nil ? .complete : .reflectionsOnly, lowFrequencyCutoff: 0)
            let model = ImageSourceModel(
                room: room, source: source.position, atmosphere: .standard, airAbsorption: false)
            var expected: [Double] = []
            model.forEachArrival(
                at: receiver.position, duration: 0.1, maximumOrder: settings.maximumReflectionOrder,
                includeDirect: surface == nil
            ) { delay, _, _ in expected.append(delay * 48_000) }
            #expect(expected.count == 1)
            let samples = try RoomResponseGenerator.generate(settings).response.channels[0]
            #expect(abs(Double(peakIndex(samples)) - expected[0]) <= 0.5)
        }
    }

    @Test("An anechoic room gives inverse-square energy and no spurious tail")
    func anechoic() throws {
        let distances = [0.5, 1.0, 2.0, 4.0]
        let sourcePoint = RoomPoint(name: "S", position: [1, 3, 1.5])
        let receivers = distances.map { RoomPoint(name: "\($0)", position: [1 + $0, 3, 1.5]) }
        let result = try RoomResponseGenerator.generate(
            RoomResponseSettings(
                room: ShoeboxRoom(size: size, material: .anechoic), source: sourcePoint, receivers: receivers,
                airAbsorption: false, duration: 0.1, lowFrequencyCutoff: 0))
        #expect(result.diagnostics.arrivals == [1, 1, 1, 1])
        let energies = result.response.channels.map { energy($0) }
        for (i, r) in distances.enumerated() {
            #expect(abs(energies[i] * r * r / energies[1] - 1) < 0.01)
            let samples = result.response.channels[i]
            let arrival = Int((result.diagnostics.directDelay[i] * 48_000).rounded())
            #expect(energy(samples[(arrival + 48)...]) < 1e-6 * energies[i])
            #expect(energy(samples[..<(arrival - 48)]) < 1e-6 * energies[i])
        }
    }

    @Test("Equal band gains pass through the band filters unchanged")
    func transparentBands() {
        var flat = BandRenderer(sampleRate: 48_000, frames: 2_000)
        flat.add(delay: 0.01234, gains: Array(repeating: 0.7, count: OctaveBands.count))
        let output = flat.render()
        var single = BandRenderer(sampleRate: 48_000, frames: 48_000)
        single.add(delay: 0.5, gains: [0.7] + Array(repeating: 0, count: OctaveBands.count - 1))
        // The kernel's samples sum to about one, so the band-limited impulse keeps its area.
        #expect(abs(output.reduce(0, +) - 0.7) < 1e-3)
        let kernelOnly = output.indices.filter { abs($0 - 592) > 40 }
        #expect(kernelOnly.allSatisfy { abs(output[$0]) < 1e-9 })
        // A low band alone is spread in time but keeps the arrival's low-frequency content.
        let low = single.render()
        #expect(abs(low.reduce(0, +) - 0.7) < 1e-3)
    }

    @Test("The reflections-only response is the complete response without the direct sound")
    func reflectionsOnly() throws {
        var settings = RoomResponseSettings(
            room: ShoeboxRoom(size: size, material: .uniform(0.3, name: "Test")), source: source,
            receivers: [receiver], duration: 0.2, maximumReflectionOrder: 20)
        let complete = try RoomResponseGenerator.generate(settings).response.channels[0]
        settings.content = .reflectionsOnly
        let reflections = try RoomResponseGenerator.generate(settings).response
        // The direct sound alone, from the same points in an anechoic room. (A reflection order of 0 would
        // not do: rays carry everything above the order limit.)
        settings.content = .complete
        settings.room = ShoeboxRoom(size: size, material: .anechoic)
        let direct = try RoomResponseGenerator.generate(settings).response.channels[0]
        let difference = zip(complete, zip(reflections.channels[0], direct)).map { $0 - $1.0 - $1.1 }
        #expect(difference.allSatisfy { abs($0) < 1e-6 })
        #expect(reflections.metadata.content == .reflectionsOnly)
    }

    @Test("The order limit is reported when it removes arrivals within the duration")
    func orderLimit() throws {
        let room = ShoeboxRoom(size: size, material: .uniform(0.2, name: "Test"))
        let limited = try RoomResponseGenerator.generate(
            RoomResponseSettings(
                room: room, source: source, receivers: [receiver], duration: 0.3, maximumReflectionOrder: 3))
        let after = try #require(limited.diagnostics.orderLimitedAfter[0])
        #expect(after > limited.diagnostics.directDelay[0] && after < 0.3)
        let complete = try RoomResponseGenerator.generate(
            RoomResponseSettings(
                room: room, source: source, receivers: [receiver], duration: 0.05, maximumReflectionOrder: 100
            ))
        #expect(complete.diagnostics.orderLimitedAfter == [nil])
    }

    /// Late decay of a specular rectangular room with one reflection coefficient everywhere, from images
    /// spread uniformly in space: a path of length `r` in direction `u` meets about
    /// `r (|ux|/Lx + |uy|/Ly + |uz|/Lz)` walls, so energy at time `t` is the direction average of
    /// `beta^(2 c t n(u))`. Only the Eyring estimate uses the mean of `n(u)` in place of the average.
    private func specularDecayTime(size: SIMD3<Double>, reflection beta: Double, c: Double) -> Double {
        let points = 20_000
        let golden = Double.pi * (3 - 5.0.squareRoot())
        let rates: [Double] = (0..<points).map { i in
            let z = 1 - 2 * (Double(i) + 0.5) / Double(points)
            let radius = (1 - z * z).squareRoot()
            let u = SIMD3(radius * cos(golden * Double(i)), radius * sin(golden * Double(i)), z)
            return -2 * c * log(beta) * (abs(u.x) / size.x + abs(u.y) / size.y + abs(u.z) / size.z)
        }
        let rate = 4_000.0
        let samples = (0..<Int(rate)).map { n in
            Float(rates.reduce(0) { $0 + exp(-$1 * Double(n) / rate) }.squareRoot())
        }
        return DecayAnalysis.reverberationTime(samples, sampleRate: Int(rate))!
    }

    @Test("A uniformly absorbing room decays at the rate expected of specular reflection")
    func decayRate() throws {
        let size: SIMD3<Double> = [5, 4, 3]
        let alpha = 0.5
        let room = ShoeboxRoom(size: size, material: .uniform(alpha, name: "Test"))
        let result = try RoomResponseGenerator.generate(
            RoomResponseSettings(
                room: room, source: RoomPoint(name: "S", position: [1.3, 1.1, 1.2]),
                receivers: [RoomPoint(name: "R", position: [3.7, 2.9, 1.6])], airAbsorption: false,
                duration: 0.2, maximumReflectionOrder: 200))
        #expect(result.diagnostics.orderLimitedAfter == [nil])
        let expected = specularDecayTime(
            size: size, reflection: (1 - alpha).squareRoot(), c: Atmosphere.standard.soundSpeed)
        let eyring = try #require(result.diagnostics.eyringReverberationTime[4])
        // Without scattering the field is not diffuse, and decay is slower than Eyring's estimate.
        #expect(expected > eyring * 1.1)
        // Interference between sparse early reflections makes single bands scatter; their mean should not.
        var times: [Double] = []
        for band in 4..<OctaveBands.count {
            let filtered = DecayAnalysis.octaveBand(
                result.response.channels[0], sampleRate: 48_000, band: band)
            let measured = try #require(DecayAnalysis.reverberationTime(filtered, sampleRate: 48_000))
            #expect(abs(measured / expected - 1) < 0.15, "band \(band): \(measured) s against \(expected) s")
            times.append(measured)
        }
        let mean = times.reduce(0, +) / Double(times.count)
        #expect(abs(mean / expected - 1) < 0.06, "mean \(mean) s against \(expected) s")
    }

    @Test("The low-frequency cutoff removes the sub-audio offset and leaves audible bands unchanged")
    func lowFrequencyCutoff() throws {
        var settings = RoomResponseSettings(
            room: ShoeboxRoom(size: [5, 4, 3], material: .uniform(0.5, name: "Test")),
            source: RoomPoint(name: "S", position: [1.3, 1.1, 1.2]),
            receivers: [RoomPoint(name: "R", position: [3.7, 2.9, 1.6])], airAbsorption: false, duration: 0.2,
            maximumReflectionOrder: 100,
            lowFrequencyCutoff: 0)
        let raw = try RoomResponseGenerator.generate(settings).response.channels[0]
        settings.lowFrequencyCutoff = 20
        let cut = try RoomResponseGenerator.generate(settings).response.channels[0]
        // The sample sum approximates the response at 0 Hz.
        let rawSum = raw.reduce(0, +)
        #expect(rawSum > 5)
        #expect(abs(cut.reduce(0, +)) < 0.02 * rawSum)
        // Compare well before the end. Where the removed offset is cut off, at the start and end of the
        // response, it leaks slightly into the lower audible bands.
        let early = 0..<4_800
        for band in 2..<OctaveBands.count {
            let before = DecayAnalysis.octaveBand(raw, sampleRate: 48_000, band: band)[early]
            let after = DecayAnalysis.octaveBand(cut, sampleRate: 48_000, band: band)[early]
            #expect(energy(zip(before, after).map { $0 - $1 }) < 0.02 * energy(before))
        }
    }

    @Test("Invalid settings are rejected with a reason")
    func validation() {
        let room = ShoeboxRoom(size: size, material: .rigid)
        let outside = RoomPoint(name: "Outside", position: [9, 1, 1])
        #expect(throws: AcousticError.self) {
            try RoomResponseSettings(room: room, source: source, receivers: [outside]).validate()
        }
        #expect(throws: AcousticError.self) {
            try RoomResponseSettings(room: room, source: source, receivers: [source]).validate()
        }
        var bad = room
        bad.floor.absorption[2] = 1.5
        #expect(throws: AcousticError.self) {
            try RoomResponseSettings(room: bad, source: source, receivers: [receiver]).validate()
        }
        #expect(throws: AcousticError.self) {
            try RoomResponseSettings(
                room: room, source: source, receivers: [receiver], duration: 10, maximumReflectionOrder: 1000
            ).validate()
        }
    }

    @Test("Settings survive a JSON round trip for reproducibility")
    func settingsCodable() throws {
        let settings = RoomResponseSettings(
            room: ShoeboxRoom(size: size, material: .uniform(0.2, name: "Test")), source: source,
            receivers: [receiver])
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(RoomResponseSettings.self, from: data) == settings)
    }
}
