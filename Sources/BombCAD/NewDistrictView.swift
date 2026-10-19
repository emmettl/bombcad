import BlastCore
import SwiftUI
import UniformTypeIdentifiers
import simd

/// A district's air: uniform cells, or a base of cells refined once, to half their size, where the
/// shock is (at a jump of 0.005 of the pressure) and no higher above the ground than the
/// buildings and the shock's top over them (`DistrictLayout.refinementCeiling`), the footprints
/// on the finer cells. Over Beirut's 1 km box, 8 m refined so to 4 m kept the glass and the
/// arrivals of 4 m cells at 0.44 of their run time (docs/beirut-2020.md).
struct DistrictAir: Sendable, Equatable {
    /// The uniform cells, or the refined air's base.
    var cellSize: Float
    var refined: Bool

    static let threshold: Float = 0.005

    /// The cells at the façades as the shock loads them. A refined air takes the ground as a
    /// staircase of whole cells (`NewDistrictModel.settings`).
    var finest: Float { refined ? cellSize / 2 : cellSize }

    var title: String {
        refined
            ? "\(Resolution.metres(cellSize)) refined to \(Resolution.metres(finest)) at the shock, near the ground"
            : "uniform \(Resolution.metres(cellSize)) cells"
    }
}

/// A district laid out for File ▸ New District, and what a run of it costs.
struct DistrictPreview: Sendable {
    struct Priced: Sendable {
        var air: DistrictAir
        var cost: RunCostEstimate
    }

    var document: ProjectDocument
    var report: MapBuildingReport
    var cost: RunCostEstimate
    /// The memory the components' histories may take, bytes, beside the air's.
    var historyBudget: Int
    var air: DistrictAir
    /// The other kind of air that fits, priced on the same layout, to set against `air`.
    var alternative: Priced?
    /// Buildings within the radius; those placed in the air are in `report`, those beyond the
    /// hand-over in `far`.
    var within: Int
    /// With a near field and a far field, the buildings beyond the air, judged after the run.
    var far: FarFieldSet? { document.farField }

    var cellSize: Float { air.cellSize }
    var scenario: Scenario { document.scenario }
}

/// File ▸ New District: a district laid out from files the user supplies (an OpenStreetMap
/// export, optionally a building-height raster and a terrain), as `scenebench district-scene`
/// lays out Beirut's. The app fetches nothing.
@MainActor
@Observable
final class NewDistrictModel {
    enum YieldUnit: String, CaseIterable, Identifiable {
        case kilograms = "kg"
        case tonnes = "t"
        case kilotonnes = "kt"
        var id: Self { self }
        var kilograms: Double {
            switch self {
            case .kilograms: 1
            case .tonnes: 1_000
            case .kilotonnes: 1_000_000
            }
        }
    }

    /// The cell sizes offered, metres, finest first.
    nonisolated static let cellSizes: [Float] = [
        0.5, 1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10, 12, 16, 20, 25, 32, 40, 50,
    ]

    var map: (name: String, buildings: [MapBuilding])?
    var terrain: (name: String, grid: ElevationGrid)?
    var heights: (name: String, grid: ElevationGrid)?
    /// The terrain is a surface model (roofs and trees in it, as Copernicus GLO-30 is): its
    /// elevations are opened over 100 m to reach the ground, and those within a metre of the sea
    /// put at it, as for Beirut.
    var terrainIsSurface = true
    var longitude = ""
    var latitude = ""
    var yieldValue = 1.0
    var yieldUnit = YieldUnit.tonnes
    var ground = GroundType.rigid
    /// Buildings whose footprint's centre lies within this many metres of the charge are placed.
    var radius: Float = 500
    /// The side faces 4 m/kg^(1/3) beyond the outermost building.
    var clearFaces = true
    /// Clear the building whose footprint holds the charge, leaving open ground
    /// (`DistrictLayout.clearsChargeBuilding`): on, a charge put inside a building goes off.
    var clearsChargeBuilding = true
    /// The air's kind: the advisor's (`DistrictAir` refined where that is both cheaper and finer
    /// at the façades than the uniform cells that fit), or one the user chose.
    enum AirChoice: String, CaseIterable, Identifiable {
        case advised, uniform, refined
        var id: Self { self }
        var title: String {
            switch self {
            case .advised: "Advisor's choice"
            case .uniform: "Uniform cells"
            case .refined: "Refined at the shock"
            }
        }
    }

