import Testing
import simd

@testable import BlastModel

/// A ridge cut's opening view and sun, and Record Clip's pull-back (emmettl/bombcad-work#133):
/// the view is framed on the cut from its own geometry, so it follows a moved, turned, resized or
/// reversed cut. Illustrative scene; these are consistency checks on the framing.
@Suite("Ridge cut view", .serialized)
struct QuarryRidgeViewTests {
    static let ridge = QuarrySite.builtInRidge()

    /// The view's eye and focus, and the sun, on the ground (x, y in the terrain's metres, z up).
    static func onGround(_ face: QuarryFace, _ view: QuarryRidgeView) -> (
        eye: SIMD3<Float>, focus: SIMD3<Float>, sun: SIMD3<Float>
    ) {
        func place(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(face.world(SIMD2(p.x, p.y)), p.z) }
        let sun2 = face.along * view.sun.x + face.inward * view.sun.y
        return (place(view.orbit.eye), place(view.orbit.focus), SIMD3(sun2, view.sun.z))
    }

    @Test(
        "The built-in cut is seen from off its steeper flank, close, a little under the crest, with nothing in the way"
    )
    func builtIn() throws {
        let face = try QuarryFace(site: Self.ridge)
        let ridge = try #require(face.ridge)
        let view = try #require(QuarryRidgeView.opening(face))
        let orbit = view.orbit
        // The built-in ridge's steeper flank is past the crest along the line (+x).
        #expect(view.flank == 1 && view.side == -1)
        #expect(abs(orbit.yaw - QuarryRidgeView.yawOffLine) < 1e-5)
        // It looks into the cut, between its walls, high in it, near the crest.
        #expect(abs(orbit.focus.y) < ridge.halfWidth)
        #expect(orbit.focus.x > ridge.cutStart && orbit.focus.x < ridge.crestX + 1)
        #expect(
            orbit.focus.z > ridge.floor + 0.5 * (ridge.crest - ridge.floor) && orbit.focus.z < ridge.crest)
        // About 94 m off: half stage 1's 189 m.
        #expect(orbit.distance > 85 && orbit.distance < 105, "\(orbit.distance)")
        let eye = orbit.eye
        #expect(eye.x > ridge.crestX + 40 && eye.y < -30)
        #expect(abs(eye.z - (ridge.crest + QuarryRidgeView.eyeOverCrest)) < 0.5)
        #expect(eye.z > face.oldHeight(eye.x, eye.y) + 10)
        #expect(
            QuarryRidgeView.clear(orbit, ridge: ridge) { face.height(face.terrain.heights, $0, $1) })
        // The sun as stage 1 had it for this view: low, from the eye's side along the ridge.
        #expect(simd_distance(view.sun, SIMD3(-0.3, -0.88, 0.3)) < 1e-5)
        // A face has none.
        #expect(QuarryRidgeView.opening(try QuarryFace(site: .builtIn())) == nil)
    }

    @Test("A cut moved along the ridge, or drawn the other way, is framed the same on the ground")
    func followsTheCut() throws {
        let base = try QuarryFace(site: Self.ridge)
        let baseView = try #require(QuarryRidgeView.opening(base))
        let a = Self.onGround(base, baseView)
        // Drawn from the other end: the steeper flank is now before the line's start.
        var reversed = Self.ridge
        (reversed.start, reversed.end) = (reversed.end, reversed.start)
        let back = try QuarryFace(site: reversed)
        let backView = try #require(QuarryRidgeView.opening(back))
        #expect(backView.flank == -1 && backView.side == 1)
        let b = Self.onGround(back, backView)
        #expect(simd_distance(a.eye, b.eye) < 2, "\(a.eye) \(b.eye)")
        #expect(simd_distance(a.focus, b.focus) < 2, "\(a.focus) \(b.focus)")
        #expect(simd_distance(a.sun, b.sun) < 1e-4)
        // Moved 150 m along the ridge: the view goes with it, looking at the new cut's crest.
        var moved = Self.ridge
        moved.start += SIMD2(0, 150)
        moved.end += SIMD2(0, 150)
        let there = try QuarryFace(site: moved)
        let thereRidge = try #require(there.ridge)
        let thereView = try #require(QuarryRidgeView.opening(there))
        let c = Self.onGround(there, thereView)
        let crest = there.world(SIMD2(thereRidge.crestX, 0))
        #expect(simd_distance(SIMD2(c.focus.x, c.focus.y), crest) < 20)
        #expect(abs(c.focus.y - a.focus.y - 150) < 15)
        #expect(abs(thereView.orbit.distance - baseView.orbit.distance) < 10)
        #expect(
            QuarryRidgeView.clear(thereView.orbit, ridge: thereRidge) {
                there.height(there.terrain.heights, $0, $1)
            })
    }

    @Test(
        "A turned copy of the ridge gives the same view in the cut's frame; a bigger cut is seen from further off"
    )
    func turnedAndResized() throws {
        // The middle of the built-in ridge turned a quarter round and moved, as a project's might be.
        let built = Self.ridge.terrain
        let size = 501
        let first = SIMD2<Float>(-250, -250)
        var heights = [Float](repeating: 0, count: size * size)
        for j in 0..<size {
            for i in 0..<size {
                heights[i + size * j] = built.height(at: first + SIMD2(Float(j), Float(size - 1 - i)))
            }
        }
        let origin = SIMD2<Float>(3000, -7000)
        let turned = Terrain(origin: origin, spacing: 1, columns: size, rows: size, heights: heights)
        func place(_ p: SIMD2<Float>) -> SIMD2<Float> {
            origin + SIMD2(Float(size - 1) - (p.y - first.y), p.x - first.x)
        }
        let base = Self.ridge
        let site = QuarrySite(
            terrain: turned, start: place(base.start), end: place(base.end), depth: base.depth,
            scene: .ridgeCut, width: base.width)
        let a = try #require(QuarryRidgeView.opening(try QuarryFace(site: base)))
        let b = try #require(QuarryRidgeView.opening(try QuarryFace(site: site)))
        #expect(simd_distance(a.orbit.eye, b.orbit.eye) < 2)
        #expect(simd_distance(a.orbit.focus, b.orbit.focus) < 1.5)
        #expect(a.sun == b.sun)
        // The cut a terrain starts with (as a file's or a project's ground does) is framed too.
        let suggested = try #require(QuarryStripGuide.suggestRidgeCut(terrain: turned))
        let opened = try QuarryFace(
            site: QuarrySite(terrain: turned, start: suggested.start, end: suggested.end, scene: .ridgeCut))
        let firstRidge = try #require(opened.ridge)
        let firstView = try #require(QuarryRidgeView.opening(opened))
        #expect(
            QuarryRidgeView.clear(firstView.orbit, ridge: firstRidge) {
                opened.height(opened.terrain.heights, $0, $1)
            })
        #expect(abs(firstView.orbit.focus.y) < firstRidge.halfWidth)

        var big = base
        big.width = QuarryRidge.widths.upperBound
        big.depth = QuarryRidge.depths.upperBound
        let bigView = try #require(QuarryRidgeView.opening(try QuarryFace(site: big)))
        #expect(bigView.orbit.distance > a.orbit.distance + 15)
        var small = base
        small.width = QuarryRidge.widths.lowerBound
        small.depth = 12
        let smallView = try #require(QuarryRidgeView.opening(try QuarryFace(site: small)))
        #expect(smallView.orbit.distance == QuarryRidgeView.nearest)
    }

    @Test("A hill in front of the default eye turns or raises the view until the crest is in sight")
    func groundInTheWay() throws {
        let base = try QuarryFace(site: Self.ridge)
        let usual = try #require(QuarryRidgeView.opening(base)).orbit
        // A knoll 50 m high, 25 m round, standing between the default eye and the cut.
        let t = Self.ridge.terrain
        let between = base.world(SIMD2((usual.eye.x + usual.focus.x) / 2, (usual.eye.y + usual.focus.y) / 2))
        var heights = t.heights
        for j in 0..<t.rows {
            for i in 0..<t.columns {
                let p = t.origin + SIMD2(Float(i), Float(j)) * t.spacing
                let d = simd_distance(p, between)
                heights[i + t.columns * j] += 50 * max(0, 1 - d / 25)
            }
        }
        var site = Self.ridge
        site.terrain = Terrain(
            origin: t.origin, spacing: t.spacing, columns: t.columns, rows: t.rows, heights: heights)
        let face = try QuarryFace(site: site)
        let ridge = try #require(face.ridge)
        let view = try #require(QuarryRidgeView.opening(face))
        #expect(view.orbit != usual)
        let ground = { (x: Float, y: Float) in face.height(face.terrain.heights, x, y) }
        #expect(!QuarryRidgeView.clear(usual, ridge: ridge, ground: ground))
        #expect(QuarryRidgeView.clear(view.orbit, ridge: ridge, ground: ground))
    }

    @Test(
        "The pull-back holds close in until just after the first firing, then eases out to the view",
        arguments: [QuarryPullBack.face, QuarryPullBack.ridge])
    func pullBack(shot: QuarryPullBack.Shot) {
        let orbit = QuarryOrbit(focus: SIMD3(70, 0, 30), yaw: 0.95, pitch: 0.07, distance: 94)
        let fov: Float = 0.56
        let first: Float = 1.8
        let start = QuarryPullBack.view(orbit: orbit, fovY: fov, time: 0, firstFiring: first, shot: shot)
        let held = QuarryPullBack.view(
            orbit: orbit, fovY: fov, time: first + shot.delay, firstFiring: first, shot: shot)
        #expect(start == held)
        #expect(abs(simd_distance(start.eye, orbit.focus) - shot.startDistance * 94) < 1e-3)
        #expect(abs(start.fovY - shot.startField * fov) < 1e-6)
        #expect(start.target.z > orbit.focus.z + 5)
        let end = QuarryPullBack.view(orbit: orbit, fovY: fov, time: 20, firstFiring: first, shot: shot)
        #expect(simd_distance(end.eye, orbit.eye) < 1e-3 && end.target == orbit.focus && end.fovY == fov)
        // Out the whole way, never back in, on the view's own line.
        var last: Float = 0
        for k in 0...100 {
            let t = Float(k) * 0.1
            let v = QuarryPullBack.view(orbit: orbit, fovY: fov, time: t, firstFiring: first, shot: shot)
            let d = simd_distance(v.eye, orbit.focus)
            #expect(d >= last - 1e-4)
            #expect(simd_distance(simd_normalize(v.eye - orbit.focus), orbit.direction) < 1e-4)
            last = d
        }
        #expect(
            QuarryPullBack.progress(time: first + shot.delay + shot.seconds, firstFiring: first, shot: shot)
                == 1)
    }

    @Test(
        "A ridge cut's pull-back opens wider than a face's, for the whole crest's dome, and moves out sooner")
    func ridgePullBackOpensWider() {
        let ridge = QuarryPullBack.ridge
        let face = QuarryPullBack.face
        #expect(ridge.startField > face.startField && ridge.startDistance >= face.startDistance)
        #expect(ridge.delay < face.delay)
    }
}
