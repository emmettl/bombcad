import AcousticCore
import Audition
import Foundation

/// Times every room preset as the app generates it, with the wave solver, and the convolution that
/// prepares the longest bundled clip for auditioning through it, and reports the process's peak memory:
/// the measurements behind RoomCAD's performance budgets. Playing a prepared clip only mixes two
/// buffers.
///
///   acousticbench --presets
enum PresetTiming {
    static func run() throws {
        let base = RoomResponseSettings(
            room: ShoeboxRoom(size: [5, 4, 3], material: .rigid),
            source: RoomPoint(name: "Source", position: [1, 1, 1]),
            receivers: [
                RoomPoint(name: "Left", position: [2, 2, 1]), RoomPoint(name: "Right", position: [2, 3, 1]),
            ],
            lowFrequencyModel: true)
        let clip =
            DryClip.bundled(sampleRate: base.sampleRate).max { $0.samples.count < $1.samples.count }
            ?? DryClip.noiseBurst(sampleRate: base.sampleRate)
        print(
            "Auditioning \(clip.name), \(format(Double(clip.samples.count) / Double(base.sampleRate), 1)) s long"
        )
        print("| Preset | Duration | Generation | Wave solver | Preview | Audition preparation |")
        print("|---|---|---|---|---|---|")
        var slowest = 0.0
        var slowestAudition = 0.0
        for preset in RoomPresets.all {
            let settings = preset.applied(to: base)
            let start = Date()
            let result = try RoomResponseGenerator.generate(settings)
            let seconds = Date().timeIntervalSince(start)
            slowest = max(slowest, seconds)
            let d = result.diagnostics
            let wave =
                d.waveCrossover.map {
                    "below \(Int($0.rounded())) Hz, \(d.waveGPURuns ?? 0) of \(d.waveRuns ?? 0) runs on the GPU"
                } ?? "skipped"
            let previewStart = Date()
            let preview = try RoomResponseGenerator.generate(settings, quality: .preview)
            let previewSeconds = Date().timeIntervalSince(previewStart)
            let previewWave =
                preview.diagnostics.waveCrossover.map { ", below \(Int($0.rounded())) Hz" } ?? ""
            let auditionStart = Date()
            _ = try AuditionPreview(clip: clip, response: result.response)
            let audition = Date().timeIntervalSince(auditionStart)
            slowestAudition = max(slowestAudition, audition)
            print(
                "| \(preset.name) | \(format(settings.duration, 1)) s | \(format(seconds, 1)) s | \(wave) | "
                    + "\(format(previewSeconds, 1)) s\(previewWave) | \(format(audition, 2)) s |")
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        // ru_maxrss is in bytes on macOS.
        print(
            "\nSlowest generation \(format(slowest, 1)) s, audition preparation \(format(slowestAudition, 2)) s; "
                + "peak memory \(format(Double(usage.ru_maxrss) / 1_048_576, 0)) MB "
                + "on \(ProcessInfo.processInfo.processorCount) cores")
    }
}
