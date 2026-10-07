import Foundation
import ImpulseResponseKit
import simd

/// A point in the room with a stable identity.
public struct RoomPoint: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Position in metres from the room's west, south, floor corner.
    public var position: SIMD3<Double>

    public init(id: UUID = UUID(), name: String, position: SIMD3<Double>) {
        self.id = id
        self.name = name
        self.position = position
    }
}

/// Everything needed to reproduce a room response.
public struct RoomResponseSettings: Codable, Equatable, Sendable {
    public var room: ShoeboxRoom
    /// An omnidirectional point source.
    public var source: RoomPoint
    /// Omnidirectional point receivers, one output channel each. Two receivers give a mono-to-stereo
    /// response.
    public var receivers: [RoomPoint]
    public var atmosphere: Atmosphere
    public var airAbsorption: Bool
    public var sampleRate: Int
    /// Arrivals later than this many seconds after emission are omitted.
    public var duration: Double
    /// Reflections above this order are omitted; see `RoomResponseDiagnostics.orderLimitedAfter`.
    public var maximumReflectionOrder: Int
    public var content: ResponseMetadata.Content
    /// Content above this frequency in Hz is kept and content below half of it removed; 0 keeps the raw
    /// model. Because every reflection is
    /// modelled as real and positive, the raw response accumulates a slowly decaying offset below the
    /// lowest room mode that is outside the usable band and would offset a convolution reverb.
    public var lowFrequencyCutoff: Double

    /// Upper bound on the estimated number of image sources per receiver.
    public static let maximumImageCount = 40_000_000
    /// Closest permitted approach of a receiver to the source.
    public static let minimumSeparation = 0.05

    public init(
        room: ShoeboxRoom, source: RoomPoint, receivers: [RoomPoint], atmosphere: Atmosphere = .standard,
        airAbsorption: Bool = true, sampleRate: Int = 48_000, duration: Double = 1,
        maximumReflectionOrder: Int = 60, content: ResponseMetadata.Content = .complete,
        lowFrequencyCutoff: Double = 20
    ) {
        self.room = room
        self.source = source
        self.receivers = receivers
        self.atmosphere = atmosphere
        self.airAbsorption = airAbsorption
        self.sampleRate = sampleRate
        self.duration = duration
        self.maximumReflectionOrder = maximumReflectionOrder
        self.content = content
        self.lowFrequencyCutoff = lowFrequencyCutoff
    }

    /// Estimated image sources per receiver within the duration and order limits.
    public var estimatedImageCount: Double {
        let reach = duration * atmosphere.soundSpeed
        let withinReach = 4 / 3 * Double.pi * reach * reach * reach / room.volume
        let order = Double(maximumReflectionOrder)
        let withinOrder = 4 / 3 * order * order * order + 2 * order * order + 8 / 3 * order + 1
        return min(withinReach, withinOrder)
    }

    public func validate() throws {
        try room.validate()
        try atmosphere.validate()
        guard (8_000...384_000).contains(sampleRate) else {
            throw AcousticError.invalid("The sample rate must be between 8 kHz and 384 kHz.")
        }
        guard duration.isFinite, duration > 0, duration <= 30 else {
            throw AcousticError.invalid("The duration must be between 0 and 30 seconds.")
        }
        guard lowFrequencyCutoff == 0 || (5...200).contains(lowFrequencyCutoff) else {
            throw AcousticError.invalid("The low-frequency cutoff must be 0 (off) or between 5 and 200 Hz.")
        }
        guard (0...1_000).contains(maximumReflectionOrder) else {
            throw AcousticError.invalid("The maximum reflection order must be between 0 and 1000.")
        }
        guard (1...16).contains(receivers.count) else {
            throw AcousticError.invalid("A response needs between 1 and 16 receivers.")
        }
        for point in [source] + receivers where !room.contains(point.position) {
            throw AcousticError.invalid("\(point.name) is not inside the room.")
        }
        for receiver in receivers
        where simd_distance(receiver.position, source.position) < Self.minimumSeparation {
            throw AcousticError.invalid(
                "\(receiver.name) must be at least \(Self.minimumSeparation) m from the source.")
        }
        guard estimatedImageCount <= Double(Self.maximumImageCount) else {
            throw AcousticError.invalid(
                "About \(Int(estimatedImageCount)) image sources per receiver; shorten the duration or "
                    + "lower the maximum reflection order.")
        }
    }
}

