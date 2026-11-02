import Foundation
import Testing
import simd

@testable import BlastModel

/// Marking buildings one at a time (`ChargeFromDamage.Marking`, emmettl/bombcad-work#116 stage 2):
/// the summed likelihood kept mark by mark gives the posterior the whole set gives, and what the
/// app draws and says of it.
@Suite("The charge from marked damage, marked one at a time")
struct ChargeFromDamageMarkingTests {
    /// Marks drawn from the made-up table's chances for a charge of 2 t at (120, −80) about the
    /// reference (300, 200), their buildings put in the scene's metres.
    static func marks(count: Int) -> [(id: UUID, mark: ChargeFromDamage.Mark)] {
        let table = ChargeFromDamageTests.table()
        var random = ChargeFromDamage.SplitMix(seed: 11)
        let place = SIMD2(120.0, -80.0)
        let logMass = log(2000.0)
        return (0..<count).map { k in
            let b = (k * 37) % table.buildingCount
            var building = table.header.buildings[b]
            building.east += 300
            building.north += 200
            let glass = ChargeFromDamage.glassClasses(
                broken: table.chance(building: b, channel: 0, place: place, logMass: logMass))
            let walls = ChargeFromDamage.wallsClasses(
                moderate: table.chance(building: b, channel: 1, place: place, logMass: logMass),
                heavy: table.chance(building: b, channel: 2, place: place, logMass: logMass))
            let v = random.uniform()
            return (
                UUID(),
                ChargeFromDamage.Mark(
                    building: building, glass: random.uniform() < glass.whole ? .whole : .broken,
                    walls: k % 3 == 0
                        ? (v < walls.undamaged
                            ? .undamaged : v < walls.undamaged + walls.damaged ? .damaged : .heavy)
                        : nil)
            )
        }
    }

    static func close(_ a: ChargeFromDamage.Posterior?, _ b: ChargeFromDamage.Posterior) -> Double {
        guard let a else { return .infinity }
        var worst = 0.0
        for c in a.cellProbabilities.indices {
            worst = max(worst, abs(a.cellProbabilities[c] - b.cellProbabilities[c]))
        }
        for k in a.yieldProbabilities.indices {
            worst = max(worst, abs(a.yieldProbabilities[k] - b.yieldProbabilities[k]))
        }
        return worst
    }