    var airChoice = AirChoice.advised
    /// Run the air only to a hand-over and judge the buildings beyond it after the run on the far
    /// field carried from it (`FarFieldSet`; docs/hybrid-far-field.md).
    var nearAndFar = true

    /// The hand-over the advisor takes for `mass` kg and buildings within `radius`: where the shock
    /// has become weak and nearly spherical, 12 m/kg^(1/3) (1 km at 0.5 kt, as Beirut was judged),
    /// to 50 m; nil where the district reaches no further than a quarter beyond it.
    nonisolated static func handover(mass: Float, radius: Float) -> Float? {
        let h = max((12 * cbrt(max(mass, 1)) / 50).rounded() * 50, 50)
        return radius >= 1.25 * h ? h : nil
    }

    /// The hand-over these inputs take, if any.
    var handover: Float? { nearAndFar ? Self.handover(mass: mass, radius: radius) : nil }
    /// The cells chosen (the refined air's base); nil for the finest that fits this Mac.
    var cellSize: Float?
    /// The GPU memory the run may take, bytes: this Mac's share for the air.
    var memory = AdvisorMachine.thisMac.memory

    private(set) var preview: DistrictPreview?
    private(set) var isWorking = false
    var message: String?

    var mass: Float { Float(yieldValue * yieldUnit.kilograms) }

    var charge: SIMD2<Double>? {
        guard let lon = Double(longitude), let lat = Double(latitude), abs(lat) < 85, abs(lon) <= 180 else {
            return nil
        }
        return SIMD2(lon, lat)
    }

    /// The map's buildings' extent, in longitude and latitude.
    var mapBounds: (low: SIMD2<Double>, high: SIMD2<Double>)? {
        let points = (map?.buildings ?? []).flatMap { $0.rings.first ?? [] }
        guard let first = points.first else { return nil }
        return points.reduce((first, first)) { (simd_min($0.0, $1), simd_max($0.1, $1)) }
    }

    func readMap(_ url: URL) throws {
        let buildings = try MapBuilding.read(contentsOf: url)
        guard !buildings.isEmpty else {
            throw MapBuilding.Failure.malformed("no buildings in \(url.lastPathComponent)")
        }
        map = (url.lastPathComponent, buildings)
        preview = nil
        // The charge at the map's centre until it is placed, and the radius to its nearer edge.
        if charge == nil, let bounds = mapBounds {
            let centre = (bounds.low + bounds.high) / 2
            longitude = String(format: "%.6f", centre.x)
            latitude = String(format: "%.6f", centre.y)
            let half = MapBuildingPlacement(origin: centre, resolution: 1).position(bounds.high)
            radius = max(50, (Float(min(half.x, half.y)) / 50).rounded(.down) * 50)
        }
    }

    func readTerrain(_ url: URL) throws {
        terrain = (url.lastPathComponent, try ElevationGrid(contentsOf: url))
        preview = nil
    }

    func readHeights(_ url: URL) throws {
        heights = (url.lastPathComponent, try ElevationGrid(contentsOf: url))
        preview = nil
    }

    /// The layout as the inputs stand; nil without a map or a charge.
    var layout: DistrictLayout? {
        guard let map, let charge, mass > 0 else { return nil }
        var layout = DistrictLayout(buildings: map.buildings, charge: charge, mass: mass)
        layout.heights = heights?.grid
        layout.clearsChargeBuilding = clearsChargeBuilding
        if let heights { layout.attributions.append("Building heights: \(heights.name)") }
        if let terrain {
            layout.ground =
                terrainIsSurface
                ? DistrictLayout.ground(terrain.grid, openingM: 100, seaM: 1)
                : terrain.grid
            layout.attributions.append("Elevations: \(terrain.name)")
        }
        return layout
    }

