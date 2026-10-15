import BlastCore
import Foundation
import Metal

/// `blastbench keys`: Keys's brick walls under 41 kg of TNT (Southampton thesis, 2016;
/// `Fixtures/Keys2016`): where their debris landed, in 0.5 m bins along the radial, against the
/// model's.
///
///   --trials WR1A,WR1B,WR2C             which walls (these three by default; WR1C too)
///   --dx 0.1 --h 0.0375                 air cells and elements
///   --time 3                            the longest run, if the debris has not come to rest
///   --sleep 0.0005                      freeze the air below this overpressure (of ambient)
///   --clearance 8 --height 10           air beyond the charge, the wall and either side; its height
///   --ground-friction 0.6               the ground's Coulomb coefficient (0: the old decay at 8/s)
///   --base mortar|joint|clamped         the wall on a mortar bed as its joints (default), on a
///                                       concrete construction joint, or clamped
///   --tunnel BWL2C [--downstream 14]    an Air Blast Tunnel wall, the measured wave driven in at
///                                       the inlet, this much tunnel behind the wall
///   --alone 1.5 [--resting]             the wall alone, no air, its top set swinging downstream
///                                       at this speed (on a mortar bed, or resting on the ground)
func runKeys(device: MTLDevice) throws {
    let groundFriction = option("ground-friction").flatMap { Float($0) } ?? 0.6
    if let names = option("tunnel")?.split(separator: ",").map(String.init) {
        // The Air Blast Tunnel's walls: --tunnel BWL2C [--downstream 14] [--dx 0.1] [--h 0.0375] [--time 2]
        for trial in MasonryDebrisTests.tunnelTrials where names.contains(trial.id) {
            print("\(trial.id), \(trial.overpressure / 1000) kPa for \(trial.duration * 1000) ms")
            let result = try MasonryDebrisTests.runTunnel(
                device: device, trial: trial, cellSize: option("dx").flatMap { Float($0) } ?? 0.1,
                elementSize: option("h").flatMap { Float($0) } ?? 0.0375,
                duration: option("time").flatMap { Double($0) } ?? 2,
                downstream: option("downstream").flatMap { Float($0) } ?? 14, groundFriction: groundFriction,
                progress: { print("  \($0)") })
            print(
                String(
                    format:
                        "  incident: %5.1f kPa, %5.0f kPa ms (measured %5.1f, %5.0f to the end of the positive phase); face %5.1f kPa",
                    result.incidentPeak / 1000, result.incidentImpulse, trial.overpressure / 1000,
                    trial.impulse,
                    result.facePeak / 1000))
            print(
                "  bed joints open at 50 ms: \(result.crackHeights.map { String(format: "%.2f", $0) }) m (measured \(trial.crackHeights))"
            )
            print("  measured: \(result.measuredSpread)")
            print("  model:    \(result.spread)")
            print(
                String(
                    format: "  settled at %.2f s; %d of %d elements eroded; %.0f s", result.settled,
                    result.summary.erodedElements,
                    result.summary.erodedElements + result.summary.activeElements,
                    result.wallSeconds))
            print("  bin from   measured  model (kg)")
            for (index, mass) in result.masses.enumerated() {
                let measured = trial.masses.indices.contains(index) ? trial.masses[index] : 0
                guard mass > 0.05 || measured > 0 else { continue }
                print(String(format: "  %5.1f m   %7.1f  %7.1f", Float(index) * trial.bin, measured, mass))
            }
        }
        return
    }
    if let speed = option("slide").flatMap({ Float($0) }) {
        try MasonryDebrisTests.runSlide(
            device: device, speed: speed, duration: option("time").flatMap { Double($0) } ?? 1,
            groundFriction: groundFriction, progress: { print($0) })
        return
    }
    if let push = option("alone").flatMap({ Float($0) }) {
        // The wall alone, swinging: --alone 1.5 [--resting]
        try MasonryDebrisTests.runAlone(
            device: device, push: push, duration: option("time").flatMap { Double($0) } ?? 1,
            anchored: !flag("resting"), free: flag("free"), contact: !flag("no-contact"),
            joints: !flag("smeared"), hourglass: option("hourglass").flatMap { Float($0) },
            groundFriction: groundFriction, progress: { print($0) })
        return
    }
    let wanted = option("trials")?.split(separator: ",").map(String.init) ?? ["WR1A", "WR1B", "WR2C"]
    let dx = option("dx").flatMap { Float($0) } ?? 0.1
    let h = option("h").flatMap { Float($0) } ?? 0.0375
    let time = option("time").flatMap { Double($0) } ?? 3
    let sleep = option("sleep").flatMap { Float($0) } ?? 5e-4
    let clearance = option("clearance").flatMap { Float($0) } ?? 8
    let height = option("height").flatMap { Float($0) } ?? 10
    let base: Anchorage? =
        switch option("base") ?? "mortar" {
        case "clamped": nil
        case "joint": .constructionJoint
        default: MasonryDebrisTests.mortarBed
        }
    for trial in MasonryDebrisTests.trials where wanted.contains(trial.id) {
        print("\(trial.id), \(trial.standoff) m\(trial.note.isEmpty ? "" : " (\(trial.note))")")
        let result = try MasonryDebrisTests.run(
            device: device, trial: trial, cellSize: dx, elementSize: h, duration: time,
            airSleepThreshold: sleep,
            clearance: clearance, height: height, groundFriction: groundFriction, base: base,
            afterburning: burning, progress: { print("  \($0)") })
        print(
            String(
                format: "  free field: %5.1f kPa, %5.0f kPa ms (measured %5.1f, %5.0f)",
                result.gaugePeak / 1000,
                result.gaugeImpulse, trial.measuredPeak / 1000, trial.measuredImpulse))
        print("  measured: \(result.measuredSpread)")
        print("  model:    \(result.spread)")
        print(
            String(
                format: "  settled at %.2f s; %d of %d elements eroded; %.0f s", result.settled,
                result.summary.erodedElements, result.summary.erodedElements + result.summary.activeElements,
                result.wallSeconds))
        print("  bin from   measured  model (kg)")
        for (index, mass) in result.masses.enumerated() {
            let from = result.firstBin + Float(index) * MasonryDebrisTests.binWidth
            let measuredIndex = Int(((from - trial.firstBin) / MasonryDebrisTests.binWidth).rounded())
            let measured = trial.masses.indices.contains(measuredIndex) ? trial.masses[measuredIndex] : 0
            guard mass > 0.05 || measured > 0 else { continue }
            print(String(format: "  %5.1f m   %7.1f  %7.1f", from, measured, mass))
        }
    }
}