    @Test("Marks added, changed and cleared one at a time give the posterior the whole set gives")
    func incremental() throws {
        let network = try #require(ChargeFromDamage.Network.builtIn)
        let reference = SIMD2(300.0, 200.0)
        var marking = ChargeFromDamage.Marking(network: network, reference: reference, weighing: .independent)
        #expect(marking.incremental)
        #expect(marking.posterior == nil)
        let list = Self.marks(count: 30)
        for (n, item) in list.enumerated() {
            marking.set(item.mark, for: item.id)
            if [0, 2, 9, 29].contains(n) {
                let whole = network.posterior(marks: list.prefix(n + 1).map(\.mark), reference: reference)
                #expect(Self.close(marking.posterior, whole) < 1e-4, "after \(n + 1) marks")
            }
        }
        // One changed, one cleared, then one cleared by marking nothing seen.
        var expected = list.map(\.mark)
        var changed = list[4].mark
        changed.glass = changed.glass == .broken ? .whole : .broken
        marking.set(changed, for: list[4].id)
        expected[4] = changed
        marking.set(nil, for: list[7].id)
        marking.set(ChargeFromDamage.Mark(building: list[8].mark.building), for: list[8].id)
        expected.remove(at: 8)
        expected.remove(at: 7)
        #expect(marking.marks.count == 28)
        #expect(marking.orderedMarks == expected)
        let whole = network.posterior(marks: expected, reference: reference)
        #expect(Self.close(marking.posterior, whole) < 1e-4)
        // The same mark again changes nothing.
        let before = marking.posterior?.cellProbabilities
        marking.set(changed, for: list[4].id)
        #expect(marking.posterior?.cellProbabilities == before)
        // Searched about another place, as the set weighed there.
        let moved = reference + SIMD2(150, -100)
        marking.recentre(on: moved)
        #expect(Self.close(marking.posterior, network.posterior(marks: expected, reference: moved)) < 1e-4)
        // All at once, and all cleared.
        var again = ChargeFromDamage.Marking(network: network, reference: reference, weighing: .independent)
        again.replaceAll(list)
        #expect(
            Self.close(again.posterior, network.posterior(marks: list.map(\.mark), reference: reference))
                < 1e-4)
        for item in list { again.set(nil, for: item.id) }
        #expect(again.posterior == nil)
        #expect(again.marks.isEmpty)
        again.set(list[0].mark, for: list[0].id)
        #expect(
            Self.close(again.posterior, network.posterior(marks: [list[0].mark], reference: reference)) < 1e-6
        )
    }

    @Test("Weighed as erring together, one at a time as the whole set, neighbours' weights and all")
    func weighedTogether() throws {
        let network = try #require(ChargeFromDamage.Network.builtIn)
        let reference = SIMD2(300.0, 200.0)
        // Neighbours, a shared correlation and a shared error at once, whatever the adopted one is.
        let weighing = try #require(
            ChargeFromDamage.Weighing.named("neighbours=60,power=0.7,rho=0.02,yield=0.4,place=40"))
        #expect(weighing.weighsNeighbours && !weighing.isIndependent)
        var marking = ChargeFromDamage.Marking(network: network, reference: reference, weighing: weighing)
        let list = Self.marks(count: 40)
        for (n, item) in list.enumerated() {
            marking.set(item.mark, for: item.id)
            if [0, 4, 19, 39].contains(n) {
                let whole = network.posterior(
                    marks: list.prefix(n + 1).map(\.mark), reference: reference, weighing: weighing)
                #expect(Self.close(marking.posterior, whole) < 1e-4, "after \(n + 1) marks")
            }
        }
        marking.set(nil, for: list[3].id)
        let left = list.map(\.mark).enumerated().filter { $0.offset != 3 }.map(\.element)
        #expect(
            Self.close(
                marking.posterior, network.posterior(marks: left, reference: reference, weighing: weighing))
                < 1e-4)
        // Weighed as independent again: stage 2's posterior, to the summed likelihood's.
        marking.weigh(as: .independent)
        #expect(Self.close(marking.posterior, network.posterior(marks: left, reference: reference)) < 1e-4)
        #expect(ChargeFromDamage.Weighing.named("independent") == .independent)
        #expect(ChargeFromDamage.Weighing.named(ChargeFromDamage.Weighing.adopted.name) == .adopted)
        #expect(ChargeFromDamage.Weighing.named("neighbours=x") == nil)
        // Weighed together, the posterior is no narrower than as independent.
        let independent = network.posterior(marks: left, reference: reference)
        marking.weigh(as: weighing)
        let wide = try #require(marking.posterior)
        #expect(
            wide.yieldQuantile(0.95) / wide.yieldQuantile(0.05)
                >= independent.yieldQuantile(0.95) / independent.yieldQuantile(0.05))
        #expect(wide.region(0.9).count >= independent.region(0.9).count)
    }

    @Test("Neighbours' weights: a cluster counts as about one, lone marks as one each")
    func neighbourWeights() throws {
        let w = try #require(ChargeFromDamage.Weighing.named("neighbours=50"))
        // Ten marks at one place, and two far apart.
        let places = (0..<10).map { _ in SIMD2(0.0, 0.0) } + [SIMD2(1000, 0), SIMD2(0, 1000)]
        let weights = w.weights(places)
        #expect(weights.prefix(10).allSatisfy { abs($0 - 0.1) < 1e-9 })
        #expect(abs(weights[10] - 1) < 1e-9 && abs(weights[11] - 1) < 1e-9)
        #expect(ChargeFromDamage.Weighing.independent.weights(places).allSatisfy { $0 == 1 })
        let rho = try #require(ChargeFromDamage.Weighing.named("rho=0.1"))
        #expect(abs(rho.sharedScale(count: 11) - 0.5) < 1e-12)
    }

    @Test("A mark is weighed in well under a frame")
    func timing() throws {
        let network = try #require(ChargeFromDamage.Network.builtIn)
        var marking = ChargeFromDamage.Marking(network: network, reference: SIMD2(300, 200))
        var times: [Double] = []
        for item in Self.marks(count: 60) {
            marking.set(item.mark, for: item.id)
            times.append(marking.lastSeconds)
        }
        times.sort()
        print(
            String(
                format: "A mark weighed into 1–60 others: %.2f ms median, %.2f ms at most", 1000 * times[30],
                1000 * times[59]))
        // A frame is 33 ms. Unoptimised builds are hundreds of times slower than the app's, and
        // timed only as they are.
        #if !DEBUG
            #expect(times[30] < 0.033)
        #endif
    }

    @Test("The shades, the regions' outlines and the words drawn from a posterior")
    func drawn() throws {
        // Four cells of 100 m about (1000, 2000): most in the north-east, some in the north-west.
        let p = ChargeFromDamage.Posterior(
            grid: 2, halfWidthM: 100, reference: SIMD2(1000, 2000),
            cellProbabilities: [0, 0.001, 0.299, 0.7],
            logYields: [log(400.0), log(600.0)], yieldProbabilities: [0.5, 0.5])
        let shades = p.shades()
        #expect(shades[0] == 0)
        #expect(shades[3] == 1)
        #expect(abs(Double(shades[2]) - (1 + log10(0.299 / 0.7) / 2)) < 1e-6)
        #expect(shades[1] == 0)
        // Half: the north-east cell alone, its four sides; nine in ten: the north row, six edges.
        #expect(p.outline(0.5).count == 4)
        let ninety = p.outline(0.9)
        #expect(ninety.count == 6)
        // Closed: each corner meets two edges.
        var ends: [SIMD2<Double>: Int] = [:]
        for (a, b) in ninety {
            ends[a, default: 0] += 1
            ends[b, default: 0] += 1
        }
        #expect(ends.values.allSatisfy { $0 % 2 == 0 })
        #expect(ninety.allSatisfy { max($0.0.y, $0.1.y) <= 2100 && min($0.0.y, $0.1.y) >= 2000 })
        let words = p.spoken(about: SIMD2(1000, 2000), aboutName: "the scene's charge")
        #expect(
            words.hasPrefix("Most likely 70 m north-east of the scene's charge; half the chance within 50 m"))
        #expect(words.contains("Yield about 490 kg; nine in ten between"))
        #expect(ChargeFromDamage.Posterior.compass(SIMD2(0, -1)) == "south")
        #expect(ChargeFromDamage.Posterior.compass(SIMD2(-1, 0.1)) == "west")
    }
}
