import BlastCore
import SwiftUI
import UniformTypeIdentifiers
import simd

/// A district laid out for File ▸ New District, and what a run of it costs.
struct DistrictPreview: Sendable {
    var document: ProjectDocument
    var report: MapBuildingReport
    var cost: RunCostEstimate
    /// The memory the components' histories may take, bytes, beside the air's.
    var historyBudget: Int
    var cellSize: Float
    /// Buildings within the radius; those placed are in `report`.
    var within: Int

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
    /// The cells chosen; nil for the finest that fits this Mac (`advisedCell`).
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
        let (radius, clear, cell, ground, memory) = (radius, clearFaces, cellSize, ground, memory)
        let result = await Task.detached(priority: .userInitiated) {
            Result {
                try Self.preview(
                    layout, radius: radius, clearFaces: clear, cellSize: cell, ground: ground, memory: memory)
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

    /// The district as a project with its run settings, the cells `cellSize` or the finest that
    /// fits `memory` (`advisedCell`), and what its run costs.
    nonisolated static func preview(
        _ layout: DistrictLayout, radius: Float, clearFaces: Bool, cellSize: Float?, ground: GroundType,
        memory: Int
    ) throws -> DistrictPreview {
        let within = layout.buildings(within: radius).count
        guard within > 0 else {
            throw MapBuilding.Failure.malformed("no building lies within \(Int(radius)) m of the charge")
        }
        let duration = DistrictLayout.duration(radius: radius)
        let history = historyBudget(memory: memory)
        var sizes =
            cellSize.map { [$0] }
            ?? cellSizes.filter {
                fits(
                    layout, radius: radius, clearFaces: clearFaces, cellSize: $0, ground: ground,
                    memory: memory)
            }
        let tooLarge = MapBuilding.Failure.malformed(
            "no cells of \(Int(cellSizes.last!)) m or less fit this Mac for a district this large")
        guard !sizes.isEmpty else { throw tooLarge }
        // Finer cells hold more of the footprints' boxes, and the ground and roofs raise the top:
        // the finest whose buildings a scene holds and whose run, laid out, still fits.
        while true {
            let cell = sizes.removeFirst()
            do {
                let half = layout.halfSide(radius: radius, cellSize: cell, clearFaces: clearFaces)
                let made = try layout.scene(
                    halfSide: half, cellSize: cell, radius: radius,
                    name: String(format: "District at %.4f, %.4f", layout.charge.y, layout.charge.x))
                var document = ProjectDocument(scenario: made.scene)
                let run = settings(document.runSettings, cellSize: cell, ground: ground, duration: duration)
                document.runSettings = run
                try ProjectDocument.validate(made.scene)
                try ProjectDocument.validateGrid(
                    made.scene, resolution: Resolution(cellSize: cell) ?? .coarse)
                let cost = run.costEstimate(made.scene)
                if cellSize == nil, cost.memory + history > memory {
                    if sizes.isEmpty { throw tooLarge }
                    continue
                }
                return DistrictPreview(
                    document: document, report: made.report, cost: cost, historyBudget: history,
                    cellSize: cell,
                    within: within)
            } catch {
                if sizes.isEmpty { throw error }
            }
        }
    }

    /// The finest uniform cells the advisor's cost model fits within `memory` with the components'
    /// histories, within the project's largest grid and 2,048 cells a side. Refinement is not
    /// offered: over a district it does not yet run cleanly (docs/beirut-2020.md).
    nonisolated static func advisedCell(
        _ layout: DistrictLayout, radius: Float, clearFaces: Bool, ground: GroundType, memory: Int
    ) -> Float? {
        cellSizes.first {
            fits(layout, radius: radius, clearFaces: clearFaces, cellSize: $0, ground: ground, memory: memory)
        }
    }

    /// Whether a district's air on `cellSize` cells fits: priced on a flat domain alone (the ground
    /// and the buildings are laid out only for the cells chosen, and priced again then).
    nonisolated static func fits(
        _ layout: DistrictLayout, radius: Float, clearFaces: Bool, cellSize: Float, ground: GroundType,
        memory: Int
    ) -> Bool {
        let half = layout.halfSide(radius: radius, cellSize: cellSize, clearFaces: clearFaces)
        let top = layout.top(chargeZ: 0, highestRoof: 0, cellSize: cellSize)
        let scenario = Scenario(
            name: "District", domainSize: SIMD3(2 * half, 2 * half, top), boxes: [],
            charge: Charge(mass: layout.mass, position: SIMD3(half, half, 0)))
        let grid = scenario.grid(cellSize: cellSize)
        guard grid.cellCount <= ProjectDocument.maximumCells, max(grid.nx, grid.ny, grid.nz) <= 2048 else {
            return false
        }
        let document = ProjectDocument(scenario: scenario)
        let run = settings(
            document.runSettings, cellSize: cellSize, ground: ground,
            duration: DistrictLayout.duration(radius: radius))
        return run.costEstimate(scenario).memory + historyBudget(memory: memory) <= memory
    }

    /// The memory a district's components' histories may take: an eighth of the run's, at most 4 GB
    /// (Beirut's 738,000 components took 4 GB in 0.7 ms bins over 0.5 s from each one's arrival).
    nonisolated static func historyBudget(memory: Int) -> Int { min(memory / 8, 4 << 30) }

    nonisolated private static func settings(
        _ settings: ProjectRunSettings?, cellSize: Float, ground: GroundType, duration: Double
    ) -> ProjectRunSettings {
        var run = settings ?? ProjectRunSettings(settings: SimulationSettings(), duration: duration)
        run.resolution = (Resolution(cellSize: cellSize) ?? .coarse).rawValue
        run.sharpShocks = false
        run.shockLevels = nil
        run.shockThreshold = nil
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
            Picker("Cells", selection: $model.cellSize) {
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
                            "%d of %d buildings within %.0f m placed; %.0f × %.0f × %.0f m of air on %@ cells.",
                        preview.report.placed.count, preview.within, model.radius, size.x, size.y, size.z,
                        Resolution.metres(preview.cellSize)))
                Text(costLine(preview))
                if !preview.report.skipped.isEmpty {
                    Text("Left out: \(preview.report.skipped.count) (too small, outside or under a cell).")
                        .foregroundStyle(.secondary)
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

    private func costLine(_ preview: DistrictPreview) -> String {
        let cost = preview.cost
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
                    // The domain, its side faces kept clear of the buildings or not.
                    let half = CGFloat(
                        Double(
                            model.layout?.halfSide(
                                radius: model.radius, cellSize: 1, clearFaces: model.clearFaces)
                                ?? model.radius) * frame.pixelsPerMetre)
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
