import Foundation
import Testing
import simd

@testable import BlastModel

@Suite("A crater growing over its formation time")
struct CraterGrowthTests {
    private let crater = CraterEstimate(
        charge: Charge(mass: 100, position: SIMD3(10, 10, 0)), groundHeight: 0, ground: .alluvium)!

    @Test("Holsapple's formation time: 0.8 √(V^(1/3) / g) of the bowl, about a third of a second for 100 kg")
    func formationTime() throws {
        let volume = Float.pi / 2 * crater.apparentRadius * crater.apparentRadius * crater.apparentDepth
        #expect(abs(crater.bowlVolume - volume) < 1e-4)
        #expect(abs(crater.formationTime - 0.8 * (cbrt(volume) / 9.806_65).squareRoot()) < 1e-6)
        #expect(crater.formationTime > 0.3 && crater.formationTime < 0.36, "\(crater.formationTime) s")
        // The square root of the size: 500 short tons, 4,536 times the mass, forms about 5 times
        // as slowly (4,536^(1/6) = 4.07, its centre datum aside).
        let big = try #require(
            CraterEstimate(charge: Charge(mass: 453_592, position: .zero), groundHeight: 0, ground: .alluvium)
        )
        #expect(abs(big.formationTime / crater.formationTime - pow(4535.92, 1.0 / 6)) < 1e-3)
        #expect(crater.formedAt == crater.formationTime)
        // Dry soil grows as t^0.29, wet as t^0.35 (μ 0.41 and 0.55).
        #expect(crater.couplingExponent == 0.41)
        let wet = try #require(
            CraterEstimate(charge: Charge(mass: 100, position: .zero), groundHeight: 0, ground: .saturated))
        #expect(wet.couplingExponent == 0.55)
    }

    @Test("Flat until the charge fires, the final crater from its formation time, and monotone between")
    func profile() throws {
        let end = crater.formedAt
        // No crater at or before t = 0, so the ground is flat.
        #expect(crater.grown(atTime: 0) == nil && crater.grown(atTime: -1) == nil)
        #expect(crater.growth(atTime: 0).bowl == 0 && crater.growth(atTime: 0).lip == 0)
        // From the formation time on, the crater itself, to the bit.
        #expect(crater.grown(atTime: end) == crater && crater.grown(atTime: 10 * end) == crater)
        // In between, the radius, depth and lip only grow, the bowl only deepens at every
        // point, and the lip rises last: none in the first half of the time.
        var last = try #require(crater.grown(atTime: end / 1000))
        let distances = stride(from: Float(0), through: crater.lipRadius, by: crater.lipRadius / 64)
        for step in 2...1000 {
            let time = end * Float(step) / 1000
            let now = try #require(crater.grown(atTime: time))
            #expect(now.apparentRadius >= last.apparentRadius && now.apparentDepth >= last.apparentDepth)
            #expect(now.lipHeight >= last.lipHeight && now.lipRadius >= last.lipRadius)
            #expect(now.apparentRadius <= crater.apparentRadius && now.lipHeight <= crater.lipHeight)
            if time <= end / 2 { #expect(now.lipHeight == 0) }
            for r in distances {
                #expect(min(now.change(atDistance: r), 0) <= min(last.change(atDistance: r), 0) + 1e-6)
            }
            last = now
        }
        // The bowl keeps its shape: depth over radius as the final crater's.
        let half = try #require(crater.grown(atTime: end / 2))
        #expect(abs(half.apparentDepth / half.apparentRadius - 0.5) < 1e-5)
        // Half the time, (1/2)^(0.41/1.41) of the size: 82%.
        #expect(abs(half.apparentRadius / crater.apparentRadius - pow(0.5, 0.41 / 1.41)) < 1e-5)
        // Its ranges stay the final crater's.
        #expect(half.radiusRange == crater.radiusRange)
    }

    @Test("A delayed charge's crater starts to grow when it fires")
    func delayed() throws {
        var scene = Scenario(
            name: "Two", domainSize: SIMD3(40, 20, 10), boxes: [],
            charge: Charge(mass: 100, position: SIMD3(10, 10, 0), delay: 0.5))
        scene.additionalCharges = [Charge(mass: 100, position: SIMD3(30, 10, 0), delay: 0.2)]
        let craters = CraterEstimate.craters(of: scene, ground: .alluvium)
        #expect(craters.count == 2)
        // The main charge fires at the start whatever its delay; the other at its own.
        #expect(craters[0].delay == nil && craters[1].delay == 0.2)
        #expect(craters[1].grown(atTime: 0.2) == nil && craters[1].grown(atTime: 0.21) != nil)
        #expect(abs(craters[1].formedAt - 0.2 - craters[1].formationTime) < 1e-6)
        // The delay changes nothing else.
        var undelayed = craters[1]
        undelayed.delay = nil
        let early = try #require(undelayed.grown(atTime: 0.1))
        let late = try #require(craters[1].grown(atTime: 0.3))
        #expect(abs(early.apparentRadius - late.apparentRadius) < 1e-4 * early.apparentRadius)
    }

    @Test(
        "The USD patch is sampled as it grows: flat to the firing, then to the crater, interpolated between")
    func usdSamples() throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "crater-growth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let scenario = Scenario(
            name: "Open", domainSize: SIMD3(40, 40, 10), boxes: [],
            charge: Charge(mass: 100, position: SIMD3(20, 20, 0)))
        // 50 frames over a second, longer than the crater takes.
        let writer = try USDSceneWriter(
            url: folder.appending(path: "long.usda"), scenario: scenario, frameInterval: 0.02)
        for _ in 0..<50 { try writer.append(nil) }
        let samples = writer.craterSamples(crater)
        let codes = samples.map(\.code)
        #expect(codes.first == 0 && samples.first?.bowl == 0, "flat at the blast")
        #expect(codes == codes.sorted() && Set(codes).count == codes.count)
        for (a, b) in zip(samples, samples.dropFirst()) { #expect(b.bowl >= a.bowl && b.lip >= a.lip) }
        // Whole at the first frame past its formation time, and held from there.
        let whole = Int((Double(crater.formedAt) / 0.02).rounded(.up))
        #expect(samples.last.map { $0.code == whole && $0.bowl == 1 && $0.lip == 1 } == true, "\(samples)")
        #expect(samples.count <= whole + 1)
        // The same crater delayed by half a second holds flat until just before it fires.
        var delayed = crater
        delayed.delay = 0.5
        let later = writer.craterSamples(delayed)
        #expect(later.prefix(2).map(\.code) == [0, 25] && later[1].bowl == 0 && later[2].bowl > 0)
        // Delayed past the end, it never grows; a run too short to finish it ends part-dug.
        delayed.delay = 2
        #expect(writer.craterSamples(delayed).allSatisfy { $0.bowl == 0 })
        let short = try USDSceneWriter(
            url: folder.appending(path: "short.usda"), scenario: scenario, frameInterval: 0.001)
        for _ in 0..<20 { try short.append(nil) }
        let part = short.craterSamples(crater)
        #expect(part.last?.code == 19 && part.last.map { $0.bowl < 1 && $0.lip == 0 } == true)
        // The cloud's frames, after the run's at their own times, carry it on to the whole crater.
        let sample = CloudSample(
            time: 0, height: 0, radius: 1, temperature: 300, ambientTemperature: 300, riseSpeed: 0, mass: 1)
        short.addCloud(
            (0..<10).map { n in
                var cloud = sample
                cloud.time = 0.02 + 0.1 * Double(n)
                return cloud
            }, secondsPerFrame: 0.1)
        let carried = short.craterSamples(crater)
        #expect(carried.last.map { $0.code == 24 && $0.bowl == 1 && $0.lip == 1 } == true, "\(carried)")
        short.discard()
        writer.discard()
    }
}
