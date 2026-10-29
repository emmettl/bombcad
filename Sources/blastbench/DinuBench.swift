import BlastCore
import Foundation
import Metal

// A HEB260 column's web under 1.815 kg close in, the CODEC bunker tests (see DinuColumnTest.swift):
//
//   blastbench dinu [--shots m4,m5,E5,E6] [--dx 0.02] [--refine 2 --refine-levels 2] [--h 0.01]
//                   [--ms 5] [--flange 0.16] [--failure 0.27] [--no-rate] [--layers 8]

func runDinu(device: MTLDevice) throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let wanted = (option("shots") ?? "m4,m5,E5,E6").split(separator: ",").map(String.init)
    var settings = DinuColumnTest.Settings()
    if let h = option("h").flatMap({ Float($0) }) { settings.elementSize = h }
    let flanges = option("flange").flatMap { Float($0) }
    if let failure = option("failure").flatMap({ Float($0) }) { settings.failureStrain = failure }
    if let layers = option("layers").flatMap({ Int($0) }) { settings.shellLayers = layers }
    if flag("no-rate") { settings.rateLaw = false }
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.02
    let duration = (option("ms").flatMap { Double($0) } ?? 5) / 1000
    var refinement = SolverConfiguration.recommended
    refinement.refinement = 2
    refinement.refinementLevels = 2
    configureRefinement(&refinement)
    print(
        "HEB260, shells of "
            + "\(format(Double(settings.elementSize * 1000), 1)) mm; air \(format(Double(cellSize * 1000), 0)) mm "
            + "refined \(refinement.refinementLevels) x \(refinement.refinement); \(format(duration * 1000, 1)) ms"
    )
    for shot in DinuColumnTest.shots where wanted.contains(shot.name) {
        var settings = DinuColumnTest.settings(settings, for: shot)
        if let flanges { settings.section.flangeWidth = flanges }
        let r = try DinuColumnTest.run(
            device: device, shot: shot, settings: settings, cellSize: cellSize,
            refinement: refinement.refinement, levels: refinement.refinementLevels, duration: duration,
            configure: { configureRefinement(&$0) }, progress: { print("  " + $0) })
        print(
            String(
                format:
                    "%@ %.3f kg at %.2f m (Z %.3f), flanges %.0f mm: web %@; %d web shells removed, breach %.0f mm along x %.0f mm across "
                    + "(reported %.0f mm along); %d flange shells removed",
                shot.name, shot.charge, shot.standoff, shot.scaledDistance,
                settings.section.flangeWidth * 1000,
                r.webRemoved > 0 ? "breached" : "held",
                r.webRemoved, r.breachLength * 1000, r.breachWidth * 1000,
                (DinuColumnTest.reportedBreachLength(shot) ?? 0) * 1000, r.flangeRemoved))
        print(
            String(
                format:
                    "   web at the charge: peak %.1f mm, end %.1f mm; plastic strain web %.3f, flanges %.3f; "
                    + "flange tips out %.1f mm; sway %.1f mm",
                r.webPeak * 1000, r.webFinal * 1000, r.webPlasticStrain, r.flangePlasticStrain,
                r.flangeSpread * 1000,
                r.columnSway * 1000))
        print(
            String(
                format: "   reflected at the web: %.1f MPa, %.0f Pa s; %@ the test (%@); %.0f s",
                r.reflectedPeak / 1e6, r.reflectedImpulse, r.agrees ? "agrees with" : "differs from",
                shot.outcome,
                r.wallSeconds))
    }
}
