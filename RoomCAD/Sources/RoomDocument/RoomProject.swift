import AcousticCore
import DocumentKit
import Foundation
import ImpulseResponseKit
import simd

/// How a response is conditioned when exported for a convolution engine. Applied to a copy; the
/// retained response keeps the model's own levels and timing.
public struct ExportSettings: Codable, Equatable, Sendable {
    /// Largest absolute sample after one common gain, or nil to keep the model's levels.
    public var peak: Float?
    /// Half-cosine fade over the end of the response, in seconds.
    public var fadeOut: Double
    /// Remove the common propagation delay before the earliest direct sound.
    public var removeLeadingDelay: Bool

    public init(peak: Float? = 0.5, fadeOut: Double = 0.01, removeLeadingDelay: Bool = false) {
        self.peak = peak
        self.fadeOut = fadeOut
        self.removeLeadingDelay = removeLeadingDelay
    }

    public func validate() throws {
        if let peak, !(peak.isFinite && peak > 0 && peak <= 1) {
            throw ProjectFileError.invalid("The export peak must be above 0 and at most 1.")
        }
        guard fadeOut.isFinite, (0...1).contains(fadeOut) else {
            throw ProjectFileError.invalid("The export fade must be between 0 and 1 second.")
        }
    }

    /// Conditions a copy of `result` for export: delay removal, then the fade, then the common gain.
    public func conditioned(_ result: RoomResponse) throws -> RoomResponse {
        try validate()
        var output = result
        if removeLeadingDelay, let delay = result.diagnostics.directDelay.min() {
            // Keep the kernel's leading half so the direct sound is not clipped.
            let frames = Int((delay * Double(result.response.sampleRate)).rounded(.down)) - 64
            if frames > 0 { try output.response.removeLeadingFrames(frames) }
        }
        try output.response.fadeOut(seconds: fadeOut)
        if let peak { try output.response.normalizePeak(to: peak) }
        return output
    }
}

/// Everything a `.roomcad` document holds.
public struct RoomProject: Equatable, Sendable {
    public static let documentType = "roomcad"
    public static let producer = "RoomCAD"
    /// Retained responses larger than this are not saved in the document.
    public static let maximumRetainedBytes = 48 * 1024 * 1024

    public var documentID: UUID
    public var settings: RoomResponseSettings
    public var export: ExportSettings
    /// The last generated response, if any. It may be stale; see `isResultCurrent`.
    public var result: RoomResponse?
    /// Files this version does not interpret, kept when the document is saved again.
    private var preserved: [String: Data] = [:]
    private var manifest: ProjectManifest?

    public init(
        settings: RoomResponseSettings = RoomProject.starter, export: ExportSettings = ExportSettings(),
        documentID: UUID = UUID()
    ) {
        self.documentID = documentID
        self.settings = settings
        self.export = export
    }

    /// The living-room preset, with published absorption, a source and a spaced pair of receivers, and the
    /// wave solver below the crossover.
    public static var starter: RoomResponseSettings {
        let blank = RoomResponseSettings(
            room: ShoeboxRoom(size: [1, 1, 1], material: .rigid),
            source: RoomPoint(name: "Source", position: [0.5, 0.5, 0.5]),
            receivers: [])
        var settings = RoomPresets.all[0].applied(to: blank)
        settings.lowFrequencyModel = true
        return settings
    }

    /// Whether the retained response was generated from the current settings by the current generator.
    public var isResultCurrent: Bool {
        guard let result else { return false }
        return result.settings == settings && result.response.metadata.generator == RoomResponse.generatorName
    }

    // MARK: - Payloads

    struct Scene: Codable, Equatable {
        static let formatIdentifier = "dev.roomcad.scene"
        var format = formatIdentifier
        var encodingVersion = 1
        var room: ShoeboxRoom
        var source: RoomPoint
        var receivers: [RoomPoint]
        /// Absent in documents saved before openings existed.
        var openings: [Opening]? = nil
    }

    struct Settings: Codable, Equatable {
        static let formatIdentifier = "dev.roomcad.settings"
        var format = formatIdentifier
        var encodingVersion = 1
        var atmosphere: Atmosphere
        var airAbsorption: Bool
        var sampleRate: Int
        var duration: Double
        var maximumReflectionOrder: Int
        var content: ResponseMetadata.Content
        var lowFrequencyCutoff: Double
        var export: ExportSettings
        /// Absent in documents saved before scattering was modelled.
        var diffuseRays: Int?
        var randomSeed: UInt64?
        var lowFrequencyModel: Bool?
        var crossoverFrequency: Double?
    }

    static let resultWAV = "results/response.wav"
    static let resultMetadata = "results/response.json"

