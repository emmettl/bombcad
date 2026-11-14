import Foundation
import simd

// Where a ridge cut is first seen from, and its sun (emmettl/bombcad-work#133). Chosen by eye, for
// the look: an opening view that shows the crest heave and break, the rock spill down the near
// flank and the notch form, with the cut's wall that faces the eye in the sun. Everything is in
// the cut's own frame (x along its line, y across, z up), so the view follows a moved cut.

/// An orbit camera, as the Quarry Face window's: about `focus`, `distance` away, `yaw` round and
/// `pitch` up (radians); yaw 0 looks from -y, yaw π/2 from +x.
public struct QuarryOrbit: Sendable, Equatable {
    public var focus: SIMD3<Float>
    public var yaw: Float
    public var pitch: Float
    public var distance: Float

    public init(focus: SIMD3<Float>, yaw: Float, pitch: Float, distance: Float) {
        self.focus = focus
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
    }

    /// From the focus toward the eye.
    public var direction: SIMD3<Float> {
        SIMD3(sin(yaw) * cos(pitch), -cos(yaw) * cos(pitch), sin(pitch))
    }

    public var eye: SIMD3<Float> { focus + direction * distance }
}

extension QuarryOrbit {
    /// A face's opening view, the Quarry Face window's default: from the floor in front of the
    /// strip's near end, toward its middle. Here, not in the window, so the dust's wind can be set
    /// across it (stage 3l, emmettl/bombcad-work#146).
    public static func faceOpening(_ face: QuarryFace) -> QuarryOrbit {
        let scale = face.length / 180
        return QuarryOrbit(
            focus: SIMD3(68 * scale, 15, face.floorLevel + 21), yaw: -0.81, pitch: -0.086,
            distance: 143 * max(1, scale * 0.85))
    }
}

/// A ridge cut's opening view and the sun it is lit by.
public struct QuarryRidgeView: Sendable, Equatable {
    public var orbit: QuarryOrbit
    /// Toward the sun (not normalised), in the cut's frame.
    public var sun: SIMD3<Float>
    /// The flank the eye is off: +1 past the line's end, -1 before its start.
    public var flank: Float
    /// The side of the line the eye is on: -1 its right (y < 0), +1 its left.
    public var side: Float

    /// The orbit's yaw off the line, before any turn to see past ground in the way (radians).
    public static let yawOffLine: Float = 0.95
    /// How far off, for the notch's width at its top (the floor's plus its two walls') and the
    /// cut's depth, and least (m).
    public static let distanceForNotch: Float = 1.5
    public static let nearest: Float = 80
    /// The eye's height against the crest's (m): a little under it, so the crest and the notch
    /// stand against the sky and the heave lifts the skyline.
    public static let eyeOverCrest: Float = -2
    /// The sun as stage 1 had it for the view off the line's end on its right: low (18°), along the
    /// ridge from the side the eye is on and a little from behind the eye, so that the wall facing
    /// the eye is lit and the near flank raked.
    static let sunOffLine = SIMD3<Float>(-0.3, -0.88, 0.3)

    /// The opening view of `face`'s ridge cut, nil for a face. Off the steeper flank (the rock runs
    /// furthest down it), a little to the side of the line so the walls and the notch show, a little
    /// under the crest's height and about one and a half notch-widths off; turned or raised until
    /// nothing of the ground (after the cut) stands between the eye and the crest either side of
    /// the cut or what it looks at.
    public static func opening(_ face: QuarryFace) -> QuarryRidgeView? {
        guard let ridge = face.ridge else { return nil }
        // The ground after the cut where the face has it, else the old ground.
        let t = face.terrain
        let high = t.origin + SIMD2(Float(t.columns - 2), Float(t.rows - 2)) * t.spacing
        func ground(_ x: Float, _ y: Float) -> Float {
            guard x > t.origin.x, y > t.origin.y, x < high.x, y < high.y else { return face.oldHeight(x, y) }
            return face.height(t.heights, x, y)
        }
        // The steeper flank: the old ground's drop over 30 m from the crest along the line.
        let crestX = ridge.crestX
        let dropAfter = ridge.crest - face.oldHeight(crestX + 30, 0)
        let dropBefore = ridge.crest - face.oldHeight(crestX - 30, 0)
        let preferred: Float = dropAfter >= dropBefore ? 1 : -1
        let depth = ridge.crest - ridge.floor
        let notch = 2 * (ridge.halfWidth + depth / ridge.wallSlope)
        let distance = max(nearest, distanceForNotch * notch + depth)
        for flank in [preferred, -preferred] {
            // The focus: on the line, a fifth of the way from the crest to where the notch runs out
            // on the far flank (the notch shows in the skyline between the two), and high in the
            // cut, so the crest sits a little above the frame's middle with sky over it.
            let far = flank > 0 ? ridge.cutStart : ridge.cutEnd
            let focus = SIMD3(crestX + 0.15 * (far - crestX), 0, ridge.floor + 0.65 * depth)
            // The side of the line: its right off the line's end, its left off its start, so the
            // eye and the sun stand in the same place on the ground whichever way the line was drawn.
            for side in [-flank, flank] {
                for turn: Float in [0, 0.2, -0.2, 0.4, -0.4] {
                    // Off the line by `yawOffLine` (and the turn), toward the side.
                    let off = yawOffLine + turn
                    let yaw = flank * (side < 0 ? off : .pi - off)
                    for lift: Float in [0, 6, 12, 20, 32] {
                        let height = ridge.crest + eyeOverCrest + lift - focus.z
                        let pitch = asin(max(-0.2, min(0.9, height / distance)))
                        let orbit = QuarryOrbit(focus: focus, yaw: yaw, pitch: pitch, distance: distance)
                        guard clear(orbit, ridge: ridge, ground: ground) else { continue }
                        let sun = SIMD3(sunOffLine.x * flank, sunOffLine.y * -side, sunOffLine.z)
                        return QuarryRidgeView(orbit: orbit, sun: sun, flank: flank, side: side)
                    }
                }
            }
        }
        // Nothing clear: from high above the near flank.
        let focus = SIMD3(crestX, 0, ridge.floor + 0.65 * depth)
        let yaw = preferred > 0 ? yawOffLine : -(Float.pi - yawOffLine)
        return QuarryRidgeView(
            orbit: QuarryOrbit(focus: focus, yaw: yaw, pitch: 0.6, distance: distance),
            sun: SIMD3(sunOffLine.x * preferred, sunOffLine.y * preferred, sunOffLine.z), flank: preferred,
            side: -preferred)
    }

