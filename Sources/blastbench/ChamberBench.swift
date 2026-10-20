import BlastCore
import Foundation
import Metal
import simd

// `blastbench chamber`.
// Split from main.swift (emmettl/bombcad-work#51).

/// The internal explosion test of Shang et al. (2026).
func runChamber() throws {
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.1
    let elementSize = option("h").flatMap { Float($0) } ?? 0.1
    let duration = option("time").flatMap { Double($0) } ?? 0.3
    let downstand = !flag("no-downstand")
    let chargeScale = option("charge-scale").flatMap { Float($0) } ?? 1
    if let text = option("pressures") {
        // The roof's resistance: the vent closed, the chamber filled with air at a steady
        // overpressure, and the roof edge watched.
        print(
            "Chamber of Shang et al. (2026), vent closed, filled with steady overpressure; roof edge at mid-span"
        )
        print(pad("kPa", 8) + pad("peak", 10) + pad("end", 10) + "failed")
        for kilopascals in text.split(separator: ",").compactMap({ Float($0) }) {
            let result = try ChamberTest.pressureTest(
                device: device, overpressure: kilopascals * 1000, elementSize: elementSize, duration: duration
            )
            print(
                pad(format(Double(kilopascals), 0), 8)
                    + pad("\(format(Double(result.peakDeflection) * 1000, 0)) mm", 10)
                    + pad("\(format(Double(result.edgeHistory.last?.y ?? 0) * 1000, 0)) mm", 10)
                    + "\(result.summary.erodedElements)")
        }
        return
    }
    print(
        "Internal explosion in a reinforced concrete chamber (Shang et al., 2026): "
            + "4 x \(format(Double(50 * chargeScale), 1)) kg TNT, half-model")
    print(
        "Air cells \(format(Double(cellSize), 3)) m, elements \(format(Double(elementSize), 3)) m, \(format(duration * 1000, 0)) ms"
            + (downstand ? "" : ", no down-stand"))
    // The open faces, across and above, 4 m/kg^(1/3) from the charge and the chamber by default
    // (since 18 October 2026); `--tight` keeps the box of 1 m either side and 2 m above, as before;
    // `--pad 0,11,10` moves them by hand (m: across below, which moves the chamber, across above,
    // and the top).
    var room =
        flag("tight")
        ? (low: .zero, high: .zero) : ChamberTest.scenario(elementSize: elementSize).openFaceRoom(step: 0.5)
    if let v = option("pad")?.split(separator: ",").compactMap({ Float($0) }), v.count == 3 {
        room = (SIMD3(0, v[0], 0), SIMD3(0, v[1], v[2]))
    }
    var scenario = ChamberTest.scenario(
        elementSize: elementSize, downstand: downstand, ties: !flag("no-ties"), elastic: flag("elastic"),
        chargeScale: chargeScale, pad: room)
    if room.low != .zero || room.high != .zero {
        print("Domain \(scenario.domainSize.x) x \(scenario.domainSize.y) x \(scenario.domainSize.z) m")
    }
    if let residual = option("crack-residual").flatMap({ Float($0) }) {
        scenario.structure?.material.crackResidual = residual
        print("Residual crack opening \(format(Double(residual) * 100, 0))%")
    }
    if flag("no-second-crack") { scenario.structure?.secondCracks = false }
    if let dowel = option("dowel").flatMap({ Float($0) }) { scenario.structure?.material.dowelFactor = dowel }
    if var structure = scenario.structure {
        applyRateOptions(&structure)
        // `--bond pullout`: bars that slip, of the 16 mm bars' diameter.
        if let bond = chosenBondSlip(diameter: 0.016) { structure.bondSlip = bond }
        scenario.structure = structure
    }
    let result = try ChamberTest.run(
        device: device, scenario: scenario, cellSize: cellSize, duration: duration,
        afterburning: burning,
        afterburnEnergy: option("afterburn-energy").flatMap { Float($0) }.map { $0 * 1e6 },
        airModel: chosenGas(), openFaces: chosenFaces(),
        refinement: option("refine").flatMap { Int($0) } ?? 1,
        contact: flag("no-contact") ? .off : nil,
        // Each charge from its own mapped one-dimensional start; `--balloon-start` for the balloon.
        mappedCharge: !flag("balloon-start"),
        // The gas losing what it radiates; `--no-radiate` keeps it, as before 19 October 2026.
        radiativeCooling: flag("no-radiate") ? nil : RadiativeCooling(),
        // `--progress` reports every 10 ms of a long run.
        progress: flag("progress")
            ? { line in
                print(line)
                fflush(stdout)
            } : nil, prepare: prepareTrace)
    print(
        "\nPeak reflected overpressure (MPa); the six sensors measured \(ChamberTest.measuredPeaks.map { format(Double($0.pressure) / 1e6, 2) }.joined(separator: ", "))"
    )
    for (name, pressure) in result.gaugePeaks {
        print("  \(pad(format(Double(pressure) / 1e6, 2), 6))  \(name)")
    }
    print(
        "\nRoof free edge at mid-span: peak \(format(Double(result.peakDeflection) * 1000, 0)) mm, "
            + "\(format(Double(result.residual) * 1000, 0)) mm at the end (measured residual \(format(Double(ChamberTest.measuredResidual) * 1000, 0)) mm)"
    )
    print(
        "Structure: \(result.summary.erodedElements) of \(result.summary.activeElements + result.summary.erodedElements) elements failed; "
            + "run took \(format(result.wallSeconds, 1)) s")
    for (part, failed, total) in result.failures {
        print("  \(pad("\(failed)", 6)) of \(pad("\(total)", 6))  \(part)")
    }
    for probe in result.probes {
        print("\(probe.name): peak \(format(Double(probe.history.map(\.y).max() ?? 0) * 1000, 0)) mm outward")
    }
    if flag("history") {
        print("    time      roof edge" + result.probes.map { pad($0.name, 24) }.joined())
        for (n, sample) in result.edgeHistory.enumerated() where Int((sample.x * 1000).rounded()) % 5 == 0 {
            print(
                "    \(pad(format(Double(sample.x) * 1000, 1), 6)) ms \(pad(format(Double(sample.y) * 1000, 1), 9))"
                    + result.probes.map { pad(format(Double($0.history[n].y) * 1000, 1), 24) }.joined())
        }
    }
}
