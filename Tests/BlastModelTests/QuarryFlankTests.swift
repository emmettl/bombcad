import Testing
import simd

@testable import BlastModel

/// A ridge cut's flanks as ground: the dense rock round the cut, the ledges, scree and grass, and
/// the render-only stones and scrub (emmettl/bombcad-work#135). Illustrative scene; these are
/// consistency checks, not a measure of how it looks.
@Suite("Ridge cut flanks", .serialized)
struct QuarryFlankTests {
    static let face: QuarryFace = {
        var options = QuarryFace.Options()
        options.blocks = 3000
        options.meshDetail = 1
        return try! QuarryFace(site: QuarrySite.builtInRidge(), options: options)
    }()

    @Test("A face has no flanks; a ridge cut's dense rock is the cut and a ragged margin round it")
    func paving() throws {
        var options = QuarryFace.Options()
        options.blocks = 3000
        #expect(QuarryFlank(face: try QuarryFace(site: QuarrySite.builtIn(), options: options)) == nil)
        let flank = try #require(QuarryFlank(face: Self.face))
        let ridge = try #require(Self.face.ridge)
        let reach = QuarryFlank.margin + QuarryFlank.marginWander + 1.5
        var cutTexels = 0
        for n in 0..<(flank.columns * flank.rows) {
            if flank.cut[n] > 0.5 {
                cutTexels += 1
                #expect(flank.paving[n])
            }
            if flank.paving[n] {
                #expect(flank.cutDistance[n] <= reach)
                #expect(flank.grass[n] == 0)
            }
        }
        // The cut is about its volume over its depth in plan, at least.
        #expect(Float(cutTexels) > ridge.cutVolume / (ridge.crest - ridge.floor))
        // The steep ground is set back only inside the dense rock, and fully only well inside it.
        let (x, y) = flank.position(flank.columns / 2, 2)
        #expect(flank.setBack(x, y) == 0)
    }

    @Test("Ledges crop out of the slopes clear of the cut, in beds that are not shale, on the ground")
    func ledges() throws {
        let flank = try #require(QuarryFlank(face: Self.face))
        #expect(flank.ledges.count > 100)
        for ledge in flank.ledges {
            let n = try #require(flank.texel(ledge.contour.x, ledge.contour.y))
            #expect(!flank.paving[n])
            #expect(simd_length(flank.gradient[n]) > QuarryFlank.ledgeSlope * 0.5)
            #expect(QuarryRock.kind(bed: ledge.bed) != .shale)
            #expect(ledge.top > ledge.bottom + 0.6)
            #expect(abs(ledge.contour.z - flank.groundHeight(ledge.contour.x, ledge.contour.y)) < 0.6)
            #expect(ledge.run >= 0.6 && ledge.run <= 3.2)
            // Downhill is down the slope.
            let ahead = SIMD2(ledge.contour.x, ledge.contour.y) + ledge.downhill * 2
            #expect(flank.groundHeight(ahead.x, ahead.y) < ledge.contour.z)
        }
        // Each made into rock.
        var face = Self.face
        let made = face.appendLedges(flank, level: 1)
        #expect(Float(made) > 0.9 * Float(flank.ledges.count))
        #expect(face.dressingIndices.count > 3 * 8 * made)
        let corners = face.dressingVertices.map { SIMD3($0.x, $0.y, $0.z) }
        let lowest = flank.ledges.map { $0.bottom }.min()! - 2
        #expect(corners.allSatisfy { $0.z > lowest })
    }

    @Test("Scree lies below the ledges more than on open gentle ground, and grass on the gentle ground")
    func cover() throws {
        let flank = try #require(QuarryFlank(face: Self.face))
        var below: [Float] = []
        for ledge in flank.ledges {
            let p = SIMD2(ledge.contour.x, ledge.contour.y) + ledge.downhill * (ledge.run + 2.5)
            if let n = flank.texel(p.x, p.y) { below.append(flank.scree[n]) }
        }
        var gentleScree: [Float] = []
        var gentleGrass: [Float] = []
        var steepGrass: [Float] = []
        for n in 0..<(flank.columns * flank.rows) where !flank.paving[n] {
            let slope = simd_length(flank.gradient[n])
            if slope < 0.15 {
                gentleScree.append(flank.scree[n])
                gentleGrass.append(flank.grass[n])
            } else if slope > 0.9 {
                steepGrass.append(flank.grass[n])
            }
        }
        func mean(_ v: [Float]) -> Float { v.reduce(0, +) / Float(max(v.count, 1)) }
        #expect(mean(below) > 0.4)
        #expect(mean(gentleScree) < 0.1)
        #expect(mean(gentleGrass) > 0.35)
        #expect(steepGrass.isEmpty || mean(steepGrass) < 0.1)
    }

    @Test("Stones lie on the scree and scrub on the grass, on the ground, the same each time")
    func stones() throws {
        let flank = try #require(QuarryFlank(face: Self.face))
        let stones = flank.stones()
        #expect(stones.count > 2000)
        var shrubs = 0
        for stone in stones {
            let p = stone.posSize
            let n = try #require(flank.texel(p.x, p.y))
            #expect(!flank.paving[n] && flank.cut[n] < 0.5)
            #expect(abs(p.z - flank.groundHeight(p.x, p.y)) < p.w)
            #expect(abs(simd_length(stone.rotation) - 1) < 1e-3)
            if stone.look.x > 0.5 {
                shrubs += 1
                #expect(flank.grass[n] > 0 || flank.grass[max(0, n - 1)] > 0)
            }
        }
        #expect(shrubs > 100 && shrubs < stones.count / 2)
        let again = try #require(QuarryFlank(face: Self.face)).stones()
        #expect(again.map(\.posSize) == stones.map(\.posSize))
        #expect(flank.stones(scale: 0.5).count < stones.count * 3 / 4)
    }
}