    /// Whether the eye stands clear of `ground` and sees, over it, the focus and the crest's top
    /// either side of the cut (sampled every 2 m, with half a metre to spare; the last 6 m to each
    /// point are its own ground).
    static func clear(_ orbit: QuarryOrbit, ridge: QuarryRidge, ground: (Float, Float) -> Float) -> Bool {
        let eye = orbit.eye
        guard eye.z > ground(eye.x, eye.y) + 4 else { return false }
        let wall = ridge.halfWidth + (ridge.crest - ridge.floor) / ridge.wallSlope + 3
        let targets = [
            orbit.focus,
            SIMD3(ridge.crestX, wall, ground(ridge.crestX, wall) + 1),
            SIMD3(ridge.crestX, -wall, ground(ridge.crestX, -wall) + 1),
        ]
        for target in targets {
            let length = simd_distance(eye, target)
            var t: Float = 0
            while t < length - 6 {
                let p = eye + (target - eye) * (t / length)
                if p.z < ground(p.x, p.y) + 0.5 { return false }
                t += 2
            }
        }
        return true
    }
}

/// The Record Clip camera's pull-back: close in on what the view looks at (nearer, a longer lens,
/// aimed a little higher, where the rock is thrown) until just after the first firing, then back to
/// the view as it stands while the rock spills, eased at both ends. Timed by the event's own
/// seconds, so it is the same moment at any clip speed. Chosen by eye.
public enum QuarryPullBack {
    /// Where a pull-back starts and when it moves.
    public struct Shot: Sendable, Equatable {
        /// At the start: the share of the view's distance, of its field, and how much higher it
        /// aims, as a share of its distance.
        public var startDistance: Float
        public var startField: Float
        public var startAim: Float
        /// Event seconds after the first firing the move begins, and how long it takes.
        public var delay: Float
        public var seconds: Float
        /// At the start, how far it aims to the frame's right, as a share of the view's distance.
        public var startAcross: Float

        public init(
            startDistance: Float, startField: Float, startAim: Float, delay: Float, seconds: Float,
            startAcross: Float = 0
        ) {
            self.startDistance = startDistance
            self.startField = startField
            self.startAim = startAim
            self.delay = delay
            self.seconds = seconds
            self.startAcross = startAcross
        }
    }

    /// A face's (stage 2b's, as it was).
    public static let face = Shot(startDistance: 0.7, startField: 0.55, startAim: 0.1, delay: 0.7, seconds: 5)
    /// A ridge cut's (stage 3i, emmettl/bombcad-work#143): the crest now heaves as one dome up to
    /// about 9 m (stage 3f), which filled the face's close, long-lens opening with rock by 1.6 s.
    /// It opens wider and a little further off, with sky over the crest, so the whole crest is
    /// seen swelling, and moves out sooner, as the dome breaks. Since stage 3j
    /// (emmettl/bombcad-work#144) it aims a little to the right and lower, where the crest's far
    /// end ran off the frame and sky filled its top half.
    public static let ridge = Shot(
        startDistance: 0.8, startField: 0.82, startAim: 0.06, delay: 0, seconds: 4, startAcross: 0.055)

    /// How far through the move it is at event time `time` (0 close in, 1 the view), eased.
    public static func progress(time: Float, firstFiring: Float, shot: Shot = face) -> Float {
        let s = max(0, min(1, (time - firstFiring - shot.delay) / shot.seconds))
        return s * s * (3 - 2 * s)
    }

    /// The camera at event time `time` for a view `orbit` with a field of `fovY`: its eye, what it
    /// looks at and its field.
    public static func view(
        orbit: QuarryOrbit, fovY: Float, time: Float, firstFiring: Float, shot: Shot = face
    )
        -> (eye: SIMD3<Float>, target: SIMD3<Float>, fovY: Float)
    {
        let p = progress(time: time, firstFiring: firstFiring, shot: shot)
        let distance = orbit.distance * (shot.startDistance + (1 - shot.startDistance) * p)
        // The frame's right, level.
        let right = simd_normalize(SIMD3(-orbit.direction.y, orbit.direction.x, 0))
        let target =
            orbit.focus + SIMD3(0, 0, orbit.distance * shot.startAim * (1 - p))
            + right * (orbit.distance * shot.startAcross * (1 - p))
        return (
            orbit.focus + orbit.direction * distance, target,
            fovY * (shot.startField + (1 - shot.startField) * p)
        )
    }
}
