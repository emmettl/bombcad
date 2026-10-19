import BlastCore
import SwiftUI
import UniformTypeIdentifiers
import simd

extension SimulationModel {
    /// Makes the rigid imports `ids` exposure-only envelopes. An IFC import's windows and doors that
    /// were left out (open meshes) are read back from its retained IFC as bounds, and cut as openings
    /// as well, when the converter is at hand. Undo restores the imports.
    func useImportsAsEnvelopes(_ ids: [UUID]) async throws -> [EnvelopeConversionReport] {
        guard !isPreparingImports else {
            throw ImportedMesh.ImportError.invalid("Wait for the imports to finish resampling.")
        }
        var openings: [UUID: [Box]] = [:]
        for model in settings.scenario.importedModels ?? [] where ids.contains(model.id) {
            if model.source.buildingSourceData != nil, IFCImporter.converterURL != nil {
                openings[model.id] = try await IFCImporter.excludedOpeningBoxes(of: model)
            }
        }
        var scene = settings.scenario
        let reports = try scene.useEnvelopes(importIDs: ids, openings: openings)
        settings.scenario = scene
        return reports
    }

    /// Places map buildings as exposure-only envelopes on the scene (and its terrain), its (0, 0) at
    /// `origin` (longitude, latitude), their footprints on `resolution` cells. Undo removes them.
    func placeMapBuildings(
        _ buildings: [MapBuilding], origin: SIMD2<Double>, resolution: Float,
        clearsChargeBuilding: Bool = true
    ) throws
        -> MapBuildingReport
    {
        var scene = settings.scenario
        var placement = MapBuildingPlacement(origin: origin, resolution: resolution)
        placement.clearsChargeBuilding = clearsChargeBuilding
        let report = try scene.addMapBuildings(buildings, placement: placement)
        settings.scenario = scene
        return report
    }
}

/// Makes rigid imports exposure-only envelopes, from the Run tab's imported geometry.
struct ImportEnvelopeButton: View {
    @Bindable var model: SimulationModel
    let ids: [UUID]
    let title: String
    @State private var isWorking = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(title) {
                isWorking = true
                Task {
                    do {
                        let reports = try await model.useImportsAsEnvelopes(ids)
                        message = reports.map(\.note).joined(separator: "\n")
                    } catch {
                        message = "Could not make an envelope: \(error.localizedDescription)"
                    }
                    isWorking = false
                }
            }
            .disabled(isWorking || model.isPreparingImports)
            .help(
                "Keep the import as a stationary, exposure-only building: its sampled boxes as walls and roofs, "
                    + "its windows and doors as openings. Element identities and materials are not kept; Undo "
                    + "restores the import.")
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            }
        }
    }
}

/// The Run tab's Map buildings section: building footprints from an OpenStreetMap extract (.osm) or
/// GeoJSON the user supplies, placed as exposure-only envelopes, on the terrain if there is one.
struct MapBuildingsSection: View {
    @Bindable var model: SimulationModel
    @State private var loaded: (name: String, buildings: [MapBuilding])?
    @State private var longitude = ""
    @State private var latitude = ""
    @State private var isImporting = false
    @State private var message: String?
    @State private var clearsChargeBuilding = true

    var body: some View {
        Section("Map buildings") {
            Button("Read map buildings…") { isImporting = true }
                .help(
                    "Building footprints and heights from an OpenStreetMap extract (.osm) or GeoJSON you have "
                        + "downloaded. Placed as solid, exposure-only envelopes.")
            if let loaded {
                Text("\(loaded.buildings.count) buildings in \(loaded.name).").font(.caption)
                TextField("Longitude of the scene's corner", text: $longitude)
                TextField("Latitude of the scene's corner", text: $latitude)
                Toggle("Clear the building over the charge", isOn: $clearsChargeBuilding)
                    .help(
                        "Leave open ground where a footprint holds the charge, so that it goes off in the open. "
                            + "Off, the building stands and the charge, buried in its solid block, releases nothing."
                    )
                Button("Place buildings") { place(loaded.buildings) }
                    .disabled(Double(longitude) == nil || Double(latitude) == nil)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            }
            ForEach(model.settings.scenario.attributions ?? [], id: \.self) { credit in
                Text(credit).font(.caption2).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [
                UTType(filenameExtension: "osm") ?? .data, UTType(filenameExtension: "geojson") ?? .data,
                .json,
            ]
        ) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let buildings = try MapBuilding.read(contentsOf: url)
                loaded = (url.lastPathComponent, buildings)
                // By default the scene's corner is the buildings' south-west corner.
                let corner = buildings.flatMap { $0.rings.flatMap { $0 } }.reduce(
                    SIMD2(Double.infinity, .infinity), simd_min)
                if corner.x.isFinite {
                    longitude = String(format: "%.6f", corner.x)
                    latitude = String(format: "%.6f", corner.y)
                }
                message = buildings.isEmpty ? "No buildings found in \(url.lastPathComponent)." : nil
            } catch {
                message = "Could not read the map data: \(error)"
            }
        }
    }

    private func place(_ buildings: [MapBuilding]) {
        guard let lon = Double(longitude), let lat = Double(latitude) else { return }
        do {
            let report = try model.placeMapBuildings(
                buildings, origin: SIMD2(lon, lat), resolution: model.grid?.cellSize ?? 0.5,
                clearsChargeBuilding: clearsChargeBuilding)
            let skipped = report.skipped.prefix(5).map { "\($0.id): \($0.reason)" }.joined(separator: "; ")
            message =
                report.summary + "."
                + (skipped.isEmpty ? "" : " Left out: \(skipped)\(report.skipped.count > 5 ? "…" : "").")
        } catch {
            message = "Could not place the buildings: \(error)"
        }
    }
}
