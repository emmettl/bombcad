import BlastCore
import BlastModel
import Foundation
import Testing

@testable import BombCAD

/// The quick estimate's learned field option (emmettl/bombcad-work#67): off by default; on without
/// the weights, it offers the download and stays off until the user clicks Download and the file
/// is in and checked. The downloads here are from a `file://` stand-in; nothing is fetched.
@MainActor @Suite("The learned field option", .serialized)
struct LearnedFieldOptionTests {
    /// A tiny but well-formed weights file: every tensor a U-Net of depth 1 has.
    static func tinyWeights() throws -> Data {
        var entries: [[String: Any]] = []
        var values: [UInt16] = []
        let shapes = LearnedField.Weights.tensorShapes(width: 1, depth: 1)
        for name in LearnedField.Weights.tensorNames(depth: 1) {
            let shape = shapes[name]!
            let count = shape.reduce(1, *)
            entries.append(["name": name, "shape": shape, "offset": values.count, "count": count])
            values += [UInt16](repeating: 0x3C00, count: count)
        }
        let header: [String: Any] = [
            "format": "bombcad-field-weights-1", "model": "unet", "width": 1, "depth": 1,
            "inputs": LearnedField.Weights.inputs,
            "stats": ["mean": [0, 0, 0, 0, 0, 0], "std": [1, 1, 1, 1, 1, 1]], "residual": true, "multiple": 2,
            "groupNormGroups": 8, "groupNormEpsilon": 1e-5, "dtype": "float16", "tensors": entries,
        ]
        var text = try JSONSerialization.data(withJSONObject: header)
        text.append(contentsOf: [UInt8](repeating: 0x20, count: (16 - text.count % 16) % 16))
        var data = Data("BCFW".utf8)
        for word in [UInt32(1), UInt32(text.count)] {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(text)
        for value in values { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    private func model(_ defaults: UserDefaults, home: URL) -> SimulationModel {
        var scenario = Scenario(
            name: "Small", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0.01, position: SIMD3(2, 2, 1)))
        scenario.gauges = []
        let model = SimulationModel(document: ProjectDocument(scenario: scenario), playbackSpeed: .unlimited)
        model.learnedDefaults = defaults
        model.learnedHome = home
        return model
    }

    @Test("Off by default; without weights, turning it on asks, and declining leaves it off")
    func offersAndDeclines() throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let home = temporary.folder.appending(path: "LearnedModels/field.bcfw")
        let model = model(temporary.defaults, home: home)
        #expect(!model.quickEstimateLearnedPeaks)
        model.setLearnedPeaks(true, environment: [:])
        #expect(
            model.offersLearnedDownload && !model.quickEstimateLearnedPeaks && !model.learnedDownloadInFlight)
        model.declineLearnedDownload()
        #expect(!model.offersLearnedDownload && !model.quickEstimateLearnedPeaks)
        #expect(model.learnedDownloadStatus.contains("stays off"))
        #expect(!FileManager.default.fileExists(atPath: home.path))
        // A path set by hand that holds nothing is reported, not filled.
        temporary.defaults.set(
            temporary.folder.appending(path: "elsewhere.bcfw").path, forKey: SimulationModel.learnedWeightsKey
        )
        model.setLearnedPeaks(true, environment: [:])
        #expect(!model.offersLearnedDownload && !model.quickEstimateLearnedPeaks)
        #expect(model.learnedDownloadStatus.contains("elsewhere.bcfw"))
    }

    @Test("A download that fails its check keeps nothing and leaves it off; one that passes turns it on")
    func downloads() async throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let home = temporary.folder.appending(path: "LearnedModels/field.bcfw")
        let model = model(temporary.defaults, home: home)
        let source = temporary.folder.appending(path: "release.bcfw")
        try Self.tinyWeights().write(to: source)

        model.setLearnedPeaks(true, environment: [:])
        #expect(model.offersLearnedDownload)
        model.downloadLearnedWeights(from: source, sha256: String(repeating: "0", count: 64))
        #expect(model.learnedDownloadInFlight && !model.offersLearnedDownload)
        await model.learnedDownloadTask?.value
        #expect(!model.learnedDownloadInFlight && !model.quickEstimateLearnedPeaks)
        #expect(model.learnedDownloadStatus.contains("stays off"))
        #expect(!FileManager.default.fileExists(atPath: home.path))

        model.setLearnedPeaks(true, environment: [:])
        model.downloadLearnedWeights(from: source, sha256: try LearnedFieldDownload.digest(of: source))
        await model.learnedDownloadTask?.value
        #expect(model.quickEstimateLearnedPeaks && FileManager.default.fileExists(atPath: home.path))
        #expect(temporary.defaults.bool(forKey: SimulationModel.learnedPeaksKey))
        // With the weights in, on is on, and off is off.
        model.setLearnedPeaks(false, environment: [:])
        #expect(!model.quickEstimateLearnedPeaks)
        model.setLearnedPeaks(true, environment: [:])
        #expect(model.quickEstimateLearnedPeaks && !model.offersLearnedDownload)
    }
}
