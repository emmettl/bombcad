import BlastCore
import BlastRender
import Foundation
import simd

/// What a run elsewhere's view draws over its scene view, sent with each `ViewFrame` (protocol 19,
/// emmettl/bombcad-work#73): the fragments and tracers in flight, the fragments' strikes, the
/// ground points, the freestanding objects, and the layers a recording keeps (`TimelineLayers`:
/// the vents, the envelopes' damage colours, the thermal paint and the cloud). Each of the stored
/// parts goes only when it has changed, and otherwise names the frame that holds it, as a
/// recording's layers do; refreshed every `refresh` frames, so that a watcher who missed the frame
/// holding one (a session resumed after a dropped link) has it again soon.
struct SceneOverlay: Sendable, Equatable {
    /// The particles as a recording keeps them: positions, speeds and whether landed. Their strikes
    /// go apart, in `strikes`.
    var fragments: FragmentLive?
    /// The fragments' strikes and landings as the view draws them (`SimulationModel.strikeDots`).
    var strikes: TimelineStored<[SIMD4<Float>]> = .none
    /// The ground points as the view draws them (`GroundShockResult.dots`).
    var groundDots: TimelineStored<[SIMD4<Float>]> = .none
    var freestanding: TimelineStored<[SceneRenderer.OrientedBox]> = .none
    var layers = TimelineLayers()

    /// Frames, by number (a millisecond each by default), after which an unchanged part is sent
    /// again all the same.
    static let refresh = 16
}

/// The sender's side: each part's last value sent, so that a frame sends only what has changed.
struct SceneOverlayKeeper {
    private var strikes = TimelineStoredKeeper<[SIMD4<Float>]>(refresh: SceneOverlay.refresh)
    private var groundDots = TimelineStoredKeeper<[SIMD4<Float>]>(refresh: SceneOverlay.refresh)
    private var freestanding = TimelineStoredKeeper<[SceneRenderer.OrientedBox]>(
        refresh: SceneOverlay.refresh)
    private var layers = TimelineLayerKeeper(refresh: SceneOverlay.refresh)

    /// `overlay`, each part a value or none, as frame `frame` sends it.
    mutating func store(_ overlay: SceneOverlay, frame: Int) -> SceneOverlay {
        var sent = overlay
        sent.strikes = strikes.store(overlay.strikes.value, frame: frame)
        sent.groundDots = groundDots.store(overlay.groundDots.value, frame: frame)
        sent.freestanding = freestanding.store(overlay.freestanding.value, frame: frame)
        sent.layers = layers.store(overlay.layers, frame: frame)
        return sent
    }
}

/// One part's side of a reader: the last value read and its frame, for the frames after that name
/// it.
struct TimelineStoredResolver<Value: Sendable & Equatable> {
    private var last: (value: Value, frame: Int)?

    /// `stored`'s value in frame `frame`: its own, the one it names if that is the last read, or
    /// none if it names a frame not read.
    mutating func resolve(_ stored: TimelineStored<Value>, frame: Int) -> TimelineStored<Value> {
        switch stored {
        case .none:
            last = nil
            return .none
        case .here(let value):
            last = (value, frame)
            return stored
        case .sameAs(let held):
            guard let last, last.frame == held else { return .none }
            return .here(last.value)
        }
    }
}

/// The watcher's side: each part resolved to its value, from the frames read so far.
struct SceneOverlayResolver {
    private var strikes = TimelineStoredResolver<[SIMD4<Float>]>()
    private var groundDots = TimelineStoredResolver<[SIMD4<Float>]>()
    private var freestanding = TimelineStoredResolver<[SceneRenderer.OrientedBox]>()
    private var vents = TimelineStoredResolver<TimelineLayers.Vents>()
    private var envelopeCodes = TimelineStoredResolver<[UInt8]>()
    private var thermal = TimelineStoredResolver<TimelineLayers.Thermal>()
    private var cloud = TimelineStoredResolver<TimelineLayers.Cloud>()

    /// `overlay` as sent in frame `frame`, with every part a value or none.
    mutating func resolve(_ overlay: SceneOverlay, frame: Int) -> SceneOverlay {
        var resolved = overlay
        resolved.strikes = strikes.resolve(overlay.strikes, frame: frame)
        resolved.groundDots = groundDots.resolve(overlay.groundDots, frame: frame)
        resolved.freestanding = freestanding.resolve(overlay.freestanding, frame: frame)
        resolved.layers.vents = vents.resolve(overlay.layers.vents, frame: frame)
        resolved.layers.envelopeCodes = envelopeCodes.resolve(overlay.layers.envelopeCodes, frame: frame)
        resolved.layers.thermal = thermal.resolve(overlay.layers.thermal, frame: frame)
        resolved.layers.cloud = cloud.resolve(overlay.layers.cloud, frame: frame)
        return resolved
    }
}

