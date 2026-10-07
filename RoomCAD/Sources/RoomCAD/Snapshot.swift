import AcousticCore
import AppKit
import RoomDocument
import SwiftUI

/// Renders the starter room's drawings and a generated response offscreen, so the drawing code can be
/// checked without a window: `RoomCAD --snapshot file.png`. Controls are not rendered.
@MainActor
enum Snapshot {
    static func write(to url: URL) -> Bool {
        do {
            var settings = StereoPair.ortf.arranged(in: RoomProject.starter)
            // Show an opening of each kind: a door in a wall and a hatch in the ceiling.
            settings.openings = [
                Opening(name: "Door", surface: .north, centre: [1.2, 1], size: [0.9, 2]),
                Opening(name: "Hatch", surface: .ceiling, centre: [4.5, 1], size: [0.8, 0.8]),
            ]
            let result = try RoomResponseGenerator.generate(settings)
            let player = AuditionPlayer()
            try player.prepareImmediately(result)
            player.wetMix = 0.7
            player.seek(to: 1.5)
            let view = SnapshotView(
                settings: settings, result: result, summary: ResponseSummary(result), player: player)
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

private struct SnapshotView: View {
    let settings: RoomResponseSettings
    let result: RoomResponse
    let summary: ResponseSummary
    let player: AuditionPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                EnvelopeChart(summary: summary).frame(width: 560, height: 240)
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
