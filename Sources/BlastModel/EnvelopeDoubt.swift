import Foundation
import simd

/// Which envelope buildings' outcomes the run's cells could flip (docs/refinement-steering.md,
/// "Which buildings the cells could flip"). Each building's loads are scaled to the two ends of
/// the band within which cells twice as fine have read districts' façade peaks
/// (`convergence`), and judged again. A building whose glass or structure comes out the same at
/// both ends as in the run is settled; one whose two ends agree with each other but not with the
/// run would likely come out differently on finer cells; one whose ends differ is in doubt. It
/// costs two more judgements of loads the run already has, and no air.
public struct EnvelopeDoubt: Codable, Hashable, Sendable {
    public enum Verdict: String, Codable, Hashable, Sendable {
        /// The same at both ends of the band as in the run.
        case settled
        /// The two ends of the band disagree.
        case inDoubt
        /// Both ends agree, and not with the run: finer cells would likely change it.
        case likelyDifferent
    }

    public struct Building: Codable, Hashable, Sendable {
        public var id: UUID
        public var verdict: Verdict
        /// What differs across the band: "glass" (some pane broken or none), "structure" (the
        /// worst level of its walls and roofs).
        public var changes: [String]
    }

    /// The factors the loads were scaled by: what cells twice as fine might read against these.
    public var factors: ClosedRange<Double>
    /// The cells the façades were read on, m/kg^(1/3) of the largest charge.
    public var scaledCell: Double
    public var buildings: [Building]

    public func count(_ verdict: Verdict) -> Int { buildings.filter { $0.verdict == verdict }.count }

    /// Façade peaks on cells of a scaled size (m/kg^(1/3)) against cells half as large, each
    /// building side's peak over the finer run's, 10th and 90th percentiles: a 150 m block of
    /// 223 buildings under 1 t on 4, 2 and 1 m cells (0.4 and 0.2), and Beirut's 1 km box under
    /// 500 t on 8 and 4 m (0.1), 20 October 2026. Between them, by the logarithm of the cell;
    /// beyond, the nearest.
    public static let convergence: [(scaledCell: Double, low: Double, high: Double)] = [
        (0.1, 0.63, 0.99), (0.2, 0.52, 1.17), (0.4, 0.46, 0.97),
    ]

    /// The band of `convergence` at `scaledCell`, as factors on the coarse loads.
    public static func factors(scaledCell: Double) -> ClosedRange<Double> {
        let table = convergence
        let ratios: (Double, Double)
        if scaledCell <= table.first!.scaledCell {
            ratios = (table.first!.low, table.first!.high)
        } else if scaledCell >= table.last!.scaledCell {
            ratios = (table.last!.low, table.last!.high)
        } else {
            let upper = table.firstIndex { $0.scaledCell >= scaledCell }!
            let (a, b) = (table[upper - 1], table[upper])
            let t = log(scaledCell / a.scaledCell) / log(b.scaledCell / a.scaledCell)
            ratios = (a.low + (b.low - a.low) * t, a.high + (b.high - a.high) * t)
        }
        return (1 / ratios.1)...(1 / ratios.0)
    }

    /// The cells the façades are read on, m/kg^(1/3) of the largest charge: the grid's, or its
    /// finest level's where the air is refined, as the recorder reads the finest cells beside a
    /// face. Where the shock is too weak to be refined the façades read coarser cells, and the
    /// band is too narrow for them.
    public static func scaledCell(
        scenario: Scenario, cellSize: Float, configuration: SolverConfiguration
    ) -> Double {
        let charges = [scenario.charge] + (scenario.additionalCharges ?? [])
        let mass = Double(charges.map(\.mass).max() ?? 1)
        var cell = Double(cellSize)
        if configuration.refinement > 1 {
            cell /= Double(configuration.refinement)
            if configuration.refinementLevels > 1 { cell /= Double(configuration.refinement) }
        }
        return cell / cbrt(max(mass, 1e-6))
    }

    /// Each envelope building with loads, judged at the ends of the band.
    public static func assess(
        loads: [EnvelopeComponentLoad], scenario: Scenario, cellSize: Float,
        configuration: SolverConfiguration, constructions: (UUID) -> EnvelopeConstruction,
        band: ClosedRange<Double>? = nil
    ) -> EnvelopeDoubt {
        let cell = scaledCell(scenario: scenario, cellSize: cellSize, configuration: configuration)
        let factors = band ?? factors(scaledCell: cell)
        func judged(_ factor: Double) -> [UUID: EnvelopeBuildingDamage] {
            let scaled = factor == 1 ? loads : loads.map { $0.scaled(by: factor) }
            return Dictionary(
                uniqueKeysWithValues: EnvelopeDamageAssessment.assess(
                    loads: scaled, constructions: constructions
                )
                .map { ($0.id, $0) })
        }
        let (run, lower, upper) = (judged(1), judged(factors.lowerBound), judged(factors.upperBound))
        func outcome(_ damage: EnvelopeBuildingDamage) -> (glass: Bool, structure: EnvelopeDamageLevel) {
            (damage.panesBroken > 0, damage.structuralLevels.upperBound)
        }
        let buildings = run.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { id -> Building? in
            guard let base = run[id], let a = lower[id], let b = upper[id] else { return nil }
            let (o, l, u) = (outcome(base), outcome(a), outcome(b))
            let changes =
                (o.glass != l.glass || l.glass != u.glass ? ["glass"] : [])
                + (o.structure != l.structure || l.structure != u.structure ? ["structure"] : [])
            let verdict: Verdict =
                l.glass != u.glass || l.structure != u.structure
                ? .inDoubt : (l.glass == o.glass && l.structure == o.structure ? .settled : .likelyDifferent)
            return Building(id: id, verdict: verdict, changes: changes)
        }
        return EnvelopeDoubt(factors: factors, scaledCell: cell, buildings: buildings)
    }
}

/// The view's colours for `EnvelopeDoubt`'s verdicts, by code 8–10: settled, in doubt, likely
/// different. Grey, orange and purple stay apart under the three colour blindnesses, and apart
/// from the damage palette's light green and blue.
public enum EnvelopeDoubtColour {
    public static let first = 8
    public static let palette: [SIMD3<Float>] = [
        SIMD3(0.780, 0.800, 0.820), SIMD3(0.929, 0.502, 0.098), SIMD3(0.533, 0.200, 0.600),
    ]
    public static let labels = ["Settled", "In doubt", "Likely different"]

    public static func code(_ verdict: EnvelopeDoubt.Verdict) -> Int {
        switch verdict {
        case .settled: first
        case .inDoubt: first + 1
        case .likelyDifferent: first + 2
        }
    }
}

extension EnvelopeComponentLoad {
    /// The same load with every pressure multiplied by `factor`.
    public func scaled(by factor: Double) -> EnvelopeComponentLoad {
        var load = self
        load.outerPa = outerPa.map { $0 * factor }
        load.innerPa = innerPa.map { $0 * factor }
        load.stripPa = stripPa.map { ($0.outer.map { $0 * factor }, $0.inner.map { $0 * factor }) }
        return load
    }
}
