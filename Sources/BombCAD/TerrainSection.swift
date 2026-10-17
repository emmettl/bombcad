import BlastCore
import SwiftUI
import UniformTypeIdentifiers

/// The Run tab's Terrain section: the ground's shape under the scene, flat by default, a simple
/// shape or a crop of an elevation grid (an ESRI ASCII grid or a GeoTIFF). The air sees its surface
/// cut through the cells, or, where the staircase is chosen, as whole cells.
struct TerrainSection: View {
    @Bindable var model: SimulationModel
    /// The grid last imported, kept for moving its crop; the scene keeps only the crop.
    @State private var dem: (name: String, grid: ElevationGrid)?
    /// Where the crop starts, metres east and north of the grid's south-west cell.
    @State private var offset = SIMD2<Float>.zero
    @State private var isImporting = false
    @State private var error: String?

    private enum Shape: String, CaseIterable, Identifiable {
        case flat = "Flat"
        case hill = "Hill"
        case ridge = "Ridge"
        case slope = "Slope"
        case imported = "Elevation grid"
        var id: String { rawValue }
    }

    private var scenario: Scenario { model.settings.scenario }

    /// What the ground is made of, as the picker offers it.
    private enum Material: Hashable {
        case rigid
        /// Soil under the debris and nothing else, as soft ground was before ground types.
        case debrisOnly
        case type(GroundType)
    }

    private var material: Binding<Material> {
        Binding(
            get: {
                let settings = model.settings
                if settings.ground != .rigid { return .type(settings.ground) }
                return settings.softGround ? .debrisOnly : .rigid
            },
            set: { choice in
                switch choice {
                case .rigid:
                    model.settings.ground = .rigid
                    model.settings.softGround = false
                case .debrisOnly:
                    model.settings.ground = .rigid
                    model.settings.softGround = true
                case .type(let type):
                    model.settings.ground = type
                    model.settings.waterTable = type.typicalWaterTable
                    model.settings.softGround = true
                    model.settings.groundStiffness =
                        type.debrisModulus ?? SolverConfiguration.soilSubgradeModulus
                }
            })
    }

    /// The crater the charge would dig, before or after a run: it depends only on the scene.
    private var craterCaption: String {
        let craters = CraterEstimate.craters(
            of: scenario, ground: model.settings.ground, waterTable: model.settings.waterTable)
        guard let crater = craters.first else {
            return "The charge is too high above the ground to dig a crater: an air burst."
        }
        return crater.summary + (craters.count > 1 ? ", and \(craters.count - 1) more" : "")
            + ". Approximation: Cooper's scaling, with a scatter of a third; the depth a rule of thumb. "
            + "Drawn on the ground when the run ends."
    }