    /// Lays the district out and prices its run, away from the main thread.
    func lay() async {
        guard let layout else {
            message = "Choose a map and place the charge."
            return
        }
        isWorking = true
        message = nil
        let (radius, clear, choice, cell, ground, memory, handover) = (
            radius, clearFaces, airChoice, cellSize, ground, memory, handover
        )
        let result = await Task.detached(priority: .userInitiated) {
            Result {
                try Self.preview(
                    layout, radius: radius, clearFaces: clear, air: choice, cellSize: cell, ground: ground,
                    memory: memory, handover: handover)
            }
        }.value
        isWorking = false
        switch result {
        case .success(let preview): self.preview = preview
        case .failure(let error):
            preview = nil
            message = "Could not lay the district out: \(error)"
        }
    }

    /// The district as a project with its run settings, its air `air` (on cells `cellSize`, or the
    /// finest that fit `memory`), and what its run costs.
    nonisolated static func preview(
        _ layout: DistrictLayout, radius: Float, clearFaces: Bool, air choice: AirChoice = .advised,
        cellSize: Float? = nil, ground: GroundType, memory: Int, handover: Float? = nil
    ) throws -> DistrictPreview {
        let within = layout.buildings(within: radius).count
        guard within > 0 else {
            throw MapBuilding.Failure.malformed("no building lies within \(Int(radius)) m of the charge")
        }
        // With a hand-over the air reaches only it, and its faces' clearance beyond.
        let airRadius = handover ?? radius
        let duration = DistrictLayout.duration(radius: airRadius)
        let history = historyBudget(memory: memory)
        func fitting(refined: Bool) -> [DistrictAir] {
            let sizes = cellSize.map { [$0] } ?? cellSizes.filter { !refined || $0 >= 2 }
            return sizes.map { DistrictAir(cellSize: $0, refined: refined) }.filter {
                cellSize != nil
                    || fits(
                        layout, radius: airRadius, clearFaces: clearFaces, air: $0, ground: ground,
                        memory: memory)
            }
        }
        // Both kinds that fit, the other to set against the one chosen.
        let uniform = fitting(refined: false)
        let refined = fitting(refined: true)
        var candidates: [DistrictAir]
        switch choice {
        case .uniform: candidates = uniform
        case .refined: candidates = refined
        case .advised where cellSize != nil: candidates = uniform
        case .advised:
            candidates =
                prefersRefined(
                    layout, radius: airRadius, clearFaces: clearFaces, uniform: uniform.first,
                    refined: refined.first,
                    ground: ground, memory: memory) ? refined + uniform : uniform + refined
        }
        let tooLarge = MapBuilding.Failure.malformed(
            "no cells of \(Int(cellSizes.last!)) m or less fit this Mac for a district this large")
        guard !candidates.isEmpty else { throw tooLarge }
        // Finer cells hold more of the footprints' boxes, and the ground and roofs raise the top:
        // the finest whose buildings a scene holds and whose run, laid out, still fits. The
        // ground is on the air's own cells, a refined air's base; the footprints on its finest.
        while true {
            let air = candidates.removeFirst()
            do {
                let half = layout.halfSide(radius: airRadius, cellSize: air.cellSize, clearFaces: clearFaces)
                let name = String(format: "District at %.4f, %.4f", layout.charge.y, layout.charge.x)
                let made: (scene: Scenario, report: MapBuildingReport)
                var far: FarFieldSet?
                if let handover {
                    // The near box's buildings in the air, those beyond it beside the scene.
                    let split = try layout.hybrid(
                        handoverM: handover, nearHalfSide: half, radius: radius,
                        halfSide: radius + 2 * air.cellSize, cellSize: air.cellSize, name: name,
                        footprintCells: air.refined ? air.finest : nil)
                    made = (split.near, split.report)
                    far = split.far
                    far?.trendReach = FarFieldSet.trendReachDefault
                } else {
                    made = try layout.scene(
                        halfSide: half, cellSize: air.cellSize, radius: radius, name: name,
                        footprintCells: air.refined ? air.finest : nil)
                }
                var document = ProjectDocument(scenario: made.scene)
                document.farField = far
                // The scene's own run settings, before either kind of air changes them.
                let base = document.runSettings
                let run = settings(
                    base, air: air, ground: ground, duration: duration,
                    ceiling: layout.refinementCeiling(radius: radius, cellSize: air.cellSize))
                document.runSettings = run
                try ProjectDocument.validate(made.scene)
                try ProjectDocument.validateGrid(
                    made.scene, resolution: Resolution(cellSize: air.cellSize) ?? .coarse)
                let cost = estimate(run, made.scene, memory: memory)
                if cellSize == nil, cost.memory + history > memory {
                    if candidates.isEmpty { throw tooLarge }
                    continue
                }
                // The other kind, priced on this layout.
                let other = (air.refined ? uniform : refined).first.map { other in
                    DistrictPreview.Priced(
                        air: other,
                        cost: estimate(
                            settings(
                                base, air: other, ground: ground, duration: duration,
                                ceiling: layout.refinementCeiling(radius: radius, cellSize: other.cellSize)),
                            made.scene, memory: memory))
                }
                return DistrictPreview(
                    document: document, report: made.report, cost: cost, historyBudget: history, air: air,
                    alternative: other, within: within)
            } catch {
                if candidates.isEmpty { throw error }
            }
        }
    }

