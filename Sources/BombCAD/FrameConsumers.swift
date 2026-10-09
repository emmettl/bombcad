import BlastCore
import DocumentKit
import Foundation

/// A model fed by the blast a frame at a time, one way, here or on another Mac: what it is and
/// what it needs to start.
enum ConsumerKind: Codable, Sendable, Equatable {
    /// A cased charge's fragments and tracers, flown through blocks of the air. `live` sends their
    /// positions back after each frame, to draw them.
    case fragments(FragmentSpec, FragmentScene, live: Bool)
    /// The fireball's radiation on the scene's surfaces.
    case thermal(ThermalSpec, FragmentScene)
    /// The ground's shaking under chosen points.
    case groundShock(GroundShockSpec)

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
        case .fireball(let frame): .fireball(frame)
        case .ground(let slice): .ground(slice.header)
        }
    }

    var payload: Data {
        switch self {
        case .air(let slice): slice.payload
        case .fireball: Data()
        case .ground(let slice): slice.payload
        }
    }

    /// The samples' size, without copying them.
    var byteCount: Int {
        switch self {
        case .air(let slice): 2 * slice.values.count
        case .fireball: 0
        case .ground(let slice): 4 * slice.values.count
        }
    }

    init(header: Header, payload: Data) throws {
        switch header {
        case .air(let header): self = .air(try AirSlice(header: header, payload: payload))
        case .fireball(let frame): self = .fireball(frame)
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
        case .thermal(let spec, let scene):
            model = .thermal(ThermalExposure(spec: spec, scene: scene))
        case .groundShock(let spec):
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

    /// The fragments' particles now, if they are flown live.
    func live(time: Double) -> FragmentLive? {
        guard case .fragments(let consumer, let live) = model, live else { return nil }
        return FragmentLive(consumer, time: time)
    }

    func outcome(frameInterval: Double) -> ConsumerOutcome {
        switch model {
        case .fragments(let consumer, _): .fragments(consumer.result(frameInterval: frameInterval))
        case .thermal(let exposure): .thermal(exposure.result)
        case .groundShock(let consumer): .groundShock(consumer.result(frameInterval: frameInterval))
        }
    }
}
