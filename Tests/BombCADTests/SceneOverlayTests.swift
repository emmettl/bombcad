import BlastCore
import BlastRender
import DocumentKit
import Foundation
import Testing
import simd

@testable import BombCAD

/// What a run elsewhere's view draws over its scene (`SceneOverlay`, emmettl/bombcad-work#73):
/// encoded as a recording's layers are, each part sent only when it has changed, and resolved
/// again on the watcher's side.
@Suite("What a watched run draws over its scene")
struct SceneOverlayTests {
    private func overlay(_ step: Int) -> SceneOverlay {
        var fragments = FragmentLive()
        fragments.positions = [SIMD3(1, 2, 3), SIMD3(4, 5, Float(step))]
        fragments.speeds = [10, 0]
        fragments.landed = [false, true]
        fragments.fragmentCount = 1
        fragments.time = 0.004
        var overlay = SceneOverlay(fragments: fragments)
        overlay.strikes = .here([SIMD4(1, 1, 0, 2.5)])
        overlay.groundDots = .here([SIMD4(3, 3, 0.05, 3 + Float(step) / 100)])
        overlay.freestanding = .here([
            .init(
                centre: SIMD3(5, 5, 1), orientation: simd_quatf(angle: 0.3, axis: SIMD3(0, 0, 1)),
                size: SIMD3(4, 2, 1.5), isCar: true)
        ])
        overlay.layers.vents = .here(.init(panels: [true, false], panes: [false, false, true]))
        overlay.layers.envelopeCodes = .here([0, 2, 5])
        overlay.layers.thermal = .here(
            .init(
                frames: 3, fluence: [1e6, 2e5] + [Float](repeating: 5e5, count: 498),
                peakIrradiance: [3e7, 1e6] + [Float](repeating: 1e6, count: 498), peakTemperature: []))
        return overlay
    }

    @Test("An overlay comes back as it went, its thermal values to half precision, and bad bytes are refused")
    func roundTrip() throws {
        let sent = overlay(1)
        let back = try SceneOverlayCodec.decode(SceneOverlayCodec.encode(sent), time: 0.004)
        #expect(back.fragments == sent.fragments)
        #expect(back.strikes == sent.strikes && back.groundDots == sent.groundDots)
        #expect(back.freestanding == sent.freestanding)
        #expect(
            back.layers.vents == sent.layers.vents && back.layers.envelopeCodes == sent.layers.envelopeCodes)
        let thermal = try #require(back.layers.thermal.value)
        #expect(thermal.frames == 3 && thermal.peakTemperature.isEmpty)
        let firsts = Array(thermal.fluence.prefix(2) + thermal.peakIrradiance.prefix(2))
        for (a, b) in zip(firsts, [1e6, 2e5, 3e7, 1e6] as [Float]) {
            #expect(abs(a - b) <= b / 500)
        }
        // Nothing to draw yet is a few bytes; a part named in another frame is its number.
        var named = SceneOverlay()
        named.groundDots = .sameAs(12)
        named.layers.thermal = .sameAs(7)
        let small = SceneOverlayCodec.encode(named)
        #expect(small.count < 100)
        let read = try SceneOverlayCodec.decode(small, time: 0)
        #expect(read.groundDots == .sameAs(12) && read.layers.thermal == .sameAs(7) && read.fragments == nil)
        let bytes = SceneOverlayCodec.encode(sent)
        #expect(throws: ProjectFileError.self) { try SceneOverlayCodec.decode(bytes.dropLast(3), time: 0) }
        #expect(throws: ProjectFileError.self) { try SceneOverlayCodec.decode(bytes + Data([0]), time: 0) }
        // A slice of a frame's payload reads the same.
        let padded = Data([9, 9]) + bytes
        #expect(try SceneOverlayCodec.decode(padded.dropFirst(2), time: 0.004).fragments == sent.fragments)
    }

    @Test("Each part goes only when it changes, again every refresh, and a watcher who missed it has it soon")
    func sentWhenChanged() throws {
        var keeper = SceneOverlayKeeper()
        var watcher = SceneOverlayResolver()
        var late = SceneOverlayResolver()
        let fixed = overlay(0)
        var sizes: [Int] = []
        for frame in 0..<40 {
            var now = fixed
            // The ground points change until frame 10, the rest never.
            now.groundDots = overlay(min(frame, 10)).groundDots
            let sent = keeper.store(now, frame: frame)
            sizes.append(SceneOverlayCodec.encode(sent).count)
            let wire = try SceneOverlayCodec.decode(SceneOverlayCodec.encode(sent), time: 0)
            // The watcher sees every frame, and always has every part.
            let seen = watcher.resolve(wire, frame: frame)
            #expect(
                seen.groundDots == now.groundDots && seen.layers.envelopeCodes == now.layers.envelopeCodes)
            #expect(seen.layers.thermal.value?.frames == 3 && seen.freestanding == now.freestanding)
            switch frame {
            case 0: #expect(sent.layers.envelopeCodes.value != nil)
            case 1...15: #expect(sent.layers.envelopeCodes == .sameAs(0))
            case 16: #expect(sent.layers.envelopeCodes.value != nil, "refreshed")
            default: break
            }
            if (1...10).contains(frame) { #expect(sent.groundDots.value != nil) }
            if frame == 11 { #expect(sent.groundDots == .sameAs(10)) }
            // One who joins at frame 5 has nothing it cannot resolve, and everything by frame 16.
            if frame >= 5 {
                let joined = late.resolve(wire, frame: frame)
                if frame < 16 { #expect(joined.layers.envelopeCodes == .none) }
                if frame >= 16 { #expect(joined.layers.envelopeCodes == now.layers.envelopeCodes) }
                if frame >= 16 { #expect(joined == seen) }
            }
        }
        // Unchanged, a frame's overlay is the fragments and a few numbers.
        #expect(sizes[12] < sizes[0] / 2)
    }

    @Test("A frame's payload carries the scene view and then the overlay, each read back apart")
    func inAFrame() throws {
        let ground = GroundSlice(
            time: 0.003, cellSize: 1, grid: SIMD3(2, 1, 1), first: .zero, counts: SIMD2(2, 1),
            values: [Float](repeating: 1000, count: 6), ambientDensity: 1.2, ambientPressure: 101_325,
            gamma: 1.4)
        let scene = Data((0..<40).map { UInt8($0) })
        let overlayBytes = SceneOverlayCodec.encode(overlay(2))
        let payload = WatchFrame.pack(
            ground: ground, surface: nil, includeQuads: false, scene: scene, overlay: overlayBytes)
        let header = WatchFrame.Header(
            frame: 3, time: 0.003, cellSize: 1, counts: SIMD2(2, 1), points: 0, faces: 0,
            quadsIncluded: false, scene: scene.count, overlay: overlayBytes.count, rawBytes: payload.count,
            compression: .none)
        let read = try WatchFrame.decode(header, payload: payload)
        #expect(read.scene == scene && read.overlay == overlayBytes)
        #expect(read.ground.count == 6)
        // A slice of a larger buffer, as a payload uncompressed is, reads the same.
        let padded = Data([7]) + payload
        let sliced = try WatchFrame.decode(header, payload: padded.dropFirst())
        #expect(sliced.scene == scene && sliced.overlay == overlayBytes)
    }
}
