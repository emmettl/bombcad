import Foundation
import ImpulseResponseKit
import Synchronization
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
    /// The most rays traced from the source for the scattered energy; fewer are traced in rooms where
    /// fewer suffice. Unused if no surface scatters.
    public var diffuseRays: Int
    /// Seed for the ray directions and the diffuse tail's random detail, so a response can be reproduced.
    public var randomSeed: UInt64

    /// Upper bound on the estimated number of image sources per receiver.
    public static let maximumImageCount = 40_000_000
    /// Closest permitted approach of a receiver to the source.
    public static let minimumSeparation = 0.05

    public init(
        room: ShoeboxRoom, source: RoomPoint, receivers: [RoomPoint], atmosphere: Atmosphere = .standard,
        airAbsorption: Bool = true, sampleRate: Int = 48_000, duration: Double = 1,
        maximumReflectionOrder: Int = 60, content: ResponseMetadata.Content = .complete,
        lowFrequencyCutoff: Double = 20, diffuseRays: Int = 40_000, randomSeed: UInt64 = 1
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
        self.diffuseRays = diffuseRays
        self.randomSeed = randomSeed
    }

    enum CodingKeys: String, CodingKey {
        case room, source, receivers, atmosphere, airAbsorption, sampleRate, duration, maximumReflectionOrder
        case content, lowFrequencyCutoff, diffuseRays, randomSeed
    }

    /// Settings saved before scattering existed decode with its defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            room: try c.decode(ShoeboxRoom.self, forKey: .room),
            source: try c.decode(RoomPoint.self, forKey: .source),
            receivers: try c.decode([RoomPoint].self, forKey: .receivers),
            atmosphere: try c.decode(Atmosphere.self, forKey: .atmosphere),
            airAbsorption: try c.decode(Bool.self, forKey: .airAbsorption),
            sampleRate: try c.decode(Int.self, forKey: .sampleRate),
            duration: try c.decode(Double.self, forKey: .duration),
            maximumReflectionOrder: try c.decode(Int.self, forKey: .maximumReflectionOrder),
            content: try c.decode(ResponseMetadata.Content.self, forKey: .content),
            lowFrequencyCutoff: try c.decode(Double.self, forKey: .lowFrequencyCutoff),
            diffuseRays: try c.decodeIfPresent(Int.self, forKey: .diffuseRays) ?? 40_000,
            randomSeed: try c.decodeIfPresent(UInt64.self, forKey: .randomSeed) ?? 1)
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
        guard (1_000...1_000_000).contains(diffuseRays) else {
            throw AcousticError.invalid("The number of diffuse rays must be between 1,000 and 1,000,000.")
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
    /// Per receiver: the fraction of the response's energy from 500 Hz to 4 kHz that was scattered at
    /// least once. Nil for responses made before scattering was modelled.
    public var scatteredFraction: [Double]?
    /// Rays traced for the scattered energy; zero when no surface scatters.
    public var diffuseRays: Int?
}

/// A generated response together with the settings that produced it.
public struct RoomResponse: Sendable {
    public var response: ImpulseResponse
    public var settings: RoomResponseSettings
    public var diagnostics: RoomResponseDiagnostics

    public static let generatorName = "RoomCAD hybrid model 3"
    /// Generators whose saved responses can still be read; only the current one is up to date.
    public static let readableGenerators: Set<String> = [
        "RoomCAD image-source model 1", "RoomCAD hybrid model 2", generatorName,
    ]