    // MARK: - Reading and writing

    public init(archive: ProjectArchive) throws {
        try archive.validate()
        guard archive.manifest.documentType == Self.documentType else {
            throw ProjectFileError.invalid(
                "This project belongs to \(archive.manifest.documentType), not RoomCAD.")
        }
        let decoder = JSONDecoder()
        let scene = try decoder.decode(Scene.self, from: archive.files["scene.json"]!)
        let stored = try decoder.decode(Settings.self, from: archive.files["settings.json"]!)
        guard scene.format == Scene.formatIdentifier, stored.format == Settings.formatIdentifier else {
            throw ProjectFileError.invalid("The room or its settings are not in RoomCAD's format.")
        }
        for version in [scene.encodingVersion, stored.encodingVersion] where version != 1 {
            throw ProjectFileError.unsupportedVersion(version)
        }
        settings = RoomResponseSettings(
            room: scene.room, source: scene.source, receivers: scene.receivers, atmosphere: stored.atmosphere,
            airAbsorption: stored.airAbsorption, sampleRate: stored.sampleRate, duration: stored.duration,
            maximumReflectionOrder: stored.maximumReflectionOrder, content: stored.content,
            lowFrequencyCutoff: stored.lowFrequencyCutoff, diffuseRays: stored.diffuseRays ?? 40_000,
            randomSeed: stored.randomSeed ?? 1, lowFrequencyModel: stored.lowFrequencyModel ?? false,
            crossoverFrequency: stored.crossoverFrequency, openings: scene.openings ?? [])
        do {
            try settings.validate()
        } catch {
            throw ProjectFileError.invalid("The room is invalid: \(error.localizedDescription)")
        }
        export = stored.export
        try export.validate()
        guard Set(([settings.source] + settings.receivers).map(\.id)).count == settings.receivers.count + 1
        else { throw ProjectFileError.invalid("The source and receivers need distinct identities.") }

        if let wav = archive.files[Self.resultWAV], let metadata = archive.files[Self.resultMetadata] {
            do {
                result = try RoomResponse(wav: wav, metadata: metadata)
            } catch {
                throw ProjectFileError.invalid(
                    "The retained response is unreadable: \(error.localizedDescription)")
            }
        } else if archive.files[Self.resultWAV] != nil || archive.files[Self.resultMetadata] != nil {
            throw ProjectFileError.invalid("The retained response is missing its audio or its description.")
        }
        documentID = archive.manifest.documentID
        manifest = archive.manifest
        let interpreted: Set<String> = ["scene.json", "settings.json", Self.resultWAV, Self.resultMetadata]
        preserved = archive.files.filter { !interpreted.contains($0.key) }
    }

    /// Whether `makeArchive` will include the retained response.
    public var retainsResult: Bool {
        guard let result else { return false }
        return result.response.frameCount * result.response.channels.count * 4 <= Self.maximumRetainedBytes
    }

    public func makeArchive() throws -> ProjectArchive {
        try settings.validate()
        try export.validate()
        var files = preserved
        let scene = Scene(
            room: settings.room, source: settings.source, receivers: settings.receivers,
            openings: settings.openings.isEmpty ? nil : settings.openings)
        files["scene.json"] = try ProjectArchive.encodeJSON(scene)
        files["settings.json"] = try ProjectArchive.encodeJSON(
            Settings(
                atmosphere: settings.atmosphere, airAbsorption: settings.airAbsorption,
                sampleRate: settings.sampleRate, duration: settings.duration,
                maximumReflectionOrder: settings.maximumReflectionOrder, content: settings.content,
                lowFrequencyCutoff: settings.lowFrequencyCutoff, export: export,
                diffuseRays: settings.diffuseRays, randomSeed: settings.randomSeed,
                lowFrequencyModel: settings.lowFrequencyModel, crossoverFrequency: settings.crossoverFrequency
            ))
        if let result, retainsResult {
            let encoded = try result.encoded()
            files[Self.resultWAV] = encoded.wav
            files[Self.resultMetadata] = encoded.metadata
        }
        var manifest =
            manifest
            ?? ProjectManifest(
                documentType: Self.documentType, producer: Self.producer, documentID: documentID)
        manifest.documentID = documentID
        return try ProjectArchive(manifest: manifest, files: files)
    }

    public static func == (lhs: RoomProject, rhs: RoomProject) -> Bool {
        lhs.documentID == rhs.documentID && lhs.settings == rhs.settings && lhs.export == rhs.export
            && lhs.result?.response == rhs.result?.response && lhs.result?.settings == rhs.result?.settings
            && lhs.preserved == rhs.preserved
    }
}
