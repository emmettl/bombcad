import BlastCore
import Foundation
import Metal

// Nassr's steel beams and columns in the open (see NassrSteelTest.swift):
//
//   blastbench nassr [--shots 1,2,3,4,5] [--members beam,column] [--rate 1.0] [--elements 24]

func runNassr(device: MTLDevice) throws {
    let wanted = (option("shots") ?? "1,2,3,4,5").split(separator: ",").compactMap { Int($0) }
    let members = (option("members") ?? "beam,column").split(separator: ",").map(String.init)
    let rate = option("rate").flatMap { Float($0) } ?? 1
    for shot in NassrSteelTest.shots where wanted.contains(shot.number) {
        for member in members {
            let r = try NassrSteelTest.run(
                device: device, shot: shot, column: member == "column", rateFactor: rate,
                elements: option("elements").flatMap { Int($0) } ?? 24)
            print(
                String(
                    format: "shot %d %@ %@ %@: peak %.1f mm, end %.1f mm, measured %@", shot.number,
                    shot.section,
                    shot.axis.rawValue, member, r.peak * 1000, r.final * 1000,
                    r.measured.map { String(format: "%.1f mm (%.2f)", $0 * 1000, r.peak / $0) } ?? "-"))
        }
    }
}