    public static let assumptions = [
        "Rectangular room. Specular reflections by the image-source method; energy scattered at least once by "
            + "ray tracing with Lambert (cosine) reflection, rendered as a dense random reflection pattern with "
            + "that energy envelope. No diffraction.",
        "Each reflection keeps (1 - alpha) of the energy, of which a fraction s (the scattering coefficient) "
            + "leaves diffusely and the rest specularly.",
        "Specular pressure reflection coefficient sqrt((1 - alpha)(1 - s)) per octave band, real and positive "
            + "(no phase shift), independent of the angle of incidence.",
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
        guard Self.readableGenerators.contains(response.metadata.generator),
            let details = try ImpulseResponse.generatorDetails(Details.self, from: metadata)
        else {
            throw AcousticError.invalid("The response was not generated by RoomCAD.")
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
    /// The work runs on several cores. Throws `CancellationError` if the calling task is cancelled.
    public static func generate(_ settings: RoomResponseSettings) async throws -> RoomResponse {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try generate(settings, cancellation: flag)
        } onCancel: {
            flag.cancel()
        }
    }

    /// The diffuse tail's seed for one receiver, from its identity, so its channel does not change when
    /// other receivers are added, removed or reordered.
    static func tailSeed(_ seed: UInt64, receiver: UUID) -> UInt64 {
        var mix = SplitMix(seed: seed)
        var value = mix.next()
        withUnsafeBytes(of: receiver.uuid) { bytes in
            for byte in bytes {
                mix = SplitMix(seed: value ^ UInt64(byte))
                value = mix.next()
            }
        }
        return value
    }

    /// Generates synchronously; `cancellation`, or cancelling the calling task, stops it.
    public static func generate(
        _ settings: RoomResponseSettings, cancellation: CancellationFlag = CancellationFlag()
    ) throws -> RoomResponse {
        try settings.validate()
        let start = Date()
        // Worker threads cannot see the task, so the calling thread passes its cancellation on.
        let cancelled: @Sendable () -> Bool = {
            if Task.isCancelled { cancellation.cancel() }
            return cancellation.isCancelled
        }
        func check() throws { if cancelled() { throw CancellationError() } }
        let model = ImageSourceModel(
            room: settings.room, source: settings.source.position, atmosphere: settings.atmosphere,
            airAbsorption: settings.airAbsorption)
        let frames = Int((settings.duration * Double(settings.sampleRate)).rounded(.up))
        let includeDirect = settings.content == .complete
        let tracer = DiffuseRayTracer(
            room: settings.room, source: settings.source.position, atmosphere: settings.atmosphere,
            airAbsorption: settings.airAbsorption, rayCount: settings.diffuseRays, seed: settings.randomSeed)
        let diffuse = tracer.trace(
            receivers: settings.receivers.map(\.position), duration: settings.duration, stop: cancelled)
        try check()
        // The bands whose energy the scattered fraction reports, 500 Hz to 4 kHz.
        let reported = 3...6

        // Receivers are independent, so each renders on its own core.
        struct Channel {
            var samples: [Float]
            var arrivals: Int
            var orderLimitedAfter: Double?
            var scatteredFraction: Double
        }
        let results = ChunkResults<Channel>(count: settings.receivers.count)
        DispatchQueue.concurrentPerform(iterations: settings.receivers.count) { index in
            guard !cancelled() else { return }
            var renderer = BandRenderer(
                sampleRate: settings.sampleRate, frames: frames,
                lowFrequencyCutoff: settings.lowFrequencyCutoff)
            var specularEnergy = 0.0
            let summary = model.forEachArrival(
                at: settings.receivers[index].position, duration: settings.duration,
                maximumOrder: settings.maximumReflectionOrder, includeDirect: includeDirect, stop: cancelled
            ) { delay, _, gains in
                renderer.add(delay: delay, gains: gains)
                for b in reported { specularEnergy += gains[b] * gains[b] }
            }
            guard !cancelled() else { return }
            let diffuseEnergy = DiffuseTail.render(
                diffuse[index], into: &renderer, roomVolume: settings.room.volume,
                soundSpeed: settings.atmosphere.soundSpeed,
                seed: Self.tailSeed(settings.randomSeed, receiver: settings.receivers[index].id),
                bands: reported)
            let total = specularEnergy + diffuseEnergy
            results.store(
                Channel(
                    samples: renderer.render(), arrivals: summary.arrivals,
                    orderLimitedAfter: summary.orderLimitedAfter,
                    scatteredFraction: total > 0 ? diffuseEnergy / total : 0),
                at: index)
        }
        try check()
        let rendered = results.values
        let channels = rendered.map(\.samples)
        let arrivals = rendered.map(\.arrivals)
        let orderLimitedAfter = rendered.map(\.orderLimitedAfter)
        let scatteredFraction = rendered.map(\.scatteredFraction)

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
            generationSeconds: Date().timeIntervalSince(start), scatteredFraction: scatteredFraction,
            diffuseRays: settings.room.scatters ? tracer.tracedRays : 0)

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
            model:
                "Geometrical acoustics (image sources for specular paths, ray tracing for scattered energy); "
                + "low-frequency behaviour is approximate.",
            assumptions: RoomResponse.assumptions, generator: RoomResponse.generatorName)
        return RoomResponse(
            response: try ImpulseResponse(channels: channels, metadata: metadata), settings: settings,
            diagnostics: diagnostics)
    }
}

/// A cancellation request that worker threads can see.
public final class CancellationFlag: Sendable {
    private let state = Atomic<Bool>(false)

    public init() {}

    public func cancel() { state.store(true, ordering: .relaxed) }

    public var isCancelled: Bool { state.load(ordering: .relaxed) }
}