/// Measured facts about a generated response, saved beside it.
public struct RoomResponseDiagnostics: Codable, Equatable, Sendable {
    public var soundSpeed: Double
    public var bandCentres: [Double]
    /// Per receiver: arrivals rendered.
    public var arrivals: [Int]
    /// Per receiver: direct-path delay in seconds.
    public var directDelay: [Double]
    /// Per receiver: time in seconds after which reflections above the maximum order are missing, or
    /// nil if the order limit removed nothing within the duration.
    public var orderLimitedAfter: [Double?]
    /// Statistical estimates per band, for comparison; not measured from the response.
    public var sabineReverberationTime: [Double?]
    public var eyringReverberationTime: [Double?]
    /// `2000 sqrt(T/V)` with the mean Sabine time of the 500 Hz and 1 kHz bands. Below it, room modes are
    /// sparse and the geometrical model is approximate.
    public var schroederFrequency: Double?
    public var generationSeconds: Double
}

/// A generated response together with the settings that produced it.
public struct RoomResponse: Sendable {
    public var response: ImpulseResponse
    public var settings: RoomResponseSettings
    public var diagnostics: RoomResponseDiagnostics

    public static let generatorName = "RoomCAD image-source model 1"

    public static let assumptions = [
        "Rectangular room, specular reflections only (image-source method); no diffraction or scattering.",
        "Pressure reflection coefficient sqrt(1 - alpha) per octave band, real and positive (no phase shift), "
            + "independent of the angle of incidence.",
        "Absorption and air attenuation blend smoothly between octave-band centres; air attenuation uses "
            + "ISO 9613-1 at each band centre, so it is underestimated above about 11 kHz.",
        "Omnidirectional point source and receivers.",
        "Arrivals after the duration and reflections above the maximum order are omitted; no late tail is "
            + "synthesized.",
        "Zero-phase band filters can spread small pre-echoes ahead of an arrival whose band gains differ.",
        "A zero-phase high-pass at the low-frequency cutoff, if set, removes the sub-audio offset that real, "
            + "positive reflection coefficients accumulate.",
    ]

    /// Writes the response as WAV with a JSON description that includes these settings and diagnostics.
    public func write(wav url: URL) throws {
        try response.write(wav: url, generatorDetails: Details(settings: settings, diagnostics: diagnostics))
    }

    /// What a response's JSON description stores under `generatorDetails`.
    public struct Details: Codable, Sendable {
        public var settings: RoomResponseSettings
        public var diagnostics: RoomResponseDiagnostics

        public init(settings: RoomResponseSettings, diagnostics: RoomResponseDiagnostics) {
            self.settings = settings
            self.diagnostics = diagnostics
        }
    }

    public init(
        response: ImpulseResponse, settings: RoomResponseSettings, diagnostics: RoomResponseDiagnostics
    ) {
        self.response = response
        self.settings = settings
        self.diagnostics = diagnostics
    }

    /// WAV and JSON data as `write(wav:)` stores them.
    public func encoded() throws -> (wav: Data, metadata: Data) {
        try response.encoded(generatorDetails: Details(settings: settings, diagnostics: diagnostics))
    }

