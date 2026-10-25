import BlastModel
import Foundation

// `blastbench hinge-sections [--through 2,4] [--to 0.1]`: the large-panel block's sections bent
// statically on the CPU reference (`CrackedHex`, emmettl/bombcad-work#20), to see what a hinge in
// them carries on the whole-event mesh (emmettl/bombcad-work#36 step 3): the 175 mm wall with its
// light central mesh, and the floor with its soffit bars, sagging and hogging. For each, the
// moment per metre width at each curvature by fibre section analysis (crack band one element),
// today's one-point element (bars smeared, hourglass control at its cap, read as the shader caps
// it), the reference's own earlier reading of that cap, its cap without the bars or with what
// their membrane stress leaves, and the element that bends in its cracked concrete
// (`assumedStrainCracking`, bars at their height); and where today's moment sits by layer. No
// axial force. CPU only; no GPU.
func runHingeSections() {
    let throughs = (option("through") ?? "2,4").split(separator: ",").compactMap { Int($0) }
    let top = option("to").flatMap { Double($0) } ?? 0.1
    // The block's concrete (`StructureMaterial.concrete` at 31 MPa) and mild steel.
    let fc = 31.0
    let concrete = CrackedHex.Concrete(
        youngsModulus: 4700e6 * fc.squareRoot(), compressiveStrength: fc * 1e6,
        tensileStrength: 0.3e6 * pow(fc, 2.0 / 3.0), fractureEnergy: 73 * pow(fc, 0.18), bandWidth: 0.0875)
    let steel = CrackedHex.Steel(yieldStress: 250e6)
    let sections: [(String, CrackedHex.ReinforcedSection)] = [
        (
            "wall, 142 mm²/m at mid-depth",
            .init(depth: 0.175, barHeight: 0.0875, barAreaPerWidth: 142e-6, concrete: concrete, steel: steel)
        ),
        (
            "floor sagging, 524 mm²/m 30 mm in",
            .init(depth: 0.175, barHeight: 0.03, barAreaPerWidth: 524e-6, concrete: concrete, steel: steel)
        ),
        (
            "floor hogging, the same bars 145 mm from the tension face",
            .init(depth: 0.175, barHeight: 0.145, barAreaPerWidth: 524e-6, concrete: concrete, steel: steel)
        ),
    ]
    let curvatures =
        stride(from: 0.0005, through: 0.005, by: 0.0005).map { $0 }
        + stride(from: 0.01, through: top, by: 0.01).map { $0 }
    for (name, section) in sections {
        print("\n\(name): cracking curvature \(String(format: "%.4f", section.crackingCurvature)) /m")
        var columns: [(String, [Double])] = []
        for n in throughs {
            let h = section.depth / Double(n)
            let reference = CrackedHex.sectionAnalysis(section, bandWidth: h, curvatures: curvatures)
            func run(
                _ formulation: CrackedHex.Formulation = .today, smeared: Bool = true,
                steel: CrackedHex.HourglassSteel = .smeared, atStrength: Bool = false
            )
                -> CrackedHex.MomentCurvatureResult
            {
                CrackedHex.momentCurvature(
                    section, elementsThroughDepth: n, formulation: formulation, curvatures: curvatures,
                    smearedBars: smeared, hourglassSteel: steel, uncrackedCapAtStrength: atStrength)
            }
            // The shader's one-point element (an uncracked element capped at the tension its
            // centre has reached), the reference's own reading of it (capped at the strength), and
            // the variants of its cap; and the element that bends in its cracked concrete.
            let shader = run()
            let variants: [(String, CrackedHex.MomentCurvatureResult)] = [
                ("one-point (shader)", shader),
                ("one-point, uncracked cap at f_t", run(atStrength: true)),
                ("cap without bars", run(steel: .none)),
                ("cap with the bars' strength left", run(steel: .remaining)),
                ("assumed strain", run(.cracked, smeared: false)),
            ]
            // Where the shader's moment sits at the last curvature: per layer (the tension face
            // first), the hourglass modes' forces as moment per width (2 F an element) and the
            // centre's largest tensile and compressive strains so far.
            let layers = shader.states.prefix(n).enumerated().map { k, state in
                let moments = state.hourglassForce.map { 2 * ($0 * $0).sum().squareRoot() / 1e3 }
                return String(
                    format: "layer %d: modes %@ kN m/m, tension %.4f, compression %.4f", k,
                    moments.map { String(format: "%.2f", $0) }.joined(separator: "/"),
                    state.centre.tension.max(), state.centre.compression.max())
            }
            print(
                "  \(n) through, the shader's element at its last curvature: "
                    + layers.joined(separator: "; "))
            columns.append(("section (band \(n))", reference))
            for (label, result) in variants { columns.append(("\(label), \(n)", result.moments)) }
        }
        print("κ (1/m) | " + columns.map(\.0).joined(separator: " | ") + "  (kN m per m)")
        for (i, kappa) in curvatures.enumerated() {
            let cells = columns.map { i < $0.1.count ? String(format: "%.2f", $0.1[i] / 1e3) : "–" }
            print(String(format: "%.4f", kappa) + " | " + cells.joined(separator: " | "))
        }
    }
}
