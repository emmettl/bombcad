import DocumentKit
import Foundation
import simd

/// A layer of a recorded frame as it is stored: none in the run so far, its value in this frame,
/// or the same as in the frame of file number `n` (`f-00000n.lzfse`). Each layer is stored only
/// when it changes, so a frame points back to the one that holds it.
enum TimelineStored<Value: Sendable & Equatable>: Sendable, Equatable {
    case none
    case here(Value)
    case sameAs(Int)

    var value: Value? {
        if case .here(let value) = self { value } else { nil }
    }
}

/// What the view draws over the scene that changes as a run goes, beside its scene view: recorded
/// with each frame from encoding version 2 (emmettl/bombcad-work#7).
struct TimelineLayers: Sendable, Equatable {
    /// Which of the scene's vent panels that release (`VentPanel.releasePressure` above zero, in
    /// order) have opened, and which of the envelopes' venting panes have broken
    /// (`BlastSolver.envelopePaneOwners` order).
    struct Vents: Sendable, Equatable {
        var panels: [Bool]
        var panes: [Bool]
    }

    /// Every receiver's thermal radiation as of the frames reckoned by then (`ThermalLive`).
    struct Thermal: Sendable, Equatable {
        var frames: Int
        /// J/m², W/m² and K, one a receiver; the temperatures empty where heating is not reckoned.
        var fluence: [Float]
        var peakIrradiance: [Float]
        var peakTemperature: [Float]
    }

    /// The hot gas handed over to the cloud model at the run's end (`CloudHandOver`): its centre,
    /// the radius of a ball of its volume at the ambient pressure, and its mass.
    struct Cloud: Sendable, Equatable {
        var time: Double
        var centre: SIMD3<Float>
        var radius: Float
        var mass: Double
    }

    var vents: TimelineStored<Vents> = .none
    /// One an envelope building, in the scene's order (`Scenario.envelopeObjects`): the colour code
    /// the view gives its damage (`EnvelopeDamageColour`, 1 to 6), 0 where none has been judged.
    var envelopeCodes: TimelineStored<[UInt8]> = .none
    var thermal: TimelineStored<Thermal> = .none
    var cloud: TimelineStored<Cloud> = .none

    /// Whether every layer is a value or none: nothing points to another frame.
    var isResolved: Bool {
        func resolved<V>(_ layer: TimelineStored<V>) -> Bool {
            if case .sameAs = layer { false } else { true }
        }
        return resolved(vents) && resolved(envelopeCodes) && resolved(thermal) && resolved(cloud)
    }
}

/// The layers' bytes, after a version-2 frame's freestanding boxes: for each of the vents, the
/// envelope codes, the thermal paint and the cloud in turn, 0 for none, 1 and the value, or 2 and
/// the frame that holds it. Bits are packed eight to a byte; the thermal values as half-precision
/// floats over a power-of-two scale each, so that a fluence of megajoules keeps its three figures.
enum TimelineLayerCodec {
    struct Writer {
        var out = Data()

        mutating func integer(_ value: Int) {
            withUnsafeBytes(of: UInt64(value).littleEndian) { out.append(contentsOf: $0) }
        }
        mutating func float(_ value: Float) {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { out.append(contentsOf: $0) }
        }
        mutating func double(_ value: Double) {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { out.append(contentsOf: $0) }
        }
        mutating func bits(_ values: [Bool]) {
            integer(values.count)
            var bytes = [UInt8](repeating: 0, count: (values.count + 7) / 8)
            for (n, value) in values.enumerated() where value { bytes[n / 8] |= 1 << UInt8(n % 8) }
            out.append(contentsOf: bytes)
        }
        mutating func scaledHalves(_ values: [Float]) {
            integer(values.count)
            let largest = values.lazy.filter(\.isFinite).map(abs).max() ?? 0
            // The largest at most 2^14, well inside a half's range, its smallest normal 2^-14.
            let scale: Float =
                largest > 0 ? Float(sign: .plus, exponent: largest.exponent - 14, significand: 1) : 1
            float(scale)
            var halves = [UInt16](repeating: 0, count: values.count)
            for (n, value) in values.enumerated() {
                halves[n] = Float16(value / scale).bitPattern.littleEndian
            }
            halves.withUnsafeBytes { out.append(contentsOf: $0) }
        }
        mutating func stored<V>(_ layer: TimelineStored<V>, _ value: (inout Writer, V) -> Void) {
            switch layer {
            case .none: integer(0)
            case .here(let v):
                integer(1)
                value(&self, v)
            case .sameAs(let frame):
                integer(2)
                integer(frame)
            }
        }
    }

    struct Reader {
        let data: Data
        var at: Data.Index

        func bad() -> Error { ProjectFileError.invalid("A recorded frame's layers are malformed.") }