    /// Decodes data from `encoded()`, rejecting responses from another generator.
    public init(wav: Data, metadata: Data) throws {
        let response = try ImpulseResponse(wav: wav, metadata: metadata)
        guard response.metadata.generator == Self.generatorName,
            let details = try ImpulseResponse.generatorDetails(Details.self, from: metadata)
        else {
            throw AcousticError.invalid("The response was not generated by \(Self.generatorName).")
        }
        guard details.settings.receivers.count == response.channels.count,
            details.settings.sampleRate == response.sampleRate
        else {
            throw AcousticError.invalid("The response does not match its recorded settings.")
        }
        self.init(response: response, settings: details.settings, diagnostics: details.diagnostics)
    }
}

public enum RoomResponseGenerator {
    /// Generates one channel per receiver: the room's response to an impulse emitted by the source at
    /// frame 0, as pressure relative to the free-field pressure 1 m from the source.
    ///
    /// Throws `CancellationError` if the calling task is cancelled.
    public static func generate(_ settings: RoomResponseSettings) throws -> RoomResponse {
        try settings.validate()
        let start = Date()
        let model = ImageSourceModel(
            room: settings.room, source: settings.source.position, atmosphere: settings.atmosphere,
            airAbsorption: settings.airAbsorption)
        let frames = Int((settings.duration * Double(settings.sampleRate)).rounded(.up))
        let includeDirect = settings.content == .complete
        var channels: [[Float]] = []
        var arrivals: [Int] = []
        var orderLimitedAfter: [Double?] = []
        for receiver in settings.receivers {
            var renderer = BandRenderer(
                sampleRate: settings.sampleRate, frames: frames,
                lowFrequencyCutoff: settings.lowFrequencyCutoff)
            let cancelled = { Task.isCancelled }
            let summary = model.forEachArrival(
                at: receiver.position, duration: settings.duration,
                maximumOrder: settings.maximumReflectionOrder, includeDirect: includeDirect, stop: cancelled
            ) { delay, _, gains in
                renderer.add(delay: delay, gains: gains)
            }
            try Task.checkCancellation()
            channels.append(renderer.render())
            arrivals.append(summary.arrivals)
            orderLimitedAfter.append(summary.orderLimitedAfter)
        }

        let c = settings.atmosphere.soundSpeed
        let sabine = settings.room.sabineReverberationTime(
            atmosphere: settings.atmosphere, airAbsorption: settings.airAbsorption)
        let eyring = settings.room.eyringReverberationTime(
            atmosphere: settings.atmosphere, airAbsorption: settings.airAbsorption)
        var schroeder: Double?
        if let t500 = sabine[3], let t1000 = sabine[4] {
            schroeder = 2000 * ((t500 + t1000) / 2 / settings.room.volume).squareRoot()
        }
        let diagnostics = RoomResponseDiagnostics(
            soundSpeed: c, bandCentres: OctaveBands.centres, arrivals: arrivals,
            directDelay: settings.receivers.map { simd_distance($0.position, settings.source.position) / c },
            orderLimitedAfter: orderLimitedAfter, sabineReverberationTime: sabine,
            eyringReverberationTime: eyring, schroederFrequency: schroeder,
            generationSeconds: Date().timeIntervalSince(start))

        let metadata = ResponseMetadata(
            sampleRate: settings.sampleRate, frameCount: frames,
            channels: settings.receivers.map {
                .init(
                    name: $0.name, sourceID: settings.source.id, receiverID: $0.id,
                    receiverPosition: [$0.position.x, $0.position.y, $0.position.z])
            },
            content: settings.content,
            gainConvention:
                "Each arrival is a band-limited impulse whose samples sum to its sound pressure relative to "
                + "the free-field pressure 1 m from the source.",
            usableBand: .init(
                lowerHz: max(settings.lowFrequencyCutoff, 20),
                upperHz: BandRenderer.passbandFraction * Double(settings.sampleRate)),
            approximateBelowHz: schroeder,
            model: "Geometrical acoustics (image-source method); low-frequency behaviour is approximate.",
            assumptions: RoomResponse.assumptions, generator: RoomResponse.generatorName)
        return RoomResponse(
            response: try ImpulseResponse(channels: channels, metadata: metadata), settings: settings,
            diagnostics: diagnostics)
    }
}
