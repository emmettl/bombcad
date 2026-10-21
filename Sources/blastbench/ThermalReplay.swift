import BlastCore
import Foundation

/// An opt-in diagnostic recording of actual consumer inputs, separate from saved run results.
struct ThermalReplaySetup: Codable {
    var spec: ThermalSpec
    var scene: FragmentScene
    var receivers: [ThermalReceiver]
}

struct ThermalReplayFrame: Codable {
    var index: Int
    var time: Double
    var cellBytes: Int
    var extractionSeconds: Double
    var encodingSeconds: Double
    var localConsumerSeconds: Double
}

final class ThermalReplayWriter {
    let directory: URL
    var frames: [ThermalReplayFrame] = []

    init(path: String, exposure: ThermalExposure, scene: FragmentScene) throws {
        directory = URL(fileURLWithPath: path, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let setup = ThermalReplaySetup(spec: exposure.spec, scene: scene, receivers: exposure.receivers)
        try JSONEncoder().encode(setup).write(to: directory.appendingPathComponent("setup.json"))
    }

    func append(_ frame: FireballFrame, extraction: Double, consumer: Double) throws {
        let started = ContinuousClock.now
        let stem = String(format: "%05d", frames.count)
        let cells = frame.cells?.binary ?? Data()
        try cells.write(to: directory.appendingPathComponent(stem + ".bin"), options: .withoutOverwriting)
        try JSONEncoder().encode(frame.withoutCells).write(
            to: directory.appendingPathComponent(stem + ".json"), options: .withoutOverwriting)
        frames.append(
            ThermalReplayFrame(
                index: frames.count, time: frame.time, cellBytes: cells.count,
                extractionSeconds: extraction,
                encodingSeconds: (ContinuousClock.now - started) / .seconds(1), localConsumerSeconds: consumer
            ))
    }

    func finish(_ exposure: ThermalExposure) throws {
        try JSONEncoder().encode(frames).write(to: directory.appendingPathComponent("frames.json"))
        try JSONEncoder().encode(exposure.result).write(
            to: directory.appendingPathComponent("reference.json"))
    }
}

func runThermalReplay(path: String) throws {
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let decoder = JSONDecoder()
    let setup = try decoder.decode(
        ThermalReplaySetup.self, from: Data(contentsOf: root.appendingPathComponent("setup.json")))
    let frames = try decoder.decode(
        [ThermalReplayFrame].self, from: Data(contentsOf: root.appendingPathComponent("frames.json")))
    let started = ContinuousClock.now
    var exposure = ThermalExposure(spec: setup.spec, scene: setup.scene)
    guard exposure.receivers == setup.receivers else { throw CocoaError(.coderReadCorrupt) }
    var decoding = 0.0
    var consuming = 0.0
    for (index, entry) in frames.enumerated() {
        guard entry.index == index else { throw CocoaError(.coderReadCorrupt) }
        let reading = ContinuousClock.now
        let stem = String(format: "%05d", index)
        var frame = try decoder.decode(
            FireballFrame.self, from: Data(contentsOf: root.appendingPathComponent(stem + ".json")))
        let cells = try Data(contentsOf: root.appendingPathComponent(stem + ".bin"))
        guard cells.count == entry.cellBytes, frame.time == entry.time else {
            throw CocoaError(.coderReadCorrupt)
        }
        frame.cells = cells.isEmpty ? nil : try LuminousCells(binary: cells)
        decoding += (ContinuousClock.now - reading) / .seconds(1)
        let adding = ContinuousClock.now
        exposure.add(frame)
        consuming += (ContinuousClock.now - adding) / .seconds(1)
    }
    let reference = try decoder.decode(
        ThermalResult.self, from: Data(contentsOf: root.appendingPathComponent("reference.json")))
    guard exposure.result.fluence == reference.fluence,
        exposure.result.peakIrradiance == reference.peakIrradiance
    else {
        throw CocoaError(.coderReadCorrupt)
    }
    print("Replay: \(frames.count) frames, \(setup.receivers.count) receivers; exact fluence/peak match")
    print(
        "Decode/read \(decoding) s; consumer \(consuming) s; total \((ContinuousClock.now - started) / .seconds(1)) s"
    )
}
