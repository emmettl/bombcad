import Foundation

public enum ImpulseResponseError: LocalizedError, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

/// Describes a sampled response independently of the model that generated it.
///
/// This is the interchange contract for convolution engines. It deliberately knows nothing about
/// rooms or solvers; generators add their own settings beside it.
public struct ResponseMetadata: Codable, Equatable, Sendable {
    public static let formatIdentifier = "dev.roomcad.impulse-response"
    public static let currentVersion = 1

    public enum Content: String, Codable, Sendable {
        /// Direct sound and every modelled reflection.
        case complete
        /// The direct path is omitted; reflection timing is unchanged.
        case reflectionsOnly
    }

    /// One output channel: the response at one receiver to one source.
    public struct Channel: Codable, Equatable, Sendable {
        public var name: String
        public var sourceID: UUID
        public var receiverID: UUID
        /// Receiver position in metres, z up, when the generator has one.
        public var receiverPosition: [Double]?
        /// The receiver's directivity and aim, in words, when it is not omnidirectional.
        public var directivity: String?

        public init(
            name: String, sourceID: UUID, receiverID: UUID, receiverPosition: [Double]? = nil,
            directivity: String? = nil
        ) {
            self.name = name
            self.sourceID = sourceID
            self.receiverID = receiverID
            self.receiverPosition = receiverPosition
            self.directivity = directivity
        }
    }

    public struct Band: Codable, Equatable, Sendable {
        public var lowerHz: Double
        public var upperHz: Double

        public init(lowerHz: Double, upperHz: Double) {
            self.lowerHz = lowerHz
            self.upperHz = upperHz
        }
    }

    /// A conditioning step applied after generation, in order.
    public struct Step: Codable, Equatable, Sendable {
        public var kind: String
        public var value: Double
        public var detail: String

        public init(kind: String, value: Double, detail: String) {
            self.kind = kind
            self.value = value
            self.detail = detail
        }
    }

    public var format = Self.formatIdentifier
    public var encodingVersion = Self.currentVersion
    public var sampleRate: Int
    public var frameCount: Int
    public var channels: [Channel]
    public var content: Content
    /// Frame at which the source emits. Zero for an untrimmed response, so frame `n` is `n / sampleRate`
    /// seconds after emission; negative after leading delay has been removed.
    public var emissionFrame: Int
    /// What a sample value of 1 means before `commonGain` is applied.
    public var gainConvention: String
    /// Gain applied equally to every channel after generation; relative channel levels are unchanged.
    public var commonGain: Double
    /// Band over which the model and sampling are intended to be meaningful.
    public var usableBand: Band
    /// Below this frequency the model's behaviour is approximate, if the generator can estimate it.
    public var approximateBelowHz: Double?
    public var model: String
    public var assumptions: [String]
    public var processing: [Step]
    public var generator: String

    public init(
        sampleRate: Int, frameCount: Int, channels: [Channel], content: Content, gainConvention: String,
        usableBand: Band, approximateBelowHz: Double? = nil, model: String, assumptions: [String],
        generator: String
    ) {
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.channels = channels
        self.content = content
        emissionFrame = 0
        self.gainConvention = gainConvention
        commonGain = 1
        self.usableBand = usableBand
        self.approximateBelowHz = approximateBelowHz
        self.model = model
        self.assumptions = assumptions
        processing = []
        self.generator = generator
    }
}

/// Sampled multichannel response with its description.
public struct ImpulseResponse: Equatable, Sendable {
    /// One array per channel, all the same length.
    public private(set) var channels: [[Float]]
    public private(set) var metadata: ResponseMetadata

