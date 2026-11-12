import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// The quarry's dust for the eye (emmettl/bombcad-work#137). Illustrative scene; this guards when
/// the dust starts, not how it looks.
@Suite("Quarry dust", .serialized, .gpuThreads)
struct QuarryDustTests {
    /// All the dust in the field, from a stored copy of it (velocity, then density in halves).
    func total(_ dust: QuarryDustField) throws -> Double {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quarry-dust-test-\(ProcessInfo.processInfo.processIdentifier).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try dust.save(to: url)
        let data = try Data(contentsOf: url)
        let cells = dust.dims.x * dust.dims.y * dust.dims.z
        return data.withUnsafeBytes { raw in
            let density = raw.baseAddress!.advanced(by: cells * 8).assumingMemoryBound(to: Float16.self)
            return (0..<cells).reduce(0.0) { $0 + Double(density[$1]) }
        }
    }

    @Test("The dust starts as the rock first moves, before the first firing lets it go")
    func startsWithTheSwell() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var options = QuarryFace.Options()
        options.blocks = 3000
        options.meshDetail = 1
        var face = try QuarryFace(site: .builtIn(), options: options)
        face.generate()
        let firings = QuarryFiringPattern.row(face: face)
        let first = try #require(firings.map(\.time).min())
        let dust = try QuarryDustField(
            device: device, face: face.withoutMesh(), firings: firings,
            sun: simd_normalize(SIMD3(0.3, -0.5, 0.8)),
            gridSize: 1.5)
        // Every block awake where it stands: nothing moves, so nothing trails or strikes, and the
        // firings' own puffs and the puffs at release come only at and after the first firing.
        let bodies = face.blocks.count
        var rest = [SIMD4<Float>]()
        for block in face.blocks { rest += [SIMD4(block.centre, 1), SIMD4(0, 0, 0, 1)] }
        let pose = try #require(device.makeBuffer(bytes: rest, length: 32 * bodies))
        let previous = try #require(device.makeBuffer(bytes: rest, length: 32 * bodies))
        let sizes = face.blocks.map(\.size)
        var calm = -1.0
        var frame = 0
        while Float(frame + 1) / 30 < first - 0.05 {
            frame += 1
            let time = Float(frame) / 30
            _ = dust.step(
                pose: pose, previous: previous, bodies: bodies, time: time, restSize: sizes, frameRate: 30)
            // The swell begins at most 1.25 s before a block lets go.
            if calm < 0, time >= first - 1.3 { calm = try total(dust) }
        }
        #expect(calm == 0, "no dust before any swell begins")
        let before = try total(dust)
        #expect(
            before > 0,
            "dust as the swell begins, \(String(format: "%.2f", first - Float(frame) / 30)) s before the first firing"
        )
    }
}
