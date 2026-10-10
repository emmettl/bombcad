import BlastCore
import DocumentKit
import Foundation

/// A model fed by the blast a frame at a time, one way, here or on another Mac: what it is and
/// what it needs to start.
enum ConsumerKind: Codable, Sendable, Equatable {
    /// A cased charge's fragments and tracers, flown through blocks of the air.
    case fragments(FragmentSpec, FragmentScene, live: Bool)
    /// The fireball's radiation on the scene's surfaces.
    case thermal(ThermalSpec, FragmentScene, live: Bool)
    /// The ground's shaking under chosen points.
    case groundShock(GroundShockSpec, live: Bool)

    /// Whether the model's state comes back after each frame, for the app to draw (see
    /// `ConsumerLive`).
    var isLive: Bool {
        switch self {
        case .fragments(_, _, let live), .thermal(_, _, let live), .groundShock(_, let live): live
        }
    }

    var name: String {
        switch self {
        case .fragments: "fragments"
        case .thermal: "thermal radiation"
        case .groundShock: "ground shock"
        }
    }
}

/// One frame's input to a consumer, as its kind takes it.
enum ConsumerInput: Sendable, Equatable {
    case air(AirSlice)
    case fireball(FireballFrame)
    case ground(GroundSlice)

    /// What travels as JSON; the samples, if any, go as the payload.
    enum Header: Codable, Sendable, Equatable {
        case air(AirSlice.Header)
        case fireball(FireballFrame)
        case ground(GroundSlice.Header)
    }

    var header: Header {
        switch self {
        case .air(let slice): .air(slice.header)
        // The cells, megabytes once the fireball fills a street, go as the payload.
        case .fireball(let frame): .fireball(frame.withoutCells)
        case .ground(let slice): .ground(slice.header)
        }
    }

    var payload: Data {
        switch self {
        case .air(let slice): slice.payload
        case .fireball(let frame): frame.cells?.binary ?? Data()
        case .ground(let slice): slice.payload
        }
    }

    /// The moment of the frame.
    var time: Double {
        switch self {
        case .air(let slice): slice.time
        case .fireball(let frame): frame.time
        case .ground(let slice): slice.time
        }
    }

    /// The samples' size, without copying them.
    var byteCount: Int {
        switch self {
        case .air(let slice): 2 * slice.values.count
        case .fireball(let frame): frame.cells.map { $0.fills.count * ($0.products == nil ? 3 : 5) } ?? 0
        case .ground(let slice): 4 * slice.values.count
        }
    }

    init(header: Header, payload: Data) throws {
        switch header {
        case .air(let header): self = .air(try AirSlice(header: header, payload: payload))
        case .fireball(var frame):
            frame.cells = payload.isEmpty ? nil : try LuminousCells(binary: payload)
            self = .fireball(frame)
        case .ground(let header): self = .ground(try GroundSlice(header: header, payload: payload))
        }
    }
}

/// What a consumer found, once every frame is in.
enum ConsumerOutcome: Codable, Sendable, Equatable {
    case fragments(FragmentResult)
    case thermal(ThermalResult)
    case groundShock(GroundShockResult)

    /// As it travels: the JSON's length, the JSON, then any binary part (the fragments'
    /// trajectories, which JSON would swamp).
    func encoded() throws -> Data {
        let json = try JSONEncoder().encode(self)
        var length = UInt32(json.count).bigEndian
        var data = Data(bytes: &length, count: 4) + json
        if case .fragments(let result) = self { data += result.trajectoryData }
        return data
    }

    init(encoded data: Data) throws {
        guard data.count >= 4 else { throw ProjectFileError.invalid("A consumer's result was cut short.") }
        let length = Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard data.count >= 4 + length else {
            throw ProjectFileError.invalid("A consumer's result was cut short.")
        }
        let start = data.startIndex
        self = try JSONDecoder().decode(Self.self, from: data.subdata(in: start + 4..<start + 4 + length))
        if case .fragments(var result) = self {
            try result.setTrajectories(data.subdata(in: start + 4 + length..<data.endIndex))
            self = .fragments(result)
        }
    }
}

/// A consumer's model and the frames it has taken, the same here and on a worker, so that its
/// result does not depend on where it ran.
struct ConsumerEngine: Sendable {
    private enum Model: Sendable {
        case fragments(FragmentConsumer, live: Bool)
        case thermal(ThermalExposure)
        case groundShock(GroundShockConsumer)
    }
    private var model: Model
    /// The last frame taken, -1 before the first.
    private(set) var frame = -1
    let kind: ConsumerKind

    init(_ kind: ConsumerKind) {
        self.kind = kind
        switch kind {
        case .fragments(let spec, let scene, let live):
            model = .fragments(FragmentConsumer(spec: spec, scene: scene, keepsFrames: !live), live: live)
        case .thermal(let spec, let scene, _):
            model = .thermal(ThermalExposure(spec: spec, scene: scene))
        case .groundShock(let spec, _):
            model = .groundShock(GroundShockConsumer(spec: spec))
        }
    }

    /// Takes the next frame's input, which must be of the kind the model takes.
    mutating func consume(_ input: ConsumerInput) throws {
        switch (model, input) {
        case (.fragments(var consumer, let live), .air(let slice)):
            consumer.consume(slice)
            model = .fragments(consumer, live: live)
        case (.thermal(var exposure), .fireball(let frame)):
            exposure.add(frame)
            model = .thermal(exposure)
        case (.groundShock(var consumer), .ground(let slice)):
            consumer.consume(slice)
            model = .groundShock(consumer)
        default:
            throw ProjectFileError.invalid("The \(kind.name) consumer was sent the wrong kind of frame.")
        }
        frame += 1
    }