/// The overlay's bytes, little-endian, in the timeline layers' encoding (`TimelineLayerCodec`):
/// whether there are fragments and if so their count, how many are fragments rather than tracers,
/// and `FragmentLive.payload`; then the strikes, the ground points (each a dot of four floats) and
/// the freestanding boxes (eleven floats each, as a recorded frame's), each 0 for none, 1 and the
/// value, or 2 and the frame that holds it; then the layers.
enum SceneOverlayCodec {
    static func encode(_ overlay: SceneOverlay) -> Data {
        var writer = TimelineLayerCodec.Writer()
        writer.integer(overlay.fragments == nil ? 0 : 1)
        if let fragments = overlay.fragments {
            writer.integer(fragments.positions.count)
            writer.integer(fragments.fragmentCount)
            writer.out.append(fragments.payload)
        }
        func dots(_ w: inout TimelineLayerCodec.Writer, _ dots: [SIMD4<Float>]) {
            w.integer(dots.count)
            for dot in dots { for k in 0..<4 { w.float(dot[k]) } }
        }
        writer.stored(overlay.strikes, dots)
        writer.stored(overlay.groundDots, dots)
        writer.stored(overlay.freestanding) { w, boxes in
            w.integer(boxes.count)
            for box in boxes {
                for value in [
                    box.centre.x, box.centre.y, box.centre.z, box.orientation.vector.x,
                    box.orientation.vector.y, box.orientation.vector.z, box.orientation.vector.w,
                    box.size.x, box.size.y, box.size.z, box.isCar ? 1 : 0,
                ] {
                    w.float(value)
                }
            }
        }
        TimelineLayerCodec.write(overlay.layers, into: &writer)
        return writer.out
    }

    /// The overlay in `data`, its fragments' time `time`.
    static func decode(_ data: Data, time: Double) throws -> SceneOverlay {
        var reader = TimelineLayerCodec.Reader(data: data, at: data.startIndex)
        var overlay = SceneOverlay()
        if try reader.integer(limit: 1) == 1 {
            let particles = try reader.integer(limit: (data.endIndex - reader.at) / 16)
            let count = try reader.integer(limit: particles)
            guard data.endIndex - reader.at >= 16 * particles else { throw reader.bad() }
            var live = FragmentLive()
            try live.read(data[reader.at..<(reader.at + 16 * particles)])
            reader.at += 16 * particles
            live.fragmentCount = count
            live.time = time
            overlay.fragments = live
        }
        func dots(_ r: inout TimelineLayerCodec.Reader) throws -> [SIMD4<Float>] {
            let count = try r.integer(limit: (data.endIndex - r.at) / 16)
            return try (0..<count).map { _ in
                SIMD4(try r.float(), try r.float(), try r.float(), try r.float())
            }
        }
        overlay.strikes = try reader.stored(dots)
        overlay.groundDots = try reader.stored(dots)
        overlay.freestanding = try reader.stored { r in
            let count = try r.integer(limit: (data.endIndex - r.at) / 44)
            return try (0..<count).map { _ in
                let v = try (0..<11).map { _ in try r.float() }
                return SceneRenderer.OrientedBox(
                    centre: SIMD3(v[0], v[1], v[2]),
                    orientation: simd_quatf(vector: SIMD4(v[3], v[4], v[5], v[6])),
                    size: SIMD3(v[7], v[8], v[9]), isCar: v[10] != 0)
            }
        }
        overlay.layers = try TimelineLayerCodec.read(&reader)
        guard reader.at == data.endIndex else { throw reader.bad() }
        return overlay
    }
}

extension SimulationModel {
    /// What this run's view draws over its scene now, every part a value or none, for a watcher
    /// elsewhere (`SceneOverlay`).
    func sceneOverlay(_ solver: BlastSolver) -> SceneOverlay {
        var overlay = SceneOverlay()
        if var live = fragments?.fragmentLive ?? fragmentLive {
            let strikes = Self.strikeDots(live.impacts)
            if !strikes.isEmpty { overlay.strikes = .here(strikes) }
            live.impacts = []
            overlay.fragments = live
        }
        if let ground = groundShockLive { overlay.groundDots = .here(ground.dots) }
        let boxes = freestandingBoxes()
        if !boxes.isEmpty { overlay.freestanding = .here(boxes) }
        overlay.layers = timelineLayers(solver)
        return overlay
    }
}
