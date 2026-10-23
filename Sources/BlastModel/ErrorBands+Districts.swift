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
            id: "structureChancesSkill", low: 0.61, high: 0.74,
            document: "validation.md#the-walls-and-roofs-chances-against-beiruts-runs",
            quote: "Brier skill 0.61 for concrete walls moderate or worse, 0.74 for roofs"),
        Figure(
            id: "structureChancesUnderCall", low: 0.1, high: 0.1,
            document: "validation.md#the-walls-and-roofs-chances-against-beiruts-runs",
            quote: "each tenth of chance within 0.1"),
        Figure(
            id: "structureChancesRoofLow", low: 0.11, high: 0.18,
            document: "validation.md#the-walls-and-roofs-chances-against-beiruts-runs",
            quote: "low by 0.11–0.18"),
        // The walls' chances with the learned field model's peaks, at its own calibration, against
        // the surrogate's at its own, on the 2 m references (emmettl/bombcad-work#19).
        Figure(
            id: "learnedWallsRefined", low: 0.61, high: 0.65,
            document: "validation.md#the-walls-and-roofs-chances-against-beiruts-runs",
            quote: "0.65 with the learned field model's peaks, against 0.61"),
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
        // judged again on the façade terms refitted on 23 October 2026, #56).
        Figure(
            id: "learnedModel2Glass", low: 0.35, high: 0.44,
            document: "learned-models.md#field-model-2-in-the-app-23-october-2026",
            quote: "glass blown out over the app's sides, Brier skill 0.44 against field model 1's 0.35"),
        Figure(
            id: "learnedModel2GlassUpper", low: 0.32, high: 0.43,
            document: "learned-models.md#field-model-2-in-the-app-23-october-2026",
            quote: "above the ground floor 0.43 against 0.32"),
        Figure(
            id: "learnedModel2Walls", low: 0.654, high: 0.656,
            document: "learned-models.md#field-model-2-in-the-app-23-october-2026",
            quote: "concrete walls moderate or worse, Brier skill 0.656 against field model 1's 0.654"),
        Figure(
            id: "dragPreviewGlass", low: 0.89, high: 0.92,
            document: "surrogate-first-look.md#dragging-the-charge-20-october-2026",
            quote: "within 0.1 of the full estimate's on 89–92% of sides"),
        Figure(
            id: "dragPreviewWalls", low: 0.988, high: 0.999,
            document: "surrogate-first-look.md#dragging-the-charge-20-october-2026",
            quote: "within 0.1 on 98.8–99.9% of buildings"),
        Figure(
            id: "dragPreviewDamage", low: 0.997, high: 0.997,
            document: "surrogate-first-look.md#dragging-the-charge-20-october-2026",
            quote: "the same for 99.7% of buildings"),
        Figure(
            id: "glassChancesBrier", low: 0.017, high: 0.108,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "Brier score 0.017, against 0.108"),
        Figure(
            id: "glassChancesBins", low: 0.06, high: 0.06,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "within 0.06 of the share of runs"),
        Figure(
            id: "glassChancesThrown", low: 0.73, high: 0.73,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "condition 3b: skill 0.73"),
        Figure(
            id: "glassChancesTest", low: 0.1, high: 0.1,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "within 0.1 of the share seen"),
        Figure(
            id: "glassChancesSurvey", low: 0.27, high: 0.93,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "blown out 0.93 at 0.75–1 km where GEER saw 0.27"),
        Figure(
            id: "openingsSurvey", low: 0.27, high: 0.34,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "openings blown out 0.34 at 0.75–1 km where GEER saw 0.27"),
        Figure(
            id: "openingsSkill", low: 0.19, high: 0.19,
            document: "validation.md#the-glass-chances-against-beiruts-runs-and-survey",
            quote: "skill 0.19 (Brier 0.138"),
        Figure(
            id: "surrogateGlassSides", low: 0.77, high: 0.84,
            document: "validation.md#the-quick-estimate-against-beiruts-runs",
            quote: "agrees with the run's for 77–84%"),
        Figure(
            id: "surrogateConcrete", low: 0.29, high: 0.49,
            document: "validation.md#the-quick-estimate-against-beiruts-runs",
            quote: "29–49% of the concrete"),
        Figure(
            id: "surrogateStone", low: 0.46, high: 0.53,
            document: "validation.md#the-quick-estimate-against-beiruts-runs",
            quote: "46–53% of the stone"),
        Figure(
            id: "surrogateRoof", low: 0.29, high: 0.64,
            document: "validation.md#the-quick-estimate-against-beiruts-runs",
            quote: "29–64% of the roofs"),
        Figure(
            id: "surrogateNearPeak", low: 0.96, high: 0.97,
            document: "validation.md#the-quick-estimate-against-beiruts-runs",
            quote: "peaks 0.96–0.97"),
        Figure(
            id: "surrogateFarLoads", low: 1.03, high: 1.65,
            document: "validation.md#the-quick-estimate-against-beiruts-runs",
            quote: "1.03–1.65 times the run's on the median"),
        Figure(
            id: "hybridFarPeak", low: 0.95, high: 1.19,
            document: "validation.md#the-hybrid-far-field-against-beiruts-runs",
            quote: "façade peaks 0.95–1.19 of the full run's to 2.5 km"),
        Figure(
            id: "hybridFarImpulse", low: 1.04, high: 2.0,
            document: "validation.md#the-hybrid-far-field-against-beiruts-runs",
            quote: "impulses 1.04–2.0 times"),
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
