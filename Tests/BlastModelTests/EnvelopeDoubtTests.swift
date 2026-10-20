import Foundation
import Testing

@testable import BlastModel

/// Which buildings' outcomes the cells could flip: each building's loads judged again at the ends
/// of the band finer cells have read façades within.
@Suite("Envelope doubt")
struct EnvelopeDoubtTests {
    private func pane(_ owner: UUID, pressure: Double) -> EnvelopeComponentLoad {
        EnvelopeComponentLoad(
            id: "\(owner.uuidString)/pane/0.0", owner: owner, kind: .pane,
            region: Box(min: SIMD3(0, 0, 1), max: SIMD3(0.006, 1.2, 2.5)),
            axis: 0, binS: 1e-4, outerPa: Array(repeating: pressure, count: 100), innerPa: [])
    }

    @Test(
        "Glass well past breaking or well short is settled, near breaking in doubt, just short likely different"
    )
    func verdicts() throws {
        let construction = { (id: UUID) in EnvelopeConstruction.assumed(objectID: id) }
        // The pressure that just breaks the pane, by bisection on the damage model itself.
        let probe = UUID()
        func breaks(_ p: Double) -> Bool {
            EnvelopeDamageAssessment.assess(loads: [pane(probe, pressure: p)], constructions: construction)
                .first.map { $0.panesBroken > 0 } ?? false
        }
        var (low, high) = (100.0, 1e6)
        #expect(!breaks(low) && breaks(high))
        for _ in 0..<40 {
            let middle = (low * high).squareRoot()
            if breaks(middle) { high = middle } else { low = middle }
        }
        let threshold = high
        let ids = (0..<4).map { _ in UUID() }
        // Run's pressures against the threshold: far past, well short, short by 1.3 (the band's
        // ends 1.1 and 1.5 straddle it) and short by 1.05 (both ends past it).
        let pressures = [4 * threshold, threshold / 2, threshold / 1.3, threshold / 1.05]
        let loads = zip(ids, pressures).map { pane($0, pressure: $1) }
        let scenario = Scenario(
            name: "Open", domainSize: SIMD3(40, 40, 10), boxes: [],
            charge: Charge(mass: 100, position: SIMD3(20, 20, 0.5)))
        let doubt = EnvelopeDoubt.assess(
            loads: loads, scenario: scenario, cellSize: 0.5, configuration: SolverConfiguration(),
            constructions: construction, band: 1.1...1.5)
        let verdicts = Dictionary(uniqueKeysWithValues: doubt.buildings.map { ($0.id, $0) })
        #expect(verdicts[ids[0]]?.verdict == .settled && verdicts[ids[1]]?.verdict == .settled)
        #expect(verdicts[ids[2]]?.verdict == .inDoubt && verdicts[ids[2]]?.changes == ["glass"])
        #expect(verdicts[ids[3]]?.verdict == .likelyDifferent)
        #expect(doubt.count(.settled) == 2 && doubt.factors == 1.1...1.5)
    }

    @Test("The band follows the measured table by scaled cell, between its points and clamped beyond")
    func band() {
        let at = EnvelopeDoubt.factors(scaledCell: 0.1)
        #expect(abs(at.lowerBound - 1 / 0.99) < 1e-12 && abs(at.upperBound - 1 / 0.63) < 1e-12)
        #expect(EnvelopeDoubt.factors(scaledCell: 0.02) == at)
        let coarse = EnvelopeDoubt.factors(scaledCell: 1)
        #expect(abs(coarse.upperBound - 1 / 0.46) < 1e-12)
        // Halfway in the logarithm between 0.1 and 0.2: halfway between their ratios.
        let between = EnvelopeDoubt.factors(scaledCell: (0.1 * 0.2).squareRoot())
        #expect(abs(between.upperBound - 1 / ((0.63 + 0.52) / 2)) < 1e-9)
        // Refined air reads the finest cells: twice refined by 2, a quarter of the grid's.
        var refined = SolverConfiguration()
        refined.refinement = 2
        refined.refinementLevels = 2
        let scenario = Scenario(
            name: "Open", domainSize: SIMD3(40, 40, 10), boxes: [],
            charge: Charge(mass: 1000, position: SIMD3(20, 20, 0.5)))
        #expect(
            abs(EnvelopeDoubt.scaledCell(scenario: scenario, cellSize: 4, configuration: refined) - 0.1)
                < 1e-9)
    }
}