    /// Whether the advisor takes refined air: the finest refined base that fits is finer at the
    /// façades than the finest uniform cells that fit, and its run is no dearer.
    nonisolated static func prefersRefined(
        _ layout: DistrictLayout, radius: Float, clearFaces: Bool, uniform: DistrictAir?,
        refined: DistrictAir?,
        ground: GroundType, memory: Int
    ) -> Bool {
        guard let refined else { return false }
        guard let uniform else { return true }
        guard refined.finest < uniform.finest else { return false }
        func seconds(_ air: DistrictAir) -> Double {
            price(layout, radius: radius, clearFaces: clearFaces, air: air, ground: ground, memory: memory)
                .cost
                .seconds
        }
        return seconds(refined) <= seconds(uniform)
    }

    /// The finest uniform cells the advisor's cost model fits within `memory` with the components'
    /// histories, within the project's largest grid and 2,048 cells a side.
    nonisolated static func advisedCell(
        _ layout: DistrictLayout, radius: Float, clearFaces: Bool, ground: GroundType, memory: Int
    ) -> Float? {
        cellSizes.first {
            fits(
                layout, radius: radius, clearFaces: clearFaces,
                air: DistrictAir(cellSize: $0, refined: false),
                ground: ground, memory: memory)
        }
    }

    /// A district's air priced on a flat domain alone (the ground and the buildings are laid out
    /// only for the air chosen, and priced again then), and its grid.
    nonisolated static func price(
        _ layout: DistrictLayout, radius: Float, clearFaces: Bool, air: DistrictAir, ground: GroundType,
        memory: Int
    ) -> (cost: RunCostEstimate, grid: BlastCore.Grid) {
        let half = layout.halfSide(radius: radius, cellSize: air.cellSize, clearFaces: clearFaces)
        let top = layout.top(chargeZ: 0, highestRoof: 0, cellSize: air.cellSize)
        let scenario = Scenario(
            name: "District", domainSize: SIMD3(2 * half, 2 * half, top), boxes: [],
            charge: Charge(mass: layout.mass, position: SIMD3(half, half, 0)))
        let run = settings(
            ProjectDocument(scenario: scenario).runSettings, air: air, ground: ground,
            duration: DistrictLayout.duration(radius: radius),
            ceiling: layout.refinementCeiling(radius: radius, cellSize: air.cellSize))
        return (estimate(run, scenario, memory: memory), scenario.grid(cellSize: air.cellSize))
    }

    /// Whether a district's air fits: within the project's largest grid, 2,048 cells a side, and
    /// `memory` with the components' histories.
    nonisolated static func fits(
        _ layout: DistrictLayout, radius: Float, clearFaces: Bool, air: DistrictAir, ground: GroundType,
        memory: Int
    ) -> Bool {
        let (cost, grid) = price(
            layout, radius: radius, clearFaces: clearFaces, air: air, ground: ground, memory: memory)
        guard grid.cellCount <= ProjectDocument.maximumCells, max(grid.nx, grid.ny, grid.nz) <= 2048 else {
            return false
        }
        return cost.memory + historyBudget(memory: memory) <= memory
    }

