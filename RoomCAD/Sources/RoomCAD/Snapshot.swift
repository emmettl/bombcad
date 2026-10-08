import AcousticCore
import AppKit
import RoomDocument
import SwiftUI

/// Renders the starter room's drawings and a generated response offscreen, so the drawing code can be
/// checked without a window: `RoomCAD --snapshot file.png [preset]`. Controls are not rendered.
@MainActor
enum Snapshot {
    static func write(to url: URL, preset id: String? = nil) -> Bool {
        do {
            // By default the L-shaped living room, with a door in one wall and a hatch in the ceiling, and
            // an ORTF pair; or the preset named.
            let preset = RoomPresets.all.first { $0.id == (id ?? "l-shaped-living-room") }
            guard let preset else { throw CocoaError(.fileNoSuchFile) }
            var settings = StereoPair.ortf.arranged(in: preset.applied(to: RoomProject.starter))
            if id == nil {
                settings.openings = [
                    Opening(name: "Door", surface: .north, wall: 5, centre: [2, 1], size: [0.9, 2]),
                    Opening(name: "Hatch", surface: .ceiling, centre: [6, 1.5], size: [0.8, 0.8]),
                ]
            }
            let result = try RoomResponseGenerator.generate(settings)
            let player = AuditionPlayer()
            try player.prepareImmediately(result)
            player.wetMix = 0.7
            player.seek(to: 1.5)
            let view = SnapshotView(
                settings: settings, result: result, summary: ResponseSummary(result), player: player,
                threeD: threeD(settings))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: url)
            print("Wrote \(url.path)")
            return true
        } catch {
            FileHandle.standardError.write(Data("Snapshot failed: \(error.localizedDescription)\n".utf8))
            return false
        }
    }
}

/// The room in 3D from the view's starting camera, with the first surface selected, and the caption the
/// view would show for it.
@MainActor
private func threeD(_ settings: RoomResponseSettings) -> (image: CGImage, caption: String)? {
    let viewport = RoomViewport()
    viewport.show(settings)
    viewport.select(.surface(0))
    guard let renderer = viewport.renderer, let queue = viewport.commandQueue,
        let image = renderer.snapshot(commandQueue: queue, width: 1920, height: 880, camera: viewport.camera)
    else { return nil }
    return (image, viewport.caption ?? "")
}

private struct SnapshotView: View {
    let settings: RoomResponseSettings
    let result: RoomResponse
    let summary: ResponseSummary
    let player: AuditionPlayer
    let threeD: (image: CGImage, caption: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let threeD {
                VStack(alignment: .leading, spacing: 4) {
                    Text("3D").font(.caption.bold()).foregroundStyle(.secondary)
                    Image(decorative: threeD.image, scale: 2).frame(width: 960, height: 440)
                    Text(threeD.caption).font(.caption)
                }
            }
            HStack(spacing: 0) {
                ForEach(RoomProjection.allCases) { projection in
                    VStack(alignment: .leading) {
                        Text(projection.title).font(.caption.bold()).foregroundStyle(.secondary)
                        RoomDrawing(settings: .constant(settings), projection: projection, editable: false)
                    }
                    .frame(width: 480, height: 320)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Audition: \(player.clip?.name ?? "—"), 70% wet").font(.caption.bold()).foregroundStyle(
                    .secondary)
                AuditionWaveform(player: player).frame(width: 960, height: 96)
                Text(player.clip?.credit ?? "").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 12) {
                    EnvelopeChart(summary: summary).frame(width: 560, height: 240)
                    SpectrumChart(summary: summary, crossover: result.diagnostics.waveCrossover)
                        .frame(width: 560, height: 200)
                    EarlyChart(summary: summary).frame(width: 560, height: 200)
                }
                VStack(alignment: .leading, spacing: 10) {
                    DecayTable(summary: summary, diagnostics: result.diagnostics)
                    DiagnosticsList(result: result)
                }
                .frame(width: 380)
            }
        }
        .padding(16)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}
