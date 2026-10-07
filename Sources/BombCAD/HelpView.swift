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
    case importing = "Importing models"

    var id: Self { self }
    var icon: String {
        switch self {
        case .gettingStarted: "play.circle"
        case .projects: "doc.text"
        case .importing: "cube.box"
        }
    }

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
                    "Restore inputs and sweep parameters",
                    "Use this run’s inputs in Compare to restore its geometry and numerical settings at time zero without losing saved results. Undo restores the previous inputs, including grid and duration. Sweep… beside the chart runs up to eight primary-charge masses or grid resolutions sequentially and keeps successful results under a unique name prefix. Reset first if needed. Original editor inputs and playback speed return after completion, cancellation or failure; finished results remain. Cancel sweep or Command-R stops the queue. Closing the sweep dialog leaves it running. Autosave keeps the original editor inputs and completed results, rather than temporary case inputs."
                ),
                (
                    "About the model",
                    "BombCAD is an experimental study of simulation numerics and performance, not a design tool. Results depend on grid resolution, material assumptions and supports. Peak pressures can be under-resolved, and collapse and debris have not been validated against tests."
                ),
            ]
        case .importing:
            [
                (
                    "Open your model",
                    "Choose Import Model… in the toolbar or drop one local OBJ, STL or IFC file into the viewport. Export closed, watertight volumes from your CAD tool. Triangles or convex planar polygons are supported; textures and OBJ visual materials are ignored. Checking runs in the background and can be cancelled. For OBJ/STL material editing, start with Open ground and enable Deformable solid; the layout must not already contain another deformable structure. Leaving it off creates rigid obstacles."
                ),
                (
                    "Import an IFC building",
                    "IFC files are converted locally to metres, Z up, and imported as rigid obstacles. The app includes its converter; no file is uploaded. Choose physical walls, slabs/roofs, columns, beams, members, plates, footings, stairs, railings, doors and windows before conversion. Building, storey, type and text filters change the list; checkboxes and Include/Exclude matching change inclusion. Choices are retained with the source. Choose IFC elements… revisits them from the preview or source inspector. Each subset is rebased to its own bounds, so review placement again. Spaces, furnishings, site/proxy markers and other types are excluded. The Parts browser preserves element names, types, available storey labels and GlobalIds, and searches all of them. IFC completeness and the exported report distinguish exclusions, unsupported types, selected elements without geometry, grid losses and cells covered by other elements. Inventory follows the decomposition tree; uncontained products may be absent. Check omissions against your CAD model and compare Source against Simulation. Touching elements stay distinct in the source, while overlapping sampled cells count once. Material properties, supports and structural connections are not inferred."
                ),
                (
                    "Confirm scale and placement",
                    "Under Units & placement, choose the source units and enable Y is the source up axis when appropriate. Check the dimensions in metres and the reference grid before proceeding. Unit suggestions require your choice. Centre moves the footprint without changing its height; On ground changes only its height. Expand domain to fit stages a larger domain and checks its memory cost. The preview shows surrounding geometry and flags overlaps, blocked charge locations and disconnected or floating components."
                ),
                (
                    "Review feature-size warnings",
                    "Compare Source, Simulation and Warnings to see what the grid preserves. Thin walls may disappear or change thickness, and narrow gaps may close. Select a warning to focus its region. Compare grids shows occupied cells, sampled volume, recovered parts and estimated air memory without applying changes. Preview finer grid advances the chosen grid. A recovered part or stable volume does not prove adequate resolution: features below two cells across still need attention, even on Fine. Highlighted regions are approximate and can miss features; simplify or enlarge unresolved geometry when a suitable grid is unavailable."
                ),
                (
                    "Assign physical materials",
                    "The Parts browser names complete OBJ shells; STL components receive generic names. Select several parts to assign or reset a material together, or copy and paste a material. Parts without an override use the model default. Advanced exposes material properties. Isolate selected parts changes only the preview; all parts still import. A shell with no sampled cells may be a cavity boundary or a lost feature. Cavity walls use the enclosing solid’s material. Rigid obstacles ignore structural materials. Fix nodes at the model’s base restrains the lowest plane; review disconnected components separately."
                ),
                (
                    "Repair rejected geometry",
                    "For OBJ/STL, open edges, non-manifold surfaces, self-intersections, overlapping solids and ambiguous contacts open the defect inspector and remain blocked from the simulation. Focus the highlighted defect or export a repair report with source triangle numbers. Close holes and Boolean-union overlapping volumes in your CAD tool, export again, then use Choose repaired file. IFC element failures identify the element name and GlobalId in the chooser. Repair the source, or explicitly Exclude invalid element and retry; no failed solid is silently skipped. If the converter cannot determine units, import remains blocked until you re-export correct project/context and unit definitions. BombCAD does not fill holes or join solids automatically. Nested shells represent cavities and further nested shells represent solid islands. If checking exceeds a model-size or work limit, simplify the source before retrying."
                ),
                (
                    "Apply, save and edit again",
                    "Review the geometry and placement warnings, then Apply. Save Project keeps source geometry, transforms, part materials and warnings; IFC projects also retain original IFC bytes and element metadata in the .bombcad project, so reopening does not need the original OBJ/STL file. Turn off Place Charge and reset after a run to select an imported model in the viewport, or choose Inspect / edit source… in Edit layout. Attached sources regenerate when the grid changes. Geometry, reinforcement and custom-support edits detach the structure to preserve your edits; Undo restores its source link. Import profiles reuse units, behavior, base restraint and materials matched by part name; placement and grid remain specific to the current import."
                ),
                (
                    "Try the repository examples",
                    "The repository’s Samples/Importer folder includes a cube, named parts with a thin panel, disconnected STL blocks, a narrow gap, an enclosed cavity, a millimetre/Y-up column, and broken/repaired pairs. Its Buildings subfolder contains a real IFC house and matching mesh reference, a two-storey duplex, structural beams, an imperial column and a unit-detection failure case. Its README lists settings and expected results. Start with unit-cube.obj, then named-parts.obj and Compare grids to see why feature-size warnings matter. These files are available in the repository and are not bundled with the app."
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