    /// What a run of `scenario` under `run` costs on a Mac that lets the air take `memory`: the
    /// refined levels' pools may grow to what the coarse grid leaves (`fitRefinementMemory`).
    nonisolated static func estimate(_ run: ProjectRunSettings, _ scenario: Scenario, memory: Int)
        -> RunCostEstimate
    {
        var configuration = SolverConfiguration()
        ProjectRunSettings.configureAir(
            &configuration, detailedCharge: run.detailedCharge, sharpShocks: run.sharpShocks,
            shockLevels: run.shockLevels ?? 1, gravity: run.gravity ?? false,
            shockThreshold: run.shockThreshold ?? 0.1,
            adaptiveSubsteps: run.adaptiveSubsteps ?? false, terrainCutCells: run.cutsTerrain(over: scenario),
            outlineByOverlap: run.countsByOverlap(over: scenario), mappedStart: run.startsMapped,
            refinementCeiling: run.refinementCeiling)
        let cellSize = (Resolution(rawValue: run.resolution) ?? .medium).cellSize
        configuration.fitRefinementMemory(scenario.grid(cellSize: cellSize), memory: memory)
        return RunCost.estimate(
            scenario, cellSize: cellSize, configuration: configuration, duration: run.duration)
    }

    /// The memory a district's components' histories may take: an eighth of the run's, at most 4 GB
    /// (Beirut's 738,000 components took 4 GB in 0.7 ms bins over 0.5 s from each one's arrival).
    nonisolated static func historyBudget(memory: Int) -> Int { min(memory / 8, 4 << 30) }

    nonisolated private static func settings(
        _ settings: ProjectRunSettings?, air: DistrictAir, ground: GroundType, duration: Double,
        ceiling: Float
    ) -> ProjectRunSettings {
        var run = settings ?? ProjectRunSettings(settings: SimulationSettings(), duration: duration)
        run.resolution = (Resolution(cellSize: air.cellSize) ?? .coarse).rawValue
        run.sharpShocks = air.refined
        run.shockLevels = nil
        run.shockThreshold = air.refined ? DistrictAir.threshold : nil
        run.refinementCeiling = air.refined ? ceiling : nil
        // Refined, the ground as a staircase of whole cells: cut through the cells, a second level's
        // rang ahead of the shock over Beirut (±0.5–0.9 kPa from 0.8 s, 300 ms early) until the
        // terrain's cut cells are fixed there; on a staircase the arrivals are within 4%, and the
        // capped runs were checked on it.
        if air.refined { run.terrainCutCells = nil }
        run.adaptiveSubsteps = nil
        run.ground = ground == .rigid ? nil : ground
        run.duration = duration
        return run
    }
}

extension SimulationModel {
    /// The components' histories the app keeps by default: the whole run, or, for a run longer
    /// than 2 s (a district's), half a second from each one's arrival within
    /// `NewDistrictModel.historyBudget`, as Beirut's were kept (docs/beirut-2020.md).
    nonisolated static func defaultEnvelopeHistory(duration: Double, memory: Int) -> EnvelopeHistoryOptions {
        guard duration > 2 else { return EnvelopeHistoryOptions(windowS: duration) }
        return EnvelopeHistoryOptions(
            windowS: 0.5, memoryBudget: NewDistrictModel.historyBudget(memory: memory),
            windowFromArrival: true)
    }
}

/// File ▸ New District…, after New.
struct NewDistrictCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New District…") { openWindow(id: "new-district") }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
    }
}

/// The New District window (File ▸ New District…).
struct NewDistrictView: View {
    @State private var model = NewDistrictModel()
    @Environment(\.newDocument) private var newDocument
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var importing: Importing?

    private enum Importing: Identifiable {
        case map, terrain, heights
        var id: Self { self }
        var types: [UTType] {
            switch self {
            case .map:
                [
                    UTType(filenameExtension: "osm") ?? .xml, UTType(filenameExtension: "geojson") ?? .json,
                    .json,
                ]
            case .terrain, .heights:
                [.tiff, UTType(filenameExtension: "asc") ?? .plainText, .plainText]
            }
        }
    }

