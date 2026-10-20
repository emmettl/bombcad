import simd

extension FacadeLoadSurrogate.Coefficients {
    /// The roofs' own terms (#10, stage 3): fitted to the roofs of the dense made-up district at 20,
    /// 100 and 500 t on 4 m cells, their loads uncapped (`Scripts/fit-surrogate.py --drop facing`:
    /// a roof faces a charge on the ground only by a sliver of a cosine). On the façades' terms
    /// Beirut's roofs came a level light; on these, of the roofs either calls damaged on Beirut's near
    /// boxes, held out, 29–64% take the run's level and 99–100% come within one
    /// (docs/validation.md, "The quick estimate against Beirut's runs").
    public static let roofs = FacadeLoadSurrogate.Coefficients(
        peak: [-1.227, 0.000, -0.125, -0.028, -0.012, 0.271, -0.347, -0.120, 0.018, -0.042, -0.224],
        impulse: [0.208, 0.000, 0.545, -0.022, -0.014, 0.806, -0.275, -0.205, -0.058, -0.182, 0.379],
        rise: [-0.001, 0.000, 0.829, 0.025, -0.000, 0.050, -0.040, 0.002, -0.046, 0.005, -0.011],
        scaledRange: 4.6...38.6, scatter: SIMD2(0.145, 0.270),
        fittedTo: "roofs of the dense made-up district at 20, 100 and 500 t (4 m cells, uncapped)")
}