    var body: some View {
        Section("Terrain") {
            Picker("Ground", selection: shape) {
                ForEach(Shape.allCases.filter { $0 != .imported || dem != nil || isImported }) {
                    Text($0.rawValue).tag($0)
                }
            }
            .help("The ground's shape, rigid and smooth.")
            if let terrain = scenario.terrain, !terrain.isFlat {
                Toggle("Cut cells along its slopes", isOn: $model.settings.terrainCutCells)
                    .help(
                        "Cuts the surface through the air's cells, so that a slope reflects the blast as a slope "
                            + "does. Off, the surface is a staircase of whole cells, which delays Mach reflection "
                            + "and overstates the peaks on faces towards the charge. About 10% slower a step."
                    )
                if shape.wrappedValue != .imported {
                    LabeledSlider(
                        title: "Relief", value: relief, range: 1...Double(0.6 * scenario.domainSize.z),
                        text: String(format: "%.1f m", terrain.highest))
                } else if let dem {
                    cropSliders(dem.grid)
                }
                LabeledContent("Charge above the ground", value: String(format: "%.2f m", chargeClearance))
                Button("Place the charge on the ground") {
                    model.settings.scenario.charge.position.z = scenario.groundHeight(
                        at: scenario.charge.position)
                }
                Text(caption(terrain))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Made of", selection: material) {
                Text("Rigid ground").tag(Material.rigid)
                Text("Soil under debris only").tag(Material.debrisOnly)
                Divider()
                ForEach(GroundType.allCases.filter { $0 != .rigid }, id: \.self) {
                    Text($0.title).tag(Material.type($0))
                }
            }
            .help(
                "What the ground is. Rigid ground reflects the whole blast, digs no crater and stops debris dead, "
                    + "which shatters falling brickwork. Soil under debris only gives under a structure's debris, a "
                    + "bed of the stiffness below, and nothing else. Earth or rock also digs each charge a crater, "
                    + "estimated by Cooper's scaling and drawn after the run, and leaves the air less of a charge "
                    + "near it: 0.9 of one on the surface. The crater forms after the blast has gone, so the "
                    + "air keeps the ground as it was.")
            if model.settings.ground != .rigid {
                Toggle(
                    "Water table near the surface",
                    isOn: Binding(
                        get: { model.settings.waterTable != nil },
                        set: { model.settings.waterTable = $0 ? (model.settings.waterTable ?? 1) : nil })
                )
                .help(
                    "Below a water table a crater's walls slump to 10–15° and it comes out far shallower: the "
                        + "500-ton craters at Suffield and Beirut's were a fifth to a third as deep as dry ground "
                        + "gives. On by default for saturated soil, with the water at the surface.")
                if let table = model.settings.waterTable {
                    LabeledSlider(
                        title: "Water table",
                        value: Binding(
                            get: { Double(table) },
                            set: { model.settings.waterTable = Float(($0 * 2).rounded() / 2) }),
                        range: 0...20, text: String(format: "%.1f m down", table))
                }
                Text(craterCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.settings.softGround {
                LabeledSlider(
                    title: "Soil stiffness",
                    value: Binding(
                        get: { log10(Double(model.settings.groundStiffness)) },
                        set: { model.settings.groundStiffness = Float((pow(10, $0) / 1e6).rounded() * 1e6) }),
                    range: log10(
                        Double(SolverConfiguration.soilSubgradeRange.lowerBound))...log10(
                            Double(SolverConfiguration.soilSubgradeRange.upperBound)),
                    text: String(format: "%.0f MN/m³", model.settings.groundStiffness / 1e6))
                Text(
                    "The soil's subgrade modulus: about 10–20 MN/m³ for loose sand or soft clay, 50 for medium dense "
                        + "sand (the default), 100–150 for dense sand or stiff clay."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Button("Import elevation grid…") { isImporting = true }
                .help(
                    "An ESRI ASCII grid (.asc) or a GeoTIFF (.tif) of elevations, cropped to the scene from its south-west corner."
                )
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [
                UTType(filenameExtension: "asc") ?? .data, UTType(filenameExtension: "tif") ?? .data,
                UTType(filenameExtension: "tiff") ?? .data,
            ]
        ) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let grid = try ElevationGrid(contentsOf: url)
                dem = (url.lastPathComponent, grid)
                offset = .zero
                try crop()
                error = nil
            } catch {
                self.error = "Could not use the elevation grid: \(error)"
            }
        }
    }

    private var isImported: Bool {
        guard let source = scenario.terrain?.source else { return false }
        return !["flat", "hill", "ridge", "slope"].contains { source.hasPrefix($0) }
    }

    private var chargeClearance: Float {
        scenario.charge.position.z - scenario.groundHeight(at: scenario.charge.position)
    }

    private func caption(_ terrain: Terrain) -> String {
        let cell = model.grid?.cellSize ?? 0
        let nodes =
            (terrain.source.map { $0.prefix(1).uppercased() + $0.dropFirst() + ". " } ?? "")
            + "\(terrain.columns) × \(terrain.rows) nodes \(terrain.spacing) m apart. "
        let steps =
            (cell > 0
                ? "On \(cell) m cells its slopes are steps of whole cells, "
                : "Its slopes are steps of whole cells, ")
            + "which delay Mach reflection on them; finer cells approach a smooth slope."
        guard model.settings.terrainCutCells else { return nodes + steps }
        return nodes + "Its slopes are cut through the cells, and reflect the blast as smooth slopes do."
    }

    private var shape: Binding<Shape> {
        Binding(
            get: {
                guard let terrain = scenario.terrain, !terrain.isFlat else { return .flat }
                if isImported { return .imported }
                let source = terrain.source ?? ""
                return Shape.allCases.first { source.hasPrefix($0.rawValue.lowercased()) } ?? .hill
            },
            set: { new in
                error = nil
                if new == .imported {
                    try? crop()
                } else {
                    model.settings.scenario.replaceTerrain(
                        with: made(new, relief: 0.3 * scenario.domainSize.z))
                }
            })
    }

    private var relief: Binding<Double> {
        Binding(
            get: { Double(scenario.terrain?.highest ?? 0) },
            set: { value in
                model.settings.scenario.replaceTerrain(
                    with: made(shape.wrappedValue, relief: Float(value.rounded())))
            })
    }

    /// One of the shapes, `relief` high, under the scene; nil for flat ground.
    private func made(_ shape: Shape, relief: Float) -> Terrain? {
        let domain = scenario.domainSize
        let spacing = min(1, model.grid?.cellSize ?? 1)
        // Beside the charge, so that the blast meets it.
        let charge = SIMD2(scenario.charge.position.x, scenario.charge.position.y)
        let side: Float = charge.x < domain.x / 2 ? 1 : -1
        let at = SIMD2(min(max(charge.x + side * 0.3 * domain.x, 0), domain.x), domain.y / 2)
        switch shape {
        case .flat, .imported: return nil
        case .hill:
            return .hill(
                domain: domain, spacing: spacing, centre: at, height: relief, radius: 0.12 * domain.x)
        case .ridge:
            return .ridge(
                domain: domain, spacing: spacing, crest: at.x, height: relief, halfWidth: 2 * relief)
        case .slope:
            let foot = at.x - 0.1 * domain.x
            let angle = atan(relief / max(domain.x - foot, 1)) * 180 / .pi
            return side > 0
                ? .slope(domain: domain, spacing: spacing, foot: foot, angle: angle)
                : .sampled(
                    domain: domain, spacing: spacing, source: "slope of \(angle)° falling to x = \(foot) m"
                ) {
                    max(0, (foot - $0.x) * tan(angle * .pi / 180))
                }
        }
    }

    @ViewBuilder
    private func cropSliders(_ grid: ElevationGrid) -> some View {
        let size =
            grid.spacingInMetres(near: grid.southWest)
            * SIMD2(Double(grid.columns - 1), Double(grid.rows - 1))
        let room = SIMD2<Float>(Float(size.x) - scenario.domainSize.x, Float(size.y) - scenario.domainSize.y)
        ForEach(0..<2, id: \.self) { axis in
            if room[axis] > 0 {
                LabeledSlider(
                    title: axis == 0 ? "Crop east" : "Crop north",
                    value: Binding(
                        get: { Double(offset[axis]) },
                        set: {
                            offset[axis] = Float($0.rounded())
                            try? crop()
                        }),
                    range: 0...Double(room[axis]), text: String(format: "%.0f m", offset[axis]))
            }
        }
    }

    /// The imported grid's crop under the scene, from `offset`, its lowest point on the floor; scaled
    /// down to 60% of the domain's height if its relief is more.
    private func crop() throws {
        guard let dem else { return }
        let grid = dem.grid
        let spacing = Float(max(min(grid.spacingInMetres(near: grid.southWest).min(), 2), 0.25))
        let origin = grid.coordinates(of: SIMD2<Double>(offset), origin: grid.southWest)
        var (terrain, _) = try grid.terrain(
            origin: origin, size: SIMD2(scenario.domainSize.x, scenario.domainSize.y), spacing: spacing,
            name: dem.name)
        let top = 0.6 * scenario.domainSize.z
        if terrain.highest > top {
            let scale = top / terrain.highest
            terrain.heights = terrain.heights.map { $0 * scale }
            terrain.source = (terrain.source ?? dem.name) + String(format: ", heights scaled by %.2f", scale)
        }
        model.settings.scenario.replaceTerrain(with: terrain)
    }
}
