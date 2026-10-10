import BlastCore
import SwiftUI
import UniformTypeIdentifiers

/// The Run tab's Terrain section: the ground's shape under the scene, flat by default, a simple
/// shape or a crop of an elevation grid (an ESRI ASCII grid or a GeoTIFF). The air sees it as
/// solid cells under its surface.
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

    var body: some View {
        Section("Terrain") {
            Picker("Ground", selection: shape) {
                ForEach(Shape.allCases.filter { $0 != .imported || dem != nil || isImported }) {
                    Text($0.rawValue).tag($0)
                }
            }
            .help(
                "The ground's shape. The air sees it as solid cells below its surface: a staircase of whole cells."
            )
            if let terrain = scenario.terrain, !terrain.isFlat {
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
        return (terrain.source.map { $0.prefix(1).uppercased() + $0.dropFirst() + ". " } ?? "")
            + "\(terrain.columns) × \(terrain.rows) nodes \(terrain.spacing) m apart. "
            + (cell > 0
                ? "On \(cell) m cells its slopes are steps of whole cells, "
                : "Its slopes are steps of whole cells, ")
            + "which delay Mach reflection on them; finer cells approach a smooth slope."
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
