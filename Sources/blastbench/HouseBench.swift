import BlastCore
import Foundation
import Metal
import simd

/// `blastbench house [--mass 25] [--standoff 10] [--height 0.8] [--dx 0.5] [--duration 0.1]
/// [--every 0.01] [--covering plainClayTiles|concreteInterlockingTiles|welshSlate|none]
/// [--erosion 0.003] [--clearance m] [--settle-only]`: the row of 1930s terraced houses under a charge in front of the middle one.
/// Settles the row, reports its ties and joist seats at rest, then runs the blast and reports
/// them again with the structure's damage.
func runHouse(device: MTLDevice) throws {
    let mass = option("mass").flatMap(Float.init) ?? 25
    let standoff = option("standoff").flatMap(Float.init) ?? 10
    let height = option("height").flatMap(Float.init) ?? 0.8
    let cell = option("dx").flatMap(Float.init) ?? 0.5
    let duration = option("duration").flatMap(Double.init) ?? 0.1
    let coveringName = option("covering") ?? "plainClayTiles"
    let covering = ScenarioPreset.RoofCovering(rawValue: coveringName)
    let preset = ScenarioPreset.terracedRow(
        title: "Terraced row", charge: mass, standoff: standoff, height: height, covering: covering,
        faceClearance: option("clearance").flatMap(Float.init))
    var scenario = preset
    if let opening = option("erosion").flatMap(Float.init) {
        // The brick's removal width, for checking what removal does to the walls.
        scenario.structure?.material.erosionOpening = opening
    }
    let solver = try BlastSolver(
        device: device, scenario: scenario, cellSize: cell, configuration: .recommended)
    guard let model = scenario.structure else { return }
    var rest: [SIMD3<Float>] = []
    func report(_ label: String) {
        guard let shells = solver.bodies.first?.shells else { return }
        let summary = shells.summary()
        let total = summary.activeElements + summary.erodedElements
        let damage = String(format: "%.2f", summary.maxDamage)
        let moved = String(format: "%.0f", summary.maxDisplacement * 1000)
        print(
            "\(label): \(summary.erodedElements) of \(total) elements removed, damage up to \(damage), "
                + "largest displacement \(moved) mm")
        var ties = PartPairs.Summary()
        var seats = PartPairs.Summary()
        var roofing = PartPairs.Summary()
        for index in model.supports.indices {
            guard let law = model.anchorage(ofSupport: index), let part = shells.pairSummary(support: index)
            else { continue }
            if law.closingGap != nil {
                ties = ties.combined(with: part)
            } else if law.cohesion > 0 {
                seats = seats.combined(with: part)
            } else {
                roofing = roofing.combined(with: part)
            }
        }
        let row = TerracedRowDamage(shells: shells, rest: rest)
        for (h, house) in row.houses.enumerated() {
            let seats = house.seatsLost.map { String(format: "%.0f%%", $0 * 100) }.joined(separator: "/")
            let fallen = house.fallen.map { String(format: "%.2f", $0) }.joined(separator: "/")
            print(
                "  house \(h + 1): \(house.category.rawValue); walls destroyed "
                    + "\(String(format: "%.1f%%", house.destroyed * 100)) (front "
                    + "\(String(format: "%.0f%%", house.frontDestroyed * 100))), cracked "
                    + "\(String(format: "%.1f%%", house.cracked * 100)); joists off seats (floor/roof) \(seats), "
                    + "fallen \(fallen) m; covering moved \(String(format: "%.0f%%", house.coveringMoved * 100))"
            )
        }
        for (name, part) in [("ties", ties), ("joist seats", seats), ("roof covering", roofing)] {
            let opening = String(format: "%.1f", part.maxOpening * 1000)
            let slip = String(format: "%.1f", part.maxSlip * 1000)
            let force = String(
                format: "%.1f %.1f %.1f", part.force.x / 1e3, part.force.y / 1e3, part.force.z / 1e3)
            print(
                "  \(name): \(part.pairs) pairs, \(part.separated) lost, \(part.unseated) off their seat; "
                    + "largest opening \(opening) mm, slip \(slip) mm; force (kN) \(force)")
        }
    }
    let size = scenario.domainSize
    print(
        "\(mass) kg TNT \(standoff) m in front of the middle house, \(height) m up; air \(cell) m; domain "
            + "\(Int(size.x)) x \(Int(size.y)) x \(Int(size.z)) m"
            + (scenario.tightFacesNote.map { "; " + $0 } ?? ""))
    solver.settleStructures()
    for settlement in solver.settlements {
        print(
            "\(settlement.settled ? "Settled" : "Did not settle") in \(String(format: "%.2f", settlement.time)) s"
        )
    }
    solver.bodies.first?.shells?.mutateNodes { nodes in rest = nodes.map(\.displacement) }
    report("At rest")
    if flag("supports"), let shells = solver.bodies.first?.shells {
        for index in model.supports.indices {
            guard let part = shells.pairSummary(support: index) else { continue }
            print(
                "  support \(index): \(part.pairs) pairs, force z \(String(format: "%.2f", part.force.z / 1e3)) kN"
            )
        }
    }
    if flag("settle-only") { return }
    let every = option("every").flatMap(Double.init) ?? duration
    var time = 0.0
    while time < duration - 1e-9 {
        time = min(time + every, duration)
        let result = solver.advance(until: time)
        report("After \(String(format: "%.1f", time * 1000)) ms\(result.isStable ? "" : " (unstable)")")
    }
}
