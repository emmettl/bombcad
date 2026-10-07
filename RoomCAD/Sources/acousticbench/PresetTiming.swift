import AcousticCore
import Foundation

/// Times every room preset as the app generates it, with the wave solver, and reports the process's
/// peak memory: the measurements behind RoomCAD's performance budgets.
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
        print("| Preset | Duration | Generation | Wave solver |")
        print("|---|---|---|---|")
        var slowest = 0.0
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
            print(
                "| \(preset.name) | \(format(settings.duration, 1)) s | \(format(seconds, 1)) s | \(wave) |")
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        // ru_maxrss is in bytes on macOS.
        print(
            "\nSlowest \(format(slowest, 1)) s; peak memory \(format(Double(usage.ru_maxrss) / 1_048_576, 0)) MB "
                + "on \(ProcessInfo.processInfo.processorCount) cores")
    }
}
