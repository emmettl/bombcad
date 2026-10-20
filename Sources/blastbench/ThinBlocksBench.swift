import BlastCore
import Foundation
import Metal
import simd

// `blastbench thin-blocks`.
// Split from main.swift (emmettl/bombcad-work#51).

/// `blastbench thin-blocks [scene.json ...] [--dx 0.5,0.25,0.125]`: the rigid blocks (scenery and
/// envelope fragments) of every layout, or of the scenes given, too thin to hold a cell's centre
/// along some axis on each grid, which the mask once left out and now widens to a layer of cells
/// (`Box.holdingCells`).
func runThinBlocks() throws {
    let sizes = option("dx")?.split(separator: ",").compactMap { Float($0) } ?? [0.5, 0.25, 0.125]
    let paths = CommandLine.arguments.dropFirst(2).filter {
        !$0.hasPrefix("--") && !sizes.map { "\($0)" }.contains($0)
    }
    var scenes: [(String, Scenario)] = ScenarioPreset.allCases.map { ($0.title, $0.scenario) }
    // The street study's layouts with their buildings as envelopes: the envelope damage references.
    for layout in StreetInteractionStudy.Layout.allCases {
        guard var scene = try? StreetInteractionStudy.make(layout, clamped: true) else { continue }
        for object in scene.structuralObjects { try? scene.useEnvelope(id: object.id) }
        scenes.append(("Street study, \(layout.rawValue), as envelopes", scene))
    }
    if !paths.isEmpty {
        scenes = try paths.map { path in
            (
                path,
                try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            )
        }
    }
    print(
        "Blocks too thin to hold a cell's centre, of all rigid blocks; on "
            + sizes.map { "\($0) m" }.joined(separator: ", "))
    for (name, scenario) in scenes {
        let boxes = scenario.rigidBoxes
        let counts = sizes.map { size in boxes.filter { $0.holdingCells(of: size) != $0 }.count }
        guard counts.contains(where: { $0 > 0 }) else { continue }
        let envelope = scenario.envelopeObjects.count
        if flag("list") {
            for box in boxes where box.holdingCells(of: sizes[0]) != box {
                print("    \(box.min) – \(box.max), size \(box.size)")
            }
        }
        print(
            "  \(name): " + counts.map { "\($0)" }.joined(separator: " / ") + " of \(boxes.count)"
                + (envelope > 0 ? " (\(envelope) envelope buildings)" : ""))
    }
}
