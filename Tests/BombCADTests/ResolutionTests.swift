import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

/// The air's cell size: presets saved by name as before, other sizes as "cell:" and metres.
@Suite("Resolution")
struct ResolutionTests {
    @Test("Presets keep their names; other sizes round-trip, and older names still read")
    func rawValues() throws {
        #expect(Resolution.allCases.map(\.rawValue) == ["coarse", "medium", "fine"])
        #expect(Resolution(rawValue: "medium") == .medium && Resolution(cellSize: 0.25) == .medium)
        let sixteen = try #require(Resolution(cellSize: 16))
        #expect(sixteen.rawValue == "cell:16" && Resolution(rawValue: "cell:16") == sixteen)
        #expect(Resolution(rawValue: "cell:7.9")?.cellSize == 7.9)
        #expect(!sixteen.isPreset && sixteen.title == "Cells of 16 m")
        for bad in ["huge", "cell:", "cell:0", "cell:-4", "cell:1e9", "cell:nan"] {
            #expect(Resolution(rawValue: bad) == nil, "\(bad)")
        }
        #expect(
            Resolution(text: "4") == Resolution(cellSize: 4)
                && Resolution(text: "4 m") == Resolution(cellSize: 4))
        #expect(Resolution(text: "fine") == .fine && Resolution(text: "metres") == nil)
        #expect(
            Resolution.coarse.finer == .medium && Resolution.fine.finer == nil && sixteen.finer?.cellSize == 8
        )
    }

    @Test("Scaled choices appear for large charges only, to two significant figures")
    func scaledChoices() {
        // 500 t: cube root 79.37; 0.2, 0.1 and 0.05 m/kg^(1/3) are 15.9, 7.9 and 4.0 m.
        let choices = Resolution.choices(mass: 500_000, current: .medium)
        #expect(choices.map(\.cellSize) == [16, 7.9, 4, 0.5, 0.25, 0.125])
        #expect(Resolution.choices(mass: 100, current: .medium) == Resolution.allCases)
        let custom = Resolution(cellSize: 3)!
        #expect(Resolution.choices(mass: 100, current: custom).first == custom)
        #expect(Resolution(cellSize: 16)!.title(mass: 500_000) == "Cells of 16 m · 0.2 m/kg^(1/3)")
    }

    @Test("A project with other cells saves them by size; one that names no grid is refused")
    func projectSettings() throws {
        var settings = SimulationSettings()
        settings.resolution = Resolution(cellSize: 8)!
        let saved = ProjectRunSettings(settings: settings, duration: 1)
        #expect(saved.resolution == "cell:8" && saved.gridName == "8 m")
        try saved.validate()
        var broken = saved
        broken.resolution = "enormous"
        #expect(throws: ProjectFileError.self) { try broken.validate() }
        #expect(ProjectRunSettings(settings: SimulationSettings(), duration: 1).gridName == "medium")
    }

    @Test("The charge's slider runs to 10 kt in two significant figures")
    func charges() {
        #expect(
            SimulationSettings.roundedMass(37.4) == 37
                && SimulationSettings.roundedMass(4_183_000) == 4_200_000)
        #expect(
            SimulationSettings.massText(250) == "250 kg" && SimulationSettings.massText(500_000) == "500 t")
        #expect(SimulationSettings.massText(4_000_000) == "4 kt")
    }
}
