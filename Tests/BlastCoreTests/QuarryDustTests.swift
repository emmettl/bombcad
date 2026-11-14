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

    /// All the dust in the field and where its middle is (m), from a stored copy of it.
    func centre(_ dust: QuarryDustField) throws -> (total: Double, middle: SIMD3<Double>) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quarry-dust-centre-\(ProcessInfo.processInfo.processIdentifier).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try dust.save(to: url)
        let data = try Data(contentsOf: url)
        let (nx, ny, nz) = (dust.dims.x, dust.dims.y, dust.dims.z)
        return data.withUnsafeBytes { raw in
            let density = raw.baseAddress!.advanced(by: nx * ny * nz * 8).assumingMemoryBound(
                to: Float16.self)
            var total = 0.0
            var sum = SIMD3<Double>.zero
            for k in 0..<nz {
                for j in 0..<ny {
                    for i in 0..<nx {
                        let d = Double(density[i + nx * (j + ny * k)])
                        guard d > 0 else { continue }
                        total += d
                        sum += d * SIMD3(Double(i), Double(j), Double(k))
                    }
                }
            }
            let low = SIMD3<Double>(dust.low)
            return (total, total > 0 ? low + Double(dust.h) * (sum / total + 0.5) : low)
        }
    }

    @Test(
        "A ridge cut's dust lingers and drifts with the wind: its columns merge, thin and lean, not vanish (emmettl/bombcad-work#145)"
    )
    func ridgeDustLingers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var options = QuarryFace.Options()
        options.blocks = 3000
        options.meshDetail = 1
        var face = try QuarryFace(site: .builtIn(.ridgeCut), options: options)
        face.generate()
        let firings = QuarryFiringPattern.pattern(face: face)
        let last = try #require(firings.map(\.time).max())
        let dust = try QuarryDustField(
            device: device, face: face.withoutMesh(), firings: firings,
            sun: simd_normalize(SIMD3(0.3, -0.5, 0.8)), gridSize: 1.5)
        // The columns differ from one another and reach their neighbours along the cut.
        let columns = dust.columns
        #expect(columns.count == firings.count)
        let strengths = columns.map(\.strength)
        #expect(strengths.max()! - strengths.min()! > 0.4, "columns of unequal strength")
        let xs = firings.map(\.position.x).sorted()
        let spacing = (xs.last! - xs.first!) / Float(xs.count - 1)
        #expect(columns.allSatisfy { $0.reach.x >= 0.9 * spacing }, "each column reaches its neighbours")
        // Blocks where they stand: only the firings' columns put dust in.
        let bodies = face.blocks.count
        var rest = [SIMD4<Float>]()
        for block in face.blocks { rest += [SIMD4(block.centre, 1), SIMD4(0, 0, 0, 1)] }
        let pose = try #require(device.makeBuffer(bytes: rest, length: 32 * bodies))
        let previous = try #require(device.makeBuffer(bytes: rest, length: 32 * bodies))
        let sizes = face.blocks.map(\.size)
        var frame = 0
        func run(to time: Float) {
            while Float(frame + 1) / 30 <= time {
                frame += 1
                _ = dust.step(
                    pose: pose, previous: previous, bodies: bodies, time: Float(frame) / 30, restSize: sizes,
                    frameRate: 30)
            }
        }
        run(to: last + 2)
        let early = try centre(dust)
        #expect(early.total > 0)
        run(to: last + 10)
        let late = try centre(dust)
        // Stage 3f to 3j thinned all of it at 0.6 to 0.9 a second: exp(-0.6 * 8) is under 1%.
        #expect(late.total > 0.1 * early.total, "the dust lingers: \(late.total / early.total) of it left")
        let wind = SIMD2<Double>(Double(dust.uniforms.wind.x), Double(dust.uniforms.wind.y))
        let drift = SIMD2(late.middle.x - early.middle.x, late.middle.y - early.middle.y)
        #expect(simd_dot(drift, simd_normalize(wind)) > 5, "the dust drifts downwind: \(drift)")
    }

    /// The march's haze bound (halves), from a copy of it.
    func hazeBound(_ dust: QuarryDustField) throws -> [Float] {
        let size = MTLSize(width: dust.dims.x, height: dust.dims.y, depth: dust.dims.z)
        let count = size.width * size.height * size.depth
        let staging = try #require(dust.device.makeBuffer(length: 2 * count, options: .storageModeShared))
        let buffer = try #require(dust.queue.makeCommandBuffer())
        let blit = try #require(buffer.makeBlitCommandEncoder())
        blit.copy(
            from: dust.hazeBound, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: size,
            to: staging, destinationOffset: 0, destinationBytesPerRow: 2 * size.width,
            destinationBytesPerImage: 2 * size.width * size.height)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        let halves = staging.contents().bindMemory(to: Float16.self, capacity: count)
        return (0..<count).map { Float(halves[$0]) }
    }

    @Test(
        "A face's firings' dust is spread along the strip, each firing's reaching its neighbours, and the march's haze bound holds every cell's dust within its reach (emmettl/bombcad-work#146)"
    )
    func faceDustMergesAndHazeBound() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var options = QuarryFace.Options()
        options.blocks = 3000
        options.meshDetail = 1
        var face = try QuarryFace(site: .builtIn(), options: options)
        face.generate()
        let firings = QuarryFiringPattern.row(face: face)
        let dust = try QuarryDustField(
            device: device, face: face.withoutMesh(), firings: firings,
            sun: simd_normalize(SIMD3(0.3, -0.5, 0.8)), gridSize: 1.5)
        let columns = dust.columns
        #expect(columns.count == firings.count)
        let strengths = columns.map(\.strength)
        #expect(strengths.max()! - strengths.min()! > 0.4, "firings of unequal strength")
        let xs = firings.map(\.position.x).sorted()
        let spacing = (xs.last! - xs.first!) / Float(xs.count - 1)
        #expect(
            columns.allSatisfy { $0.reach.x >= 0.9 * spacing }, "each firing's dust reaches its neighbours")
        // The face's wind blows along the strip toward its far end, not into the face.
        #expect(dust.uniforms.wind.x > 2 && dust.uniforms.wind.y < 0, "wind \(dust.uniforms.wind)")
        // Blocks where they stand: only the firings put dust in.
        let bodies = face.blocks.count
        var rest = [SIMD4<Float>]()
        for block in face.blocks { rest += [SIMD4(block.centre, 1), SIMD4(0, 0, 0, 1)] }
        let pose = try #require(device.makeBuffer(bytes: rest, length: 32 * bodies))
        let previous = try #require(device.makeBuffer(bytes: rest, length: 32 * bodies))
        let sizes = face.blocks.map(\.size)
        let last = try #require(firings.map(\.time).max())
        var frame = 0
        while Float(frame + 1) / 30 <= last + 1.5 {
            frame += 1
            _ = dust.step(
                pose: pose, previous: previous, bodies: bodies, time: Float(frame) / 30, restSize: sizes,
                frameRate: 30)
        }
        // Every cell's dust is under the bound of every cell within the reach of it.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quarry-dust-bound-\(ProcessInfo.processInfo.processIdentifier).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try dust.save(to: url)
        let data = try Data(contentsOf: url)
        let (nx, ny, nz) = (dust.dims.x, dust.dims.y, dust.dims.z)
        let bound = try hazeBound(dust)
        let reach = Int(dust.hazeReach)
        var thick = 0
        var unbounded = 0
        data.withUnsafeBytes { raw in
            let density = raw.baseAddress!.advanced(by: nx * ny * nz * 8).assumingMemoryBound(
                to: Float16.self)
            for k in 0..<nz {
                for j in 0..<ny {
                    for i in 0..<nx {
                        let d = Float(density[i + nx * (j + ny * k)])
                        guard d >= 0.5 else { continue }
                        thick += 1
                        // The box's corners and middle are enough to catch a bound too small.
                        for (x, y, z) in [
                            (i - reach, j - reach, k - reach), (i + reach, j + reach, k + reach),
                            (i - reach, j + reach, k), (i, j, k), (i + reach, j - reach, k - reach),
                        ] where x >= 0 && y >= 0 && z >= 0 && x < nx && y < ny && z < nz {
                            if bound[x + nx * (y + ny * z)] < d { unbounded += 1 }
                        }
                    }
                }
            }
        }
        #expect(thick > 100, "thick dust to bound: \(thick) cells")
        #expect(unbounded == 0, "cells whose bound is under dust within their reach: \(unbounded)")
        // The reach covers the march's warped lookup (5.1 m) and a cell's interpolation.
        #expect(Float(dust.hazeReach) * dust.h >= 5.1 + dust.h)
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
