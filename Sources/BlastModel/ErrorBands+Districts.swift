import Foundation
import simd

// The figures of the estimates beside a run.
// Split from ErrorBands.swift (emmettl/bombcad-work#50); see that file for the types.

extension ValidationTables {
    /// Estimates beside a run, against BombCAD's own runs. Part of `figures`, in its order.
    static let districtFigures: [Figure] = [
        // Estimates beside a run, against BombCAD's own runs: the standing lines of
        // `FacadeLoadSurrogate`, `HybridFarField` and `ChargeInference` are worded from these.
        Figure(
            id: "glassChancesBrier", low: 0.020, high: 0.108,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "Brier score 0.020, against 0.108"),
        Figure(
            id: "glassChancesBins", low: 0.05, high: 0.05,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "within 0.05 of the share of runs"),
        Figure(
            id: "glassChancesThrown", low: 0.72, high: 0.72,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "condition 3b: skill 0.72"),
        Figure(
            id: "glassChancesTest", low: 0.1, high: 0.1,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "within 0.1 of the share seen"),
        Figure(
            id: "glassChancesSurvey", low: 0.27, high: 0.91,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "blown out 0.91 at 0.75–1 km where GEER saw 0.27"),
        Figure(
            id: "openingsSurvey", low: 0.27, high: 0.31,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "openings blown out 0.31 at 0.75–1 km where GEER saw 0.27"),
        Figure(
            id: "openingsSkill", low: 0.15, high: 0.15,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "skill 0.15 (Brier 0.144"),
        Figure(
            id: "surrogateGlassSides", low: 0.75, high: 0.84,
            document: "validation.md#the-quick-estimate-against-beiruts-runs",
            quote: "agrees with the run's for 75–84%"),
        Figure(
            id: "surrogateConcrete", low: 0.28, high: 0.49,
            document: "validation.md#the-quick-estimate-against-beiruts-runs",
            quote: "28–49% of the concrete"),
        Figure(
            id: "surrogateStone", low: 0.36, high: 0.45,
            document: "validation.md#the-quick-estimate-against-beiruts-runs",
            quote: "36–45% of the stone"),
        Figure(
            id: "surrogateRoof", low: 0.29, high: 0.64,
            document: "validation.md#the-quick-estimate-against-beiruts-runs",
            quote: "29–64% of the roofs"),
        Figure(
            id: "surrogateNearPeak", low: 0.85, high: 1.00,
            document: "validation.md#the-quick-estimate-against-beiruts-runs",
            quote: "peaks 0.85–1.00"),
        Figure(
            id: "surrogateFarLoads", low: 1.09, high: 1.63,
            document: "validation.md#the-quick-estimate-against-beiruts-runs",
            quote: "1.09–1.63 times the run's on the median"),
        Figure(
            id: "hybridFarPeak", low: 0.76, high: 1.04,
            document: "validation.md#the-hybrid-far-field-against-beiruts-runs",
            quote: "façade peaks 0.76–1.04 of the full run's to 2.5 km"),
        Figure(
            id: "hybridFarImpulse", low: 1.04, high: 1.5,
            document: "validation.md#the-hybrid-far-field-against-beiruts-runs",
            quote: "impulses 1.04–1.5 times"),
        Figure(
            id: "inferredBeirut", low: 0.50, high: 0.54,
            document: "validation.md#the-charge-from-its-arrivals",
            quote: "0.50–0.54 kt"),
        Figure(
            id: "inferredWithRatios", low: 0.97, high: 1.01,
            document: "validation.md#the-charge-from-its-arrivals",
            quote: "0.97–1.01 of it on 2 m cells"),
        Figure(
            id: "inferredByCurvesAlone", low: 1.27, high: 1.95,
            document: "validation.md#the-charge-from-its-arrivals",
            quote: "1.27–1.95 times the yield"),
    ]
}