    init(model: NewDistrictModel = NewDistrictModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                filesSection
                chargeSection
                extentSection
                costSection
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if model.isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Lay Out") { Task { await model.lay() } }
                    .disabled(model.layout == nil || model.isWorking)
                Button("Create Project") {
                    guard let preview = model.preview else { return }
                    newDocument(preview.document)
                    dismissWindow(id: "new-district")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.preview == nil || model.isWorking)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 640)
        .fileImporter(
            isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
            allowedContentTypes: importing?.types ?? [.data]
        ) { result in
            guard let kind = importing, case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                switch kind {
                case .map: try model.readMap(url)
                case .terrain: try model.readTerrain(url)
                case .heights: try model.readHeights(url)
                }
                model.message = nil
            } catch {
                model.message = "Could not read \(url.lastPathComponent): \(error)"
            }
        }
    }

    private var filesSection: some View {
        Section {
            fileRow(
                "Map", model.map.map { "\($0.name): \($0.buildings.count) buildings" },
                help:
                    "An OpenStreetMap export (.osm, from openstreetmap.org's Export) or GeoJSON of building footprints.",
                choose: .map)
            fileRow(
                "Building heights", model.heights?.name,
                help:
                    "Optional: a raster of building heights for buildings the map gives none (GHSL's GHS-BUILT-H).",
                choose: .heights)
            fileRow(
                "Terrain", model.terrain.map { "\($0.name): \($0.grid.columns) × \($0.grid.rows)" },
                help:
                    "Optional: a GeoTIFF or ESRI ASCII grid of elevations (Copernicus GLO-30 or any the terrain importer reads).",
                choose: .terrain)
            if model.terrain != nil {
                Toggle(
                    "Surface model: take roofs and trees down to the ground", isOn: $model.terrainIsSurface
                )
                .help(
                    "A surface model such as Copernicus GLO-30 has the buildings and trees in it: its elevations "
                        + "are opened over 100 m to reach the ground, and those within a metre of sea level put at it."
                )
            }
        } header: {
            Text("Files")
        } footer: {
            Text(
                "The files stay on this Mac; the app fetches nothing. Map data © OpenStreetMap contributors (ODbL)."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func fileRow(_ title: String, _ detail: String?, help: String, choose: Importing) -> some View {
        LabeledContent(title) {
            HStack {
                Text(detail ?? "None").foregroundStyle(detail == nil ? .secondary : .primary).lineLimit(1)
                Button("Choose…") { importing = choose }
            }
        }
        .help(help)
    }

    private var chargeSection: some View {
        Section("Charge") {
            DistrictMapView(model: model).frame(height: 240)
            HStack {
                TextField("Longitude", text: $model.longitude)
                TextField("Latitude", text: $model.latitude)
            }
            LabeledContent("Yield, TNT") {
                HStack {
                    TextField("Yield", value: $model.yieldValue, format: .number)
                        .labelsHidden().multilineTextAlignment(.trailing).frame(maxWidth: 120)
                    Picker("Unit", selection: $model.yieldUnit) {
                        ForEach(NewDistrictModel.YieldUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            Picker("Ground under the charge", selection: $model.ground) {
                ForEach(GroundType.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
    }

    private var extentSection: some View {
        Section("Extent") {
            TextField(
                "Buildings within (m)",
                value: Binding(get: { Double(model.radius) }, set: { model.radius = Float(max($0, 10)) }),
                format: .number.precision(.fractionLength(0)))
            Toggle("Keep the side faces 4 m/kg^(1/3) beyond the buildings", isOn: $model.clearFaces)
                .help(
                    "The open faces release a blast that grazes them; kept 4 m/kg^(1/3) from the charge and the "
                        + "buildings, they do not reach the buildings' loads. The top is always kept so from the charge."
                )
            Toggle("Clear the building over the charge", isOn: $model.clearsChargeBuilding)
                .help(
                    "Real charges are often inside a building (Beirut's Warehouse 12). On, its footprint is open "
                        + "ground and the charge goes off in the open; off, the building stands and the charge, buried "
                        + "in its solid block, releases nothing.")
            Toggle("Near field + far field", isOn: $model.nearAndFar)
                .help(
                    "Run the air only to a hand-over where the shock has become weak and nearly spherical, and judge "
                        + "the buildings beyond it after the run on the far field carried from it: minutes, not tens of "
                        + "minutes, for a city. An estimate beyond the hand-over (docs/hybrid-far-field.md).")
            if model.nearAndFar {
                Text(
                    model.handover.map {
                        String(
                            format:
                                "Hand-over at %.0f m (Z %.0f m/kg^(1/3)): the air reaches it and its open faces' clearance; the buildings beyond are judged after the run.",
                            $0, $0 / cbrt(model.mass))
                    }
                        ?? "The district reaches too little beyond the hand-over for a far field: the air takes it all."
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker("Air", selection: $model.airChoice) {
                ForEach(NewDistrictModel.AirChoice.allCases) { Text($0.title).tag($0) }
            }
            .help(
                "Uniform cells, or a coarser base refined to half its cells where the shock is, near the ground. The advisor takes the refined "
                    + "air where it is both finer at the façades and no dearer than the uniform cells that fit."
            )
            Picker(model.airChoice == .refined ? "Base cells" : "Cells", selection: $model.cellSize) {
                Text("Finest that fits this Mac").tag(Float?.none)
                ForEach(NewDistrictModel.cellSizes, id: \.self) { size in
                    Text(Resolution.metres(size)).tag(Float?.some(size))
                }
            }
        }
    }

    @ViewBuilder
    private var costSection: some View {
        Section("Before creating") {
            if let preview = model.preview {
                let size = preview.scenario.domainSize
                Text(
                    String(
                        format:
                            "%d buildings within %.0f m: %d in the air, %d beside it; %.0f × %.0f × %.0f m of air, %@.",
                        preview.within, model.radius, preview.report.placed.count,
                        preview.far?.buildings.count ?? 0,
                        size.x, size.y, size.z, preview.air.title))
                Text(costLine(preview.cost, preview: preview))
                if let far = preview.far {
                    Text(
                        String(
                            format:
                                "Far field: %d buildings beyond %.0f m, kept beside the scene and judged after the run in about %@ on this Mac's cores (an estimate).",
                            far.buildings.count, Double(far.handoverM), RunAdvisor.duration(far.judgeSeconds))
                    )
                }
                if let other = preview.alternative {
                    Text("Instead, \(other.air.title): " + costLine(other.cost, preview: preview))
                        .foregroundStyle(.secondary)
                }
                if preview.air.refined {
                    Text(
                        "Refined air is refined only near the ground, to the height of all but the tallest 2% of the "
                            + "buildings and four base cells over them: a tower's top floors take the coarse cells' load. "
                            + "It takes the ground as a staircase of whole cells for now (docs/beirut-2020.md)."
                    )
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !preview.report.skipped.isEmpty {
                    Text("Left out: \(preview.report.skipped.count) (too small, outside or under a cell).")
                        .foregroundStyle(.secondary)
                }
                if preview.report.clearedCharge {
                    Text(
                        "The building over the charge is cleared to open ground, so that the charge goes off in the open; its walls neither confine nor vent the blast (in the standing)."
                    )
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if preview.scenario.blocks(preview.scenario.charge.position) {
                    Text(
                        "The charge is buried in a building's solid block and will release nothing: turn on Clear the building over the charge, or move the charge."
                    )
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text(
                    "What holds over a city and what does not: docs/beirut-2020.md. Structure results are not converged at these cells."
                )
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Lay the district out to see what its run costs.").foregroundStyle(.secondary)
            }
            if let message = model.message {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func costLine(_ cost: RunCostEstimate, preview: DistrictPreview) -> String {
        var line = String(
            format:
                "%.0f million cells, %d steps over %.1f s: about %@ of memory with the components' histories, ",
            Double(cost.cells) / 1e6, cost.steps, preview.document.runSettings?.duration ?? 0,
            AdvisorMachine.gigabytes(cost.memory + preview.historyBudget))
        line += RunAdvisor.duration(cost.seconds) + " unloaded"
        if let factor = RunCostStore.standard.factor {
            line += ", " + RunAdvisor.duration(cost.seconds * factor) + " here lately"
        }
        return line + "."
    }
}

/// The map's buildings as points, the radius and the charge; a click places the charge. Drawn
/// from the map file alone: no tiles are fetched.
struct DistrictMapView: View {
    @Bindable var model: NewDistrictModel

    var body: some View {
        GeometryReader { geometry in
            let frame = self.frame(in: geometry.size)
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary.opacity(0.08)))
                guard let frame else { return }
                for building in model.map?.buildings ?? [] {
                    guard let ring = building.rings.first, !ring.isEmpty else { continue }
                    let point = frame.point(ring.reduce(SIMD2<Double>.zero, +) / Double(ring.count))
                    context.fill(
                        Path(CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)),
                        with: .color(.secondary))
                }
                if let charge = model.charge {
                    let centre = frame.point(charge)
                    let r = CGFloat(Double(model.radius) * frame.pixelsPerMetre)
                    // The domain, its side faces kept clear of the buildings or not: with a far field,
                    // the near box about the hand-over, drawn as a dashed circle.
                    let handover = model.handover
                    let reach = handover ?? model.radius
                    let half = CGFloat(
                        Double(
                            model.layout?.halfSide(radius: reach, cellSize: 1, clearFaces: model.clearFaces)
                                ?? reach) * frame.pixelsPerMetre)
                    if let handover {
                        let h = CGFloat(Double(handover) * frame.pixelsPerMetre)
                        context.stroke(
                            Path(
                                ellipseIn: CGRect(
                                    x: centre.x - h, y: centre.y - h, width: 2 * h, height: 2 * h)),
                            with: .color(.orange), style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
                    }
                    context.stroke(
                        Path(
                            CGRect(x: centre.x - half, y: centre.y - half, width: 2 * half, height: 2 * half)),
                        with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    context.stroke(
                        Path(
                            ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)),
                        with: .color(.accentColor), lineWidth: 1.5)
                    context.fill(
                        Path(ellipseIn: CGRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10)),
                        with: .color(.red))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let frame else { return }
                let lonLat = frame.lonLat(location)
                model.longitude = String(format: "%.6f", lonLat.x)
                model.latitude = String(format: "%.6f", lonLat.y)
            }
            .overlay(alignment: .topLeading) {
                Text(
                    model.map == nil
                        ? "Choose a map to place the charge on it."
                        : "Click to place the charge. The circle holds the buildings placed; the square is the air."
                )
                .font(.caption).foregroundStyle(.secondary).padding(6)
            }
        }
        .accessibilityLabel("The map's buildings and the charge")
    }

    /// The map's extent fitted to `size`, north up, by a local equirectangular mapping.
    struct Frame {
        var centre: SIMD2<Double>
        var pixelsPerMetre: Double
        var size: CGSize

        func point(_ lonLat: SIMD2<Double>) -> CGPoint {
            let metres = MapBuildingPlacement(origin: centre, resolution: 1).position(lonLat)
            return CGPoint(
                x: size.width / 2 + metres.x * pixelsPerMetre, y: size.height / 2 - metres.y * pixelsPerMetre)
        }

        func lonLat(_ point: CGPoint) -> SIMD2<Double> {
            let metres =
                SIMD2(
                    Double(point.x - size.width / 2), Double(size.height / 2 - point.y)) / pixelsPerMetre
            let east = ElevationGrid.metresPerDegree * cos(centre.y * .pi / 180)
            return centre + metres / SIMD2(east, ElevationGrid.metresPerDegree)
        }
    }

    private func frame(in size: CGSize) -> Frame? {
        guard let bounds = model.mapBounds, size.width > 0, size.height > 0 else { return nil }
        let centre = (bounds.low + bounds.high) / 2
        let extent = MapBuildingPlacement(origin: bounds.low, resolution: 1).position(bounds.high)
        let scale =
            min(
                Double(size.width) / max(extent.x, 1), Double(size.height) / max(extent.y, 1)) * 0.92
        return Frame(centre: centre, pixelsPerMetre: scale, size: size)
    }
}
