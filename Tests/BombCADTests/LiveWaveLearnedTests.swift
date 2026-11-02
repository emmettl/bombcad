import BlastCore
import BlastModel
import Foundation
import Testing

@testable import BombCAD

/// The live wave's learned refinement in the app (emmettl/bombcad-work#115): off by default and
/// then the wave as it was; on without its weights, it offers the download and stays off until
/// the file is in and checked; on with them, the wave is refined on the GPU. The weights here are a
/// tiny well-formed network whose corrections are its head's biases; nothing is fetched.
@MainActor
@Suite("The live wave's learned refinement in the app", .serialized, .hangLimit)
struct LiveWaveLearnedTests {
    /// A U-Net of depth 1 and width 2 without group norms, every weight 0 and its head's biases
    /// `biases`: the same corrections everywhere.
    static func tinyWeights(biases: [Float]) throws -> Data {
        let inputs = LiveWave.Refinement.inputs
        let shapes = LearnedField.Weights.tensorShapes(
            width: 2, depth: 1, outputs: 3, inputs: inputs.count, normalised: false)
        var entries: [[String: Any]] = []
        var values: [Float] = []
        for name in LearnedField.Weights.tensorNames(depth: 1, normalised: false) {
            let shape = shapes[name]!
            let count = shape.reduce(1, *)
            entries.append(["name": name, "shape": shape, "offset": values.count, "count": count])
            values += name == "head.bias" ? biases : [Float](repeating: 0, count: count)
        }
        let header: [String: Any] = [
            "format": "bombcad-field-weights-1", "model": "unet", "width": 2, "depth": 1, "inputs": inputs,
            "stats": [
                "mean": [Double](repeating: 0, count: inputs.count),
                "std": [Double](repeating: 1, count: inputs.count),
            ],
            "residual": true, "outputs": LiveWave.Refinement.outputs, "multiple": 2, "groupNormGroups": 0,
            "groupNormEpsilon": 1e-5, "dtype": "float32", "tensors": entries,
        ]
        var text = try JSONSerialization.data(withJSONObject: header)
        text.append(contentsOf: [UInt8](repeating: 0x20, count: (16 - text.count % 16) % 16))
        var data = Data("BCFW".utf8)
        for word in [UInt32(1), UInt32(text.count)] {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(text)
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func model(_ temporary: TemporaryDefaults) async throws -> SimulationModel {
        var document = ProjectDocument(scenario: ScenarioPreset.streetCanyon.scenario)
        document.runSettings?.resolution = "coarse"
        let model = SimulationModel(document: document)
        model.learnedDefaults = temporary.defaults
        model.liveWaveLearnedHome = temporary.folder.appending(path: "LearnedModels/live-wave.bcfw")
        while model.isLoadingInputs { try await Task.sleep(for: .milliseconds(20)) }
        return model
    }

    private func waitForWave(_ model: SimulationModel, learned: Bool) async throws {
        while model.liveWave == nil || model.liveWaveInFlight || model.liveWaveShownFor?.learned != learned {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Off by default; without weights, turning it on asks, and declining leaves it off")
    func offersAndDeclines() async throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let model = try await model(temporary)
        model.liveWaveLearned = false
        model.setLiveWaveLearned(true, environment: [:])
        #expect(model.offersLiveWaveLearnedDownload && !model.liveWaveLearned)
        model.declineLiveWaveLearnedDownload()
        #expect(!model.offersLiveWaveLearnedDownload && !model.liveWaveLearned)
        #expect(model.liveWaveLearnedStatus.contains("stays off"))
        // A path set by hand that holds nothing is reported, not filled.
        temporary.defaults.set(
            temporary.folder.appending(path: "elsewhere.bcfw").path,
            forKey: SimulationModel.liveWaveLearnedWeightsKey)
        model.setLiveWaveLearned(true, environment: [:])
        #expect(!model.offersLiveWaveLearnedDownload && !model.liveWaveLearned)
        #expect(model.liveWaveLearnedStatus.contains("elsewhere.bcfw"))
    }

    @Test("A download that fails its check keeps nothing; one that passes turns it on")
    func downloads() async throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let model = try await model(temporary)
        model.liveWaveLearned = false
        let source = temporary.folder.appending(path: "release.bcfw")
        try Self.tinyWeights(biases: [0, 0, 0]).write(to: source)
        var item = LearnedFieldDownload.Item(
            source: source, destination: model.liveWaveLearnedHome,
            sha256: String(repeating: "0", count: 64), bytes: 100)
        model.setLiveWaveLearned(true, environment: [:])
        model.downloadLiveWaveLearnedWeights(item)
        await model.liveWaveLearnedDownloadTask?.value
        #expect(!model.liveWaveLearned && model.liveWaveLearnedStatus.contains("stays off"))
        #expect(!FileManager.default.fileExists(atPath: model.liveWaveLearnedHome.path))
        item.sha256 = try LearnedFieldDownload.digest(of: source)
        model.downloadLiveWaveLearnedWeights(item)
        await model.liveWaveLearnedDownloadTask?.value
        #expect(model.liveWaveLearned && item.isInPlace)
        #expect(temporary.defaults.bool(forKey: SimulationModel.liveWaveLearnedKey))
        model.setLiveWaveLearned(false)
        #expect(!model.liveWaveLearned)
    }

    @Test("On, the wave is refined on the GPU; off, it is the wave as it was")
    func refines() async throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let model = try await model(temporary)
        model.liveWaveLearned = false
        model.liveWaveShown = true
        try await waitForWave(model, learned: false)
        let plain = try #require(model.liveWave)
        #expect(!plain.refined)

        try FileManager.default.createDirectory(
            at: model.liveWaveLearnedHome.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.tinyWeights(biases: [log(2), 0, 0]).write(to: model.liveWaveLearnedHome)
        model.setLiveWaveLearned(true, environment: [:])
        #expect(model.liveWaveLearned)
        try await waitForWave(model, learned: true)
        let refined = try #require(model.liveWave)
        #expect(refined.refined && refined.refinementSeconds > 0)
        #expect(model.liveWaveStatus.contains("refined by the learned model"))
        var checked = 0
        for n in plain.peak.indices where plain.arrival[n].isFinite && plain.peak[n] > 0 {
            #expect(abs(refined.peak[n] / plain.peak[n] - 2) < 1e-4)
            #expect(refined.arrival[n] == plain.arrival[n])
            checked += 1
        }
        #expect(checked > 100)

        model.setLiveWaveLearned(false)
        try await waitForWave(model, learned: false)
        #expect(model.liveWave?.peak == plain.peak && model.liveWave?.refined == false)
        model.liveWaveShown = false
    }
}
