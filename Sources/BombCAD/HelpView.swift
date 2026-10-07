import SwiftUI

struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("BombCAD Help") { openWindow(id: "help") }
                .keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }
}

/// Small, offline help articles. Add topics here as the editor grows.
private enum HelpTopic: String, CaseIterable, Identifiable {
    case gettingStarted = "Getting started"
    case projects = "Editing and saving projects"

    var id: Self { self }
    var icon: String { self == .gettingStarted ? "play.circle" : "doc.text" }

    var sections: [(title: String, text: String)] {
        switch self {
        case .gettingStarted:
            [
                (
                    "Your first run",
                    "In the Run tab, choose a built-in Layout. Open ground is a simple place to start. Choose a Grid, then set the charge’s TNT equivalent and position. Press Run or Space to start; press again to pause. Reset (⌘R) returns to the moment before detonation."
                ),
                (
                    "Move around the scene",
                    "Drag or use two-finger scrolling to orbit. Shift-drag or right-drag pans the view. Pinch or use the mouse wheel to zoom. Choose Simulation → Reset Camera (⌘0) to return to the scene’s starting view."
                ),
                (
                    "Place the charge",
                    "Turn on Place Charge in the toolbar, then click the ground to move the charge. Set Height in the Run tab to move it above the ground. A charge inside a block or wall releases no energy; move it clear if the sidebar shows that warning."
                ),
                (
                    "Read the results",
                    "The Display section chooses the field painted on surfaces. Use the legend for its units and colour scale. Pressure gauges record histories in the chart below the scene. Deformable layouts also show damage and deflection in the Structure section. Export gauge and deflection histories as CSV from beside the chart."
                ),
                (
                    "Balance detail and speed",
                    "Start with a coarse grid to explore a layout. Finer grids use more GPU memory and take longer. Sharpen shocks refines the air near the shock; Afterburning and hot air adds charge physics at extra cost. Playback Speed controls playback, and Stop after sets the run duration."
                ),
                (
                    "Compare simulation runs",
                    "Complete a stable run, then choose Keep Run… beside the chart and give it a unique name. Compare opens retained runs with pressure or deflection overlays and peak differences from a reference run. Matching gauges must have the same name and position. Saved runs keep their inputs and full pressure samples across resets, edits and reopening. Structural deflection is recorded every 1 ms of simulation time; its recorded peak can miss faster motion. Rename by pressing Return in a run’s name field, export its CSV, or remove it and use Undo last removal. Keeping results adds them to the project; ordinary simulation progress does not."
                ),
                (
                    "About the model",
                    "BombCAD is an experimental study of simulation numerics and performance, not a design tool. Results depend on grid resolution, material assumptions and supports. Peak pressures can be under-resolved, and collapse and debris have not been validated against tests."
                ),
            ]
        case .projects:
            [
                (
                    "Edit a layout",
                    "Open the Edit layout tab to add, select, move, resize or remove rigid blocks, deformable walls, openings and pressure gauges. Select an item to reveal its fields. Coordinates and sizes are in metres, with Z pointing up. Walls have material and reinforcement settings."
                ),
                (
                    "Undo edits",
                    "Use Undo Edit (⌘Z) and Redo Edit (⇧⌘Z) to step through layout edits. Opening another project starts a fresh run and clears its layout undo history."
                ),
                (
                    "Save a project",
                    "Use Save Project in the toolbar or File → Save (⌘S). A .bombcad project contains the layout, simulation settings and camera/display preferences. Named projects also autosave. Use Save As… in the toolbar’s extra-actions menu to save a separate copy."
                ),
                (
                    "Edit imported structures",
                    "In Edit layout, choose a named part under Deformable structure. Part material choices stay linked to the source and survive grid changes. Frame selected part brings it into view. Reinforcement applies to its sampled regions. Cut opening and Add base support place editable regions at the selected part. Geometry, reinforcement and custom support edits detach the structure in the same undo step; undo restores its source link. Detached edits and part ownership are saved in the project."
                ),
                (
                    "Structural supports",
                    "Fix nodes on the ground controls the ground restraint. Support regions hold every structural node inside them still. Select a support to edit its corner and size or remove it. A source-managed import can change its base restraint without detaching; custom support regions detach it. Supports describe restraints, not geometric connections between disconnected parts."
                ),
                (
                    "Open a project",
                    "Use Open Project to open a .bombcad project in its own window. Use Import Layout JSON… in the toolbar’s extra-actions menu for JSON layouts. A saved project restores its inputs and view for a fresh simulation. It does not resume the elapsed simulation or restore GPU state, chart histories or the undo stack."
                ),
                (
                    "Share a layout or results",
                    "Export Layout JSON writes only the scene for interchange; it leaves out run and view preferences. Import Layout JSON… in the toolbar’s extra-actions menu opens a layout as a new project. Use the CSV export beside the chart to keep results separately from the project."
                ),
                (
                    "If something goes wrong",
                    "If a run cannot start, check the message in the viewport and any warning in the sidebar. For GPU memory issues, try a coarser grid or a simpler layout. If opening a file fails, keep the original and check that it is a BombCAD project or a supported layout JSON file."
                ),
            ]
        }
    }
}

struct HelpView: View {
    @State private var selection: HelpTopic? = .gettingStarted

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: $selection) { topic in
                Label(topic.rawValue, systemImage: topic.icon)
                    .tag(topic)
            }
            .navigationTitle("Help topics")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            let topic = selection ?? .gettingStarted
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(topic.rawValue)
                        .font(.largeTitle.weight(.semibold))
                    ForEach(topic.sections.indices, id: \.self) { index in
                        let section = topic.sections[index]
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title).font(.title3.weight(.semibold))
                            Text(section.text).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
            .navigationTitle(topic.rawValue)
        }
        .frame(minWidth: 680, minHeight: 480)
    }
}