        mutating func word(_ size: Int) throws -> UInt64 {
            guard data.endIndex - at >= size else { throw bad() }
            var value: UInt64 = 0
            for k in 0..<size { value |= UInt64(data[at + k]) << (8 * k) }
            at += size
            return value
        }
        mutating func integer(limit: Int) throws -> Int {
            let value = try word(8)
            guard value <= UInt64(limit) else { throw bad() }
            return Int(value)
        }
        mutating func float() throws -> Float { Float(bitPattern: UInt32(try word(4))) }
        mutating func double() throws -> Double { Double(bitPattern: try word(8)) }
        mutating func bits() throws -> [Bool] {
            let count = try integer(limit: 8 * (data.endIndex - at))
            let bytes = (count + 7) / 8
            guard data.endIndex - at >= bytes else { throw bad() }
            defer { at += bytes }
            return (0..<count).map { data[at + $0 / 8] & (1 << UInt8($0 % 8)) != 0 }
        }
        mutating func bytes() throws -> [UInt8] {
            let count = try integer(limit: data.endIndex - at)
            defer { at += count }
            return Array(data[at..<(at + count)])
        }
        mutating func scaledHalves() throws -> [Float] {
            let count = try integer(limit: (data.endIndex - at) / 2)
            let scale = try float()
            guard data.endIndex - at >= 2 * count else { throw bad() }
            defer { at += 2 * count }
            return (0..<count).map { n in
                let bits = UInt16(data[at + 2 * n]) | UInt16(data[at + 2 * n + 1]) << 8
                return Float(Float16(bitPattern: bits)) * scale
            }
        }
        mutating func stored<V>(_ value: (inout Reader) throws -> V) throws -> TimelineStored<V> {
            switch try integer(limit: 2) {
            case 0: return .none
            case 1: return .here(try value(&self))
            default: return .sameAs(try integer(limit: Int(Int32.max)))
            }
        }
    }

    static func write(_ layers: TimelineLayers, into writer: inout Writer) {
        writer.stored(layers.vents) { w, vents in
            w.bits(vents.panels)
            w.bits(vents.panes)
        }
        writer.stored(layers.envelopeCodes) { w, codes in
            w.integer(codes.count)
            w.out.append(contentsOf: codes)
        }
        writer.stored(layers.thermal) { w, thermal in
            w.integer(thermal.frames)
            w.scaledHalves(thermal.fluence)
            w.scaledHalves(thermal.peakIrradiance)
            w.scaledHalves(thermal.peakTemperature)
        }
        writer.stored(layers.cloud) { w, cloud in
            w.double(cloud.time)
            for value in [cloud.centre.x, cloud.centre.y, cloud.centre.z, cloud.radius] { w.float(value) }
            w.double(cloud.mass)
        }
    }

    static func read(_ reader: inout Reader) throws -> TimelineLayers {
        var layers = TimelineLayers()
        layers.vents = try reader.stored { r in
            TimelineLayers.Vents(panels: try r.bits(), panes: try r.bits())
        }
        layers.envelopeCodes = try reader.stored { r in try r.bytes() }
        layers.thermal = try reader.stored { r in
            TimelineLayers.Thermal(
                frames: try r.integer(limit: Int(Int32.max)), fluence: try r.scaledHalves(),
                peakIrradiance: try r.scaledHalves(), peakTemperature: try r.scaledHalves())
        }
        layers.cloud = try reader.stored { r in
            TimelineLayers.Cloud(
                time: try r.double(), centre: SIMD3(try r.float(), try r.float(), try r.float()),
                radius: try r.float(), mass: try r.double())
        }
        return layers
    }
}

/// One layer's side of a keeper: its last stored value and the frame it is in, so that a frame
/// stores it only when it has changed and otherwise points back to it.
struct TimelineStoredKeeper<Value: Sendable & Equatable> {
    private var last: (value: Value, frame: Int)?
    /// With a refresh, a value unchanged for that many frames is stored again all the same, so
    /// that a reader who missed the frame holding it (a watcher who joined late) has it soon.
    var refresh: Int?

    init(refresh: Int? = nil) { self.refresh = refresh }

    /// `value`, or none, as frame `frame` stores it; `same` says whether it is unchanged.
    mutating func store(_ value: Value?, frame: Int, same: (Value, Value) -> Bool = (==))
        -> TimelineStored<Value>
    {
        guard let value else {
            last = nil
            return .none
        }
        // A frame written again in place of the one that holds it stores it itself.
        if let previous = last, previous.frame != frame, same(previous.value, value),
            refresh.map({ frame - previous.frame < $0 }) ?? true
        {
            return .sameAs(previous.frame)
        }
        last = (value, frame)
        return .here(value)
    }
}

/// The recorder's side: each layer's last stored value and the frame it is in, so that a frame
/// stores a layer only when it has changed and otherwise points back to it.
struct TimelineLayerKeeper {
    private var vents: TimelineStoredKeeper<TimelineLayers.Vents>
    private var envelopeCodes: TimelineStoredKeeper<[UInt8]>
    private var thermal: TimelineStoredKeeper<TimelineLayers.Thermal>
    private var cloud: TimelineStoredKeeper<TimelineLayers.Cloud>

    /// With `refresh`, as `TimelineStoredKeeper`.
    init(refresh: Int? = nil) {
        vents = .init(refresh: refresh)
        envelopeCodes = .init(refresh: refresh)
        thermal = .init(refresh: refresh)
        cloud = .init(refresh: refresh)
    }

    /// `layers`, each a value or none, as frame `frame` stores them.
    mutating func store(_ layers: TimelineLayers, frame: Int) -> TimelineLayers {
        var stored = TimelineLayers()
        stored.vents = vents.store(layers.vents.value, frame: frame)
        stored.envelopeCodes = envelopeCodes.store(layers.envelopeCodes.value, frame: frame)
        // The thermal paint is the same while no more of its frames are reckoned.
        stored.thermal = thermal.store(layers.thermal.value, frame: frame) { $0.frames == $1.frames }
        stored.cloud = cloud.store(layers.cloud.value, frame: frame)
        return stored
    }
}