    /// Where it has got: the frame, and for fragments the region of air the next frames need.
    var report: ConsumerReport {
        if case .fragments(let consumer, _) = model { return consumer.report }
        return ConsumerReport(frame: frame, low: nil, high: nil, speed: 0, airborne: 0)
    }

    /// The GPU's time on the model's frames so far, in seconds, if it uses the GPU: the thermal
    /// radiation's march through the fireball.
    var gpuSeconds: Double? {
        if case .thermal(let exposure) = model { return exposure.marchGPUSeconds }
        return nil
    }

    /// The model's state now, for a live view, if its kind is live; `time` is the last frame's.
    func live(time: Double) -> ConsumerLive? {
        guard kind.isLive else { return nil }
        switch model {
        case .fragments(let consumer, _): return .fragments(FragmentLive(consumer, time: time))
        case .thermal(let exposure): return .thermal(ThermalLive(exposure))
        case .groundShock(let consumer): return .groundShock(consumer.result(frameInterval: 0))
        }
    }

    func outcome(frameInterval: Double) -> ConsumerOutcome {
        switch model {
        case .fragments(let consumer, _): .fragments(consumer.result(frameInterval: frameInterval))
        case .thermal(let exposure): .thermal(exposure.result)
        case .groundShock(let consumer): .groundShock(consumer.result(frameInterval: frameInterval))
        }
    }
}

/// A model's state as of its last frame, for the app to draw while the run goes on: the fragments'
/// particles, the thermal radiation's receivers, or the ground points' estimates so far.
enum ConsumerLive: Sendable, Equatable {
    case fragments(FragmentLive)
    case thermal(ThermalLive)
    case groundShock(GroundShockResult)

    /// What travels after each frame as JSON; the particles' positions or the receivers' values go
    /// as the payload. The fragments' impacts travel as those new since the last frame.
    enum Header: Codable, Sendable, Equatable {
        case fragments(LiveFrameHeader)
        case thermal(ThermalLiveHeader)
        case groundShock(GroundShockResult)
    }

    var fragments: FragmentLive? { if case .fragments(let live) = self { live } else { nil } }
    var thermal: ThermalLive? { if case .thermal(let live) = self { live } else { nil } }
    var groundShock: GroundShockResult? { if case .groundShock(let live) = self { live } else { nil } }

    /// The header and payload to send, given the fragments' impacts already sent.
    func encoded(impactsSent: Int) -> (header: Header, payload: Data) {
        switch self {
        case .fragments(let live):
            (
                .fragments(
                    LiveFrameHeader(
                        time: live.time, fragmentCount: live.fragmentCount,
                        impacts: Array(live.impacts.dropFirst(impactsSent)))),
                live.payload
            )
        case .thermal(let live):
            (.thermal(ThermalLiveHeader(frames: live.frames, time: live.time)), live.payload)
        case .groundShock(let result): (.groundShock(result), Data())
        }
    }

    /// This state brought up to date by what came after a frame.
    func updated(by header: Header, payload: Data) throws -> ConsumerLive {
        switch (self, header) {
        case (.fragments(var live), .fragments(let header)):
            try live.read(payload)
            live.time = header.time
            live.fragmentCount = header.fragmentCount
            live.impacts += header.impacts
            return .fragments(live)
        case (.thermal(var live), .thermal(let header)):
            try live.read(payload, header: header)
            return .thermal(live)
        case (.groundShock, .groundShock(let result)):
            return .groundShock(result)
        default:
            throw ProjectFileError.invalid("A consumer's live state came back as another kind.")
        }
    }
}

/// Every receiver's fluence, peak irradiance and peak surface temperature as of the last frame
/// consumed, for drawing and for keeping the run.
struct ThermalLive: Sendable, Equatable {
    /// Frames consumed so far.
    var frames = 0
    var time: Double = 0
    /// In joules a square metre, one a receiver.
    var fluence: [Float] = []
    /// In watts a square metre, one a receiver.
    var peakIrradiance: [Float] = []
    /// In kelvin, one a receiver; empty where the surfaces' heating is not reckoned.
    var peakTemperature: [Float] = []

    init(receivers: Int) {
        fluence = [Float](repeating: 0, count: receivers)
        peakIrradiance = fluence
    }

    init(_ exposure: ThermalExposure) {
        frames = exposure.frames.count
        time = exposure.frames.last?.time ?? 0
        // As `ThermalExposure.result` rounds them, so a run kept from these is the same.
        fluence = exposure.fluence.map { Float($0) }
        peakIrradiance = exposure.peakIrradiance
        peakTemperature = exposure.heating?.peakTemperature ?? []
    }

    /// The fluences, the peak irradiances and any peak surface temperatures, as little-endian floats.
    var payload: Data {
        (fluence + peakIrradiance + peakTemperature).withUnsafeBytes { Data($0) }
    }

    mutating func read(_ payload: Data, header: ThermalLiveHeader) throws {
        let count = fluence.count
        guard payload.count == 8 * count || payload.count == 12 * count else {
            throw ProjectFileError.invalid("The thermal radiation arrived cut short.")
        }
        let heated = payload.count == 12 * count
        if heated && peakTemperature.count != count { peakTemperature = [Float](repeating: 0, count: count) }
        payload.withUnsafeBytes { raw in
            for n in 0..<count {
                fluence[n] = raw.loadUnaligned(fromByteOffset: 4 * n, as: Float.self)
                peakIrradiance[n] = raw.loadUnaligned(fromByteOffset: 4 * (count + n), as: Float.self)
                if heated {
                    peakTemperature[n] = raw.loadUnaligned(
                        fromByteOffset: 4 * (2 * count + n), as: Float.self)
                }
            }
        }
        frames = header.frames
        time = header.time
    }
}
