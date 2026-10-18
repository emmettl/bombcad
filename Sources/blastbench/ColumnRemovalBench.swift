import BlastCore
import Foundation
import Metal

// NIST's steel moment-frame assemblies under a column's removal, and a gravity frame's shear tabs
// (Weigand and Berman's; see ColumnRemovalTest.swift):
//
//   blastbench removal [--specimens WUF-B,RBS,SPS] [--joints rigid,hinged] [--speed 0.1] [--dx 0.15]
//                      [--drop m] [--curve]

func runColumnRemoval(device: MTLDevice) throws {
    let specimens = (option("specimens") ?? "WUF-B,RBS,SPS").split(separator: ",").compactMap {
        ColumnRemovalTest.Specimen(rawValue: String($0))
    }
    let joints = (option("joints") ?? "rigid,hinged").split(separator: ",").map(String.init)
    for specimen in specimens {
        for joint in joints {
            let r = try ColumnRemovalTest.run(
                device: device, specimen: specimen, connection: joint == "rigid" ? nil : specimen.connection,
                speed: option("speed").flatMap { Float($0) } ?? 0.1,
                drop: option("drop").flatMap { Float($0) } ?? (specimen == .singlePlateShear ? 1.4 : 1.1),
                elementSize: option("dx").flatMap { Float($0) } ?? 0.15)
            let measured = ColumnRemovalTest.measured(specimen)
            print(
                String(
                    format:
                        "%@ %@: peak %.0f kN at %.0f mm, failed at %@; measured %.0f kN at %.0f mm; %d hinges let go",
                    specimen.rawValue, joint, r.peakLoad / 1000, r.dropAtPeak * 1000,
                    r.failedAt.map { String(format: "%.0f mm", $0 * 1000) } ?? "-", measured.load / 1000,
                    measured.drop * 1000, r.hingesReleased))
            if flag("curve") {
                for point in r.curve where Int(point.x * 1000) % 50 == 0 {
                    print(String(format: "  %.0f mm  %.0f kN", point.x * 1000, point.y / 1000))
                }
            }
        }
    }
}
