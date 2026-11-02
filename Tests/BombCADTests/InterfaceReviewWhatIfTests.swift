import AppKit
import BlastCore
import SwiftUI
import Testing

@testable import BombCAD

/// The quick estimate's what-ifs (emmettl/bombcad-work#113), captured offscreen for a look by eye:
/// the What if controls as built and with every building's glass laminated and walls of masonry, in
/// light and dark. Only with `BOMBCAD_INTERFACE_REVIEW` (the folder to write).
@MainActor
@Suite(
    "The quick estimate's what-ifs, offscreen", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"] != nil))
struct InterfaceReviewWhatIfTests {
    @Test("Capture the What if controls as built and with a what-if set")
    func whatIfControls() throws {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: "what-if")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = SimulationModel(document: ProjectDocument(scenario: ScenarioPreset.blastWall.scenario))
        for (name, whatIf) in [
            ("as-built", LiveResponse.WhatIf()),
            (
                "laminated-masonry",
                LiveResponse.WhatIf(glass: .laminated(.facade), walls: .unreinforcedMasonry)
            ),
        ] {
            model.quickEstimateWhatIf = whatIf
            for (style, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try InterfaceSnapshotTests().snapshot(
                    Form { WhatIfControls(model: model, isExpanded: true) }.formStyle(.grouped).frame(
                        width: 310),
                    size: CGSize(width: 310, height: 280), appearance: appearance,
                    to: folder.appending(path: "\(name)-\(style).png"))
            }
        }
    }
}
