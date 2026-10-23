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

    /// The release's two files as `file://` stand-ins in `folder`, for the model's home.
    private func standIns(_ folder: URL, model: SimulationModel) throws -> [LearnedFieldDownload.Item] {
        let ground = folder.appending(path: "release-ground.bcfw")
        let levels = folder.appending(path: "release-levels.bcfw")
        try Self.tinyWeights().write(to: ground)
        var other = try Self.tinyWeights()
        other.append(contentsOf: [0, 0])
        try other.write(to: levels)
        return [
            LearnedFieldDownload.Item(
                source: ground, destination: model.learnedHome,
                sha256: try LearnedFieldDownload.digest(of: ground),
                bytes: 100),
            LearnedFieldDownload.Item(
                source: levels, destination: model.learnedLevelsHome,
                sha256: try LearnedFieldDownload.digest(of: levels), bytes: 102),
        ]
    }

    @Test("A download that fails its check keeps nothing and leaves it off; one that passes turns it on")
    func downloads() async throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let home = temporary.folder.appending(path: "LearnedModels/field.bcfw")
        let model = model(temporary.defaults, home: home)
        let items = try standIns(temporary.folder, model: model)
        #expect(model.learnedReleaseItems.map(\.destination) == items.map(\.destination))

        model.setLearnedPeaks(true, environment: [:])
        #expect(model.offersLearnedDownload)
        var wrong = items
        wrong[1].sha256 = String(repeating: "0", count: 64)
        model.downloadLearnedWeights(wrong)
        #expect(model.learnedDownloadInFlight && !model.offersLearnedDownload)
        await model.learnedDownloadTask?.value
        #expect(!model.learnedDownloadInFlight && !model.quickEstimateLearnedPeaks)
        #expect(model.learnedDownloadStatus.contains("stays off"))
        // Neither file kept: the first passed its check, but the second did not.
        #expect(!FileManager.default.fileExists(atPath: home.path))
        #expect(!FileManager.default.fileExists(atPath: model.learnedLevelsHome.path))

        model.setLearnedPeaks(true, environment: [:])
        model.downloadLearnedWeights(items)
        await model.learnedDownloadTask?.value
        #expect(model.quickEstimateLearnedPeaks && items.allSatisfy { $0.isInPlace })
        #expect(temporary.defaults.bool(forKey: SimulationModel.learnedPeaksKey))
        #expect(
            model.learnedLevelsURL == model.learnedLevelsHome
                && !model.learnedUpdateAvailable(environment: [:]))
        #expect(model.learnedStanding == LearnedField.standing)
        // With the weights in, on is on, and off is off.
        model.setLearnedPeaks(false, environment: [:])
        #expect(!model.quickEstimateLearnedPeaks)
        model.setLearnedPeaks(true, environment: [:])
        #expect(model.quickEstimateLearnedPeaks && !model.offersLearnedDownload)
    }

    @Test(
        "With field model 1's file alone it keeps working, and the update is offered, fetched only on a click"
    )
    func update() async throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let home = temporary.folder.appending(path: "LearnedModels/field.bcfw")
        let model = model(temporary.defaults, home: home)
        let items = try standIns(temporary.folder, model: model)
        // Field model 1's install: its file alone, the option on.
        try FileManager.default.createDirectory(
            at: home.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: items[0].source, to: home)
        model.setLearnedPeaks(true, environment: [:])
        #expect(model.quickEstimateLearnedPeaks && !model.offersLearnedDownload)
        #expect(model.learnedLevelsURL == nil && model.learnedStanding == LearnedField.standingModel1)
        #expect(model.learnedUpdateAvailable(environment: [:]))
        // Not offered for a path set by hand.
        #expect(
            !model.learnedUpdateAvailable(environment: [LearnedField.environmentKey: items[0].source.path]))
        #expect(!FileManager.default.fileExists(atPath: model.learnedLevelsHome.path))
        // A failed update keeps field model 1 on, saying so.
        var wrong = items
        wrong[1].sha256 = String(repeating: "0", count: 64)
        model.downloadLearnedWeights(wrong)
        #expect(model.learnedDownloadStatus.contains("0.0 MB"))
        #expect(model.learnedDownloadStatus.contains(items[1].source.absoluteString))
        #expect(!model.learnedDownloadStatus.contains(items[0].source.absoluteString))
        await model.learnedDownloadTask?.value
        #expect(model.quickEstimateLearnedPeaks && model.learnedDownloadStatus.contains("carries on"))
        #expect(model.learnedUpdateAvailable(environment: [:]))
        // The update: the second file alone, and the option is field model 2.
        model.downloadLearnedWeights(items)
        await model.learnedDownloadTask?.value
        #expect(model.quickEstimateLearnedPeaks && items.allSatisfy { $0.isInPlace })
        #expect(!model.learnedUpdateAvailable(environment: [:]))
        #expect(model.learnedStanding == LearnedField.standing)
    }

    /// The release's files as prepared on StudioData, where they are.
    nonisolated static let release = URL(filePath: "/Volumes/StudioData/bombcad/release-field-model-2")

    @Test(
        "With the release's two files the quick estimate is field model 2's: storeys above take a peak too",
        .enabled(if: FileManager.default.fileExists(atPath: release.path))
    )
    func fieldModel2() async throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        var scene = Scenario(
            name: "One building", domainSize: SIMD3(200, 200, 24), boxes: [],
            charge: Charge(mass: 20, position: SIMD3(40, 100, 0.5)))
        let id = try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(80, 84, 0), max: SIMD3(96, 116, 12))]))
        var construction = EnvelopeConstruction(objectID: id, source: .user, detail: "glazed")
        construction.glazing = .apartments
        scene.setEnvelopeConstruction(construction)
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        let model = SimulationModel(document: document)
        model.learnedDefaults = temporary.defaults
        let home = temporary.folder.appending(path: "LearnedModels").appending(path: LearnedField.fileName)
        model.learnedHome = home
        model.refinesCloseCalls = false
        try FileManager.default.createDirectory(
            at: home.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Field model 1's file alone first, then the update beside it.
        try FileManager.default.copyItem(at: Self.release.appending(path: LearnedField.fileName), to: home)
        while model.isLoadingInputs { try await Task.sleep(for: .milliseconds(20)) }
        model.setLearnedPeaks(true, environment: [:])
        model.quickEstimate()
        while model.estimatingEnvelopeDamage { try await Task.sleep(for: .milliseconds(20)) }
        #expect(
            model.learnedPeaksStatus.contains("ground-floor façade strips"), "\(model.learnedPeaksStatus)")
        let one = Int(model.learnedPeaksStatus.split(separator: " ").compactMap { Int($0) }.first ?? 0)
        try FileManager.default.copyItem(
            at: Self.release.appending(path: LearnedField.levelsFileName), to: model.learnedLevelsHome)
        model.quickEstimate()
        while model.estimatingEnvelopeDamage { try await Task.sleep(for: .milliseconds(20)) }
        #expect(
            model.learnedPeaksStatus.hasPrefix("Learned field model 2's peak"), "\(model.learnedPeaksStatus)")
        let two = Int(model.learnedPeaksStatus.split(separator: " ").compactMap { Int($0) }.first ?? 0)
        #expect(one > 0 && two > one, "\(one) strips with field model 1, \(two) with field model 2")
        #expect(
            model.learnedNetwork?.levels != nil && model.learnedEstimator?.estimator.scatter?.upper != nil)
        model.setLearnedPeaks(false, environment: [:])
    }
}