    public init(channels: [[Float]], metadata: ResponseMetadata) throws {
        guard !channels.isEmpty, channels.count == metadata.channels.count else {
            throw ImpulseResponseError.invalid("The response needs one sample array per described channel.")
        }
        guard let frames = channels.first?.count, channels.allSatisfy({ $0.count == frames }) else {
            throw ImpulseResponseError.invalid("All channels must have the same length.")
        }
        guard metadata.sampleRate > 0 else {
            throw ImpulseResponseError.invalid("The sample rate must be positive.")
        }
        guard channels.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            throw ImpulseResponseError.invalid("The response contains non-finite samples.")
        }
        var metadata = metadata
        metadata.frameCount = frames
        self.channels = channels
        self.metadata = metadata
    }

    public var sampleRate: Int { metadata.sampleRate }
    public var frameCount: Int { metadata.frameCount }

    public var peak: Float {
        channels.map { $0.map(abs).max() ?? 0 }.max() ?? 0
    }

    // MARK: - Conditioning

    /// Scales every channel by one gain, keeping relative channel levels and timing.
    public mutating func applyCommonGain(_ gain: Double, detail: String) throws {
        guard gain.isFinite, gain > 0 else {
            throw ImpulseResponseError.invalid("A common gain must be finite and positive.")
        }
        let factor = Float(gain)
        channels = channels.map { $0.map { $0 * factor } }
        metadata.commonGain *= gain
        metadata.processing.append(.init(kind: "commonGain", value: gain, detail: detail))
    }

    /// Scales all channels together so the largest absolute sample equals `target`.
    public mutating func normalizePeak(to target: Float) throws {
        let current = peak
        guard current > 0 else { return }
        try applyCommonGain(
            Double(target / current), detail: "Peak normalized to \(target) across all channels")
    }

    /// Removes the same number of leading frames from every channel.
    public mutating func removeLeadingFrames(_ frames: Int) throws {
        guard frames >= 0, frames < frameCount else {
            throw ImpulseResponseError.invalid("Cannot remove \(frames) of \(frameCount) frames.")
        }
        guard frames > 0 else { return }
        channels = channels.map { Array($0[frames...]) }
        metadata.frameCount -= frames
        metadata.emissionFrame -= frames
        metadata.processing.append(
            .init(
                kind: "removeLeadingFrames", value: Double(frames),
                detail: "Common leading delay removed; emission is now at frame \(metadata.emissionFrame)"))
    }

    /// Applies a half-cosine fade to the final `seconds` of every channel.
    public mutating func fadeOut(seconds: Double) throws {
        guard seconds.isFinite, seconds >= 0 else {
            throw ImpulseResponseError.invalid("A fade length must be finite and non-negative.")
        }
        let length = min(Int((seconds * Double(sampleRate)).rounded()), frameCount)
        guard length > 0 else { return }
        let start = frameCount - length
        channels = channels.map { samples in
            var faded = samples
            for i in 0..<length {
                let phase = Double(i + 1) / Double(length)
                faded[start + i] *= Float(0.5 + 0.5 * cos(Double.pi * phase))
            }
            return faded
        }
        metadata.processing.append(
            .init(kind: "fadeOut", value: seconds, detail: "Half-cosine fade over the final \(length) frames")
        )
    }

    // MARK: - Files

    /// The response as 32-bit float WAV and its metadata as JSON.
    ///
    /// Generator-specific settings and diagnostics go under the `generatorDetails` key, which readers of
    /// the interchange contract may ignore.
    public func encoded(generatorDetails: (any Encodable)? = nil) throws -> (wav: Data, metadata: Data) {
        let wav = try WAVFile.encode(channels: channels, sampleRate: sampleRate)
        let encoder = Self.encoder
        var json = try encoder.encode(metadata)
        if let generatorDetails {
            guard var object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
                throw ImpulseResponseError.invalid("The metadata did not encode as a JSON object.")
            }
            object["generatorDetails"] = try JSONSerialization.jsonObject(
                with: encoder.encode(generatorDetails))
            json = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        }
        return (wav, json)
    }

    /// Decodes a response from WAV data and the metadata that describes it.
    public init(wav: Data, metadata json: Data) throws {
        let audio = try WAVFile.decode(wav)
        let metadata = try JSONDecoder().decode(ResponseMetadata.self, from: json)
        guard metadata.format == ResponseMetadata.formatIdentifier else {
            throw ImpulseResponseError.invalid("The metadata is not an impulse-response description.")
        }
        guard metadata.encodingVersion <= ResponseMetadata.currentVersion else {
            throw ImpulseResponseError.invalid(
                "The metadata uses version \(metadata.encodingVersion); this reader supports version 1.")
        }
        guard audio.sampleRate == metadata.sampleRate, audio.channels.count == metadata.channels.count,
            audio.channels.first?.count == metadata.frameCount
        else {
            throw ImpulseResponseError.invalid("The WAV file does not match its metadata.")
        }
        try self.init(channels: audio.channels, metadata: metadata)
    }

    /// The `generatorDetails` stored in metadata JSON, if present.
    public static func generatorDetails<Details: Decodable>(
        _ type: Details.Type, from metadata: Data
    ) throws -> Details? {
        try JSONDecoder().decode(GeneratorDetailsWrapper<Details>.self, from: metadata).generatorDetails
    }

    /// Writes the response as 32-bit float WAV and its metadata as a JSON file beside it.
    public func write(wav url: URL, generatorDetails: (any Encodable)? = nil) throws {
        let files = try encoded(generatorDetails: generatorDetails)
        try files.wav.write(to: url, options: .atomic)
        try files.metadata.write(to: Self.metadataURL(for: url), options: .atomic)
    }

    /// Reads a WAV written by `write(wav:)` and its metadata.
    public static func read(wav url: URL) throws -> ImpulseResponse {
        try ImpulseResponse(wav: Data(contentsOf: url), metadata: Data(contentsOf: metadataURL(for: url)))
    }

    public static func metadataURL(for wav: URL) -> URL {
        wav.deletingPathExtension().appendingPathExtension("json")
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private struct GeneratorDetailsWrapper<Details: Decodable>: Decodable {
    var generatorDetails: Details?
}
