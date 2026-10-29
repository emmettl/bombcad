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
            id: "structureChancesSkill", low: 0.60, high: 0.74,
            document: "validation.md#the-walls-and-roofs-chances-against-beiruts-runs",
            quote: "Brier skill 0.60 for concrete walls moderate or worse, 0.74 for roofs"),
        // Concrete walls' tenths: each within 0.1 of the runs, since the impulse took ×0.95 on 25
        // October 2026 (emmettl/bombcad-work#102; at ×1.15 one tenth was 0.11 under, #99).
        Figure(
            id: "structureChancesUnderCall", low: 0.1, high: 0.1,
            document: "validation.md#the-walls-and-roofs-chances-against-beiruts-runs",
            quote: "each tenth of chance within 0.1 of the share of runs, which passes"),
        Figure(
            id: "structureChancesRoofLow", low: 0.11, high: 0.18,
            document: "validation.md#the-walls-and-roofs-chances-against-beiruts-runs",
            quote: "low by 0.11–0.18"),
        // The walls' chances with the learned field model's peaks, at its own calibration, against
        // the surrogate's at its own, on the 2 m references (emmettl/bombcad-work#19).
        Figure(
            id: "learnedWallsRefined", low: 0.60, high: 0.65,
            document: "validation.md#the-walls-and-roofs-chances-against-beiruts-runs",
            quote: "0.65 with the learned field model's peaks, against 0.60"),
        Figure(
            id: "surrogateCloseInShielded", low: 1.0, high: 1.2,
            document: "surrogate-first-look.md#adopted-23-october-2026",
            quote: "behind buildings close in it reads 1.0–1.2 times the 4 m runs' peaks"),
        // The learned field model's peak at ground-floor façades, in the quick estimate
        // (`LearnedField.standing`): the surrogate's figure low, the model's high.
        Figure(
            id: "learnedPeakGlass", low: 0.916, high: 0.942,
            document: "learned-models.md#in-the-apps-quick-estimate-21-october-2026",
            quote:
                "glass by side exactly right on 0.916 of sides with the surrogate's peak and 0.942 with the model's"
        ),
        Figure(
            id: "learnedPeakGlassSkill", low: 0.62, high: 0.72,
            document: "learned-models.md#in-the-apps-quick-estimate-21-october-2026",
            quote: "Heidke skill 0.62 and 0.72"),
        Figure(
            id: "learnedPeakWalls", low: 0.69, high: 0.78,
            document: "learned-models.md#in-the-apps-quick-estimate-21-october-2026",
            quote: "concrete walls moderate or worse, Brier skill 0.69 and 0.78"),
        Figure(
            id: "learnedPeakWallsApp", low: 0.60, high: 0.68,
            document: "learned-models.md#in-the-apps-quick-estimate-21-october-2026",
            quote: "at the app's own load factor of 1.0, 0.60 and 0.68"),
        // Field model 2 in the quick estimate (`LearnedField.standing`), against Beirut's 2 m
        // references: field model 1's figure and model 2's, the lower first (emmettl/bombcad-work#69;
        // on the façade terms refitted on 23 October 2026, #56, and on the references run to their
        // judged corners rather than to 3 s, the same day).
        Figure(
            id: "learnedModel2Glass", low: 0.66, high: 0.72,
            document: "learned-models.md#on-the-clear-top-terms-25-october-2026",
            quote: "0.0397 / 0.64; 0.0365 / 0.66; 0.0307 / 0.72"),
        Figure(
            id: "learnedModel2GlassUpper", low: 0.65, high: 0.71,
            document: "learned-models.md#on-the-clear-top-terms-25-october-2026",
            quote: "0.0393 / 0.65; 0.0323 / 0.71"),
        Figure(
            id: "learnedModel2Walls", low: 0.653, high: 0.653,
            document: "learned-models.md#on-the-clear-top-terms-25-october-2026",
            quote: "both pass the tenths test on the new terms, at skill 0.653"),
        // The drag preview, each side's glass a strip for each way its outline faces it since 29
        // October 2026 (emmettl/bombcad-work#110; 82–93% with one strip for the side).
        Figure(
            id: "dragPreviewGlass", low: 0.86, high: 0.95,
            document: "surrogate-first-look.md#dragging-the-charge-20-october-2026",
            quote: "within 0.1 of the full estimate's on 86–95% of sides"),
        Figure(
            id: "dragPreviewWalls", low: 0.986, high: 0.999,
            document: "surrogate-first-look.md#dragging-the-charge-20-october-2026",
            quote: "within 0.1 on 98.6–99.9% of buildings"),
        Figure(
            id: "dragPreviewDamage", low: 0.995, high: 0.995,
            document: "surrogate-first-look.md#dragging-the-charge-20-october-2026",
            quote: "the same for 99.5% of buildings"),
        // The glass chances, the quick estimate's loads and the hybrid on the deep-city terms with
        // each wall facing as its map outline, adopted on 28 October 2026 (emmettl/bombcad-work#109,
        // its judges; the deep-city terms of 25 October, #105, before).
        Figure(
            id: "glassChancesBrier", low: 0.025, high: 0.104,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "Brier score 0.025, against 0.104"),
        Figure(
            id: "glassChancesBins", low: 0.07, high: 0.07,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "up to 0.07 under the share of runs"),
        Figure(
            id: "glassChancesThrown", low: 0.039, high: 0.025,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "condition 3b: Brier 0.039, against 0.025"),
        Figure(
            id: "glassChancesTest", low: 0.1, high: 0.1,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "within 0.1 of the share seen"),
        // The diagonal-line notes of emmettl/bombcad-work#107 (glassChancesDiagonal,
        // surrogateGlassSidesDiagonal, hybridFarPeakDiagonal) were retired on 28 October 2026
        // (#109): with the grid turned 45° (#108) the runs' loads go with the city, not the line's
        // angle to the cells, so the diagonal lines are not the cleaner ones. The split by angle was
        // the surrogate's own, from its facing read off the cells' staircase faces.
        Figure(
            id: "glassChancesSurvey", low: 0.27, high: 0.96,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "blown out 0.96 at 0.75–1 km where GEER saw 0.27"),
        Figure(
            id: "openingsSurvey", low: 0.27, high: 0.36,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "openings blown out 0.36 at 0.75–1 km where GEER saw 0.27"),
        Figure(
            id: "openingsSkill", low: 0.18, high: 0.18,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "skill 0.18 (Brier 0.139"),
        Figure(
            id: "surrogateGlassSides", low: 0.68, high: 0.89,
            document: "validation.md#the-quick-estimate-against-beiruts-runs",
            quote: "agrees with the run's for 68–89%"),
        Figure(
            id: "surrogateConcrete", low: 0.29, high: 0.51,
            document: "validation.md#the-quick-estimate-against-beiruts-runs",
            quote: "29–51% of the concrete"),
        Figure(
            id: "surrogateStone", low: 0.45, high: 0.56,
            document: "validation.md#the-quick-estimate-against-beiruts-runs",
            quote: "45–56% of the stone"),
        Figure(
            id: "surrogateRoof", low: 0.29, high: 0.64,
            document: "validation.md#the-quick-estimate-against-beiruts-runs",
            quote: "29–64% of the roofs"),
        Figure(
            id: "surrogateNearPeak", low: 0.96, high: 1.06,
            document: "validation.md#the-quick-estimate-against-beiruts-runs",
            quote: "peaks 0.96–1.06"),
        Figure(
            id: "surrogateFarLoads", low: 0.89, high: 1.04,
            document: "validation.md#the-quick-estimate-against-beiruts-runs",
            quote: "0.89–1.04 times the run's on the median"),
        Figure(
            id: "hybridFarPeak", low: 0.87, high: 1.09,
            document: "validation.md#the-hybrid-far-field-against-beiruts-runs",
            quote: "façade peaks 0.87–1.09 of the full run's to 2.5 km"),
        Figure(
            id: "hybridFarImpulse", low: 1.05, high: 1.14,
            document: "validation.md#the-hybrid-far-field-against-beiruts-runs",
            quote: "impulses 1.05–1.14 times"),
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
