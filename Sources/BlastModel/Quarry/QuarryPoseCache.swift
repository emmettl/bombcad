import Foundation
import simd

/// A quarry event's poses, packed for replay and scrubbing: every `stride`-th frame is stored, and
/// the frames between are interpolated. Each stored block takes 10 bytes: its position as three
/// 16-bit fractions of the domain (6 mm over 380 m) and its orientation as the smallest three of
/// its quaternion in 10 bits each. Blocks that never move (the held skin) are not stored. A
/// block's release frame is kept apart, for the renderer's shading of moved rock.
///
/// One thread may store frames in order while another decodes: the cache fills as the event is
/// simulated, and any frame below `available` can be decoded while later ones are still being
/// stored (emmettl/bombcad-work#126).
public final class QuarryPoseCache: @unchecked Sendable {
    public let bodies: Int
    public let frames: Int
    public let stride: Int
    public let low: SIMD3<Float>
    public let high: SIMD3<Float>
    /// Index among the stored blocks, or -1 for a block that never moves.
    private let slot: [Int32]
    private let rest: [SIMD4<Float>]
    private let moving: Int
    private let positions: UnsafeMutablePointer<UInt16>
    private let orientations: UnsafeMutablePointer<UInt32>
    /// Each block's release frame, or `UInt16.max` while held. Written only by `store`, for frames
    /// past `available`; a reader compares it with a frame it may decode, so a value being written
    /// reads as "not yet" either way.
    private let releaseFrames: UnsafeMutablePointer<UInt16>
    private let lock = NSLock()
    private var storedFrames = 0

    /// `rest` gives each block's starting pose (pairs: position with w unused, then orientation);
    /// `still` marks the blocks that never move.
    public init(
        rest: [SIMD4<Float>], still: [Bool], frames: Int, low: SIMD3<Float>, high: SIMD3<Float>,
        stride: Int = 2
    ) {
        bodies = still.count
        self.frames = frames
        self.stride = max(1, stride)
        self.low = low
        self.high = high
        self.rest = rest
        var slot = [Int32](repeating: -1, count: still.count)
        var count: Int32 = 0
        for n in still.indices where !still[n] {
            slot[n] = count
            count += 1
        }
        self.slot = slot
        moving = Int(count)
        let stored = Self.storedCount(frames: frames, stride: self.stride)
        positions = .allocate(capacity: max(1, stored * moving * 3))
        orientations = .allocate(capacity: max(1, stored * moving))
        releaseFrames = .allocate(capacity: max(1, still.count))
        releaseFrames.initialize(repeating: UInt16.max, count: max(1, still.count))
    }

    deinit {
        positions.deallocate()
        orientations.deallocate()
        releaseFrames.deallocate()
    }

    /// Frames stored so far: frame `filled - 1` was the last.
    public var filled: Int { lock.withLock { storedFrames } }

    /// Frames from the first that can be decoded now: all of them once the event is stored, else
    /// up to the last stored keyframe (the frames after it wait for the next one).
    public var available: Int {
        let filled = self.filled
        if filled >= frames { return frames }
        return filled == 0 ? 0 : (filled - 1) / stride * stride + 1
    }

    /// Whether every frame has been stored.
    public var isComplete: Bool { filled >= frames }

    /// The frame a block was released at, or nil if it is held at every frame stored so far.
    public func release(_ n: Int) -> Int? {
        releaseFrames[n] == UInt16.max ? nil : Int(releaseFrames[n])
    }

    static func storedCount(frames: Int, stride: Int) -> Int { (frames - 1) / stride + 2 }

    /// Bytes held.
    public var bytes: Int {
        Self.storedCount(frames: frames, stride: stride) * moving * 10 + bodies * (2 + 4 + 32)
    }

    /// The stored index of a frame: every `stride`-th, and the last.
    private func storedIndex(_ f: Int) -> Int? {
        if f % stride == 0 { return f / stride }
        if f == frames - 1 { return f / stride + 1 }
        return nil
    }

    /// Smallest-three packing of a unit quaternion: the largest component's index in two bits.
    public static func pack(_ q: SIMD4<Float>) -> UInt32 {
        var largest = 0
        for i in 1..<4 where abs(q[i]) > abs(q[largest]) { largest = i }
        let sign: Float = q[largest] < 0 ? -1 : 1
        var word = UInt32(largest) << 30
        var shift: UInt32 = 20
        for i in 0..<4 where i != largest {
            let v = q[i] * sign * 0.7072 + 0.5
            word |= UInt32(max(0, min(1023, v * 1023 + 0.5))) << shift
            shift = shift &- 10
        }
        return word
    }

    public static func unpack(_ word: UInt32) -> SIMD4<Float> {
        let largest = Int(word >> 30)
        var q = SIMD4<Float>(repeating: 0)
        var sum: Float = 0
        var shift: UInt32 = 20
        for i in 0..<4 where i != largest {
            let v = (Float((word >> shift) & 1023) / 1023 - 0.5) / 0.7072
            q[i] = v
            sum += v * v
            shift = shift &- 10
        }
        q[largest] = sqrt(max(0, 1 - sum))
        return q
    }

    /// Stores frame `f` from `pose` (pairs of float4; w of the first is the block's state, 0 held).
    /// Frames are stored in order, from one thread at a time.
    public func store(frame f: Int, pose: UnsafePointer<SIMD4<Float>>) {
        for n in 0..<bodies where releaseFrames[n] == UInt16.max && pose[2 * n].w >= 0.5 {
            releaseFrames[n] = UInt16(f)
        }
        defer { lock.withLock { storedFrames = max(storedFrames, f + 1) } }
        guard let k = storedIndex(f) else { return }
        nonisolated(unsafe) let p = positions + k * moving * 3
        nonisolated(unsafe) let o = orientations + k * moving
        nonisolated(unsafe) let input = pose
        let slots = slot
        let (low, scale) = (low, 65535 / simd_max(high - low, SIMD3(repeating: 1e-3)))
        let chunk = 8192
        DispatchQueue.concurrentPerform(iterations: (bodies + chunk - 1) / chunk) { c in
            for n in (c * chunk)..<min(slots.count, (c + 1) * chunk) {
                let s = Int(slots[n])
                guard s >= 0 else { continue }
                let x = input[2 * n]
                let q = simd_clamp((SIMD3(x.x, x.y, x.z) - low) * scale, .zero, SIMD3(repeating: 65535))
                p[3 * s] = UInt16(q.x.rounded())
                p[3 * s + 1] = UInt16(q.y.rounded())
                p[3 * s + 2] = UInt16(q.z.rounded())
                o[s] = Self.pack(input[2 * n + 1])
            }
        }
    }

    /// Frame `f` into `pose`, interpolated between stored frames. `f` is held below `available`.
    public func decode(frame f: Int, into pose: UnsafeMutablePointer<SIMD4<Float>>) {
        let f = max(0, min(available - 1, f))
        let a = f / stride
        let b: Int
        let t: Float
        if f % stride == 0 {
            (b, t) = (a, 0)
        } else if f / stride * stride + stride > frames - 1 {
            (b, t) = (a + 1, Float(f - a * stride) / Float(frames - 1 - a * stride))
        } else {
            (b, t) = (a + 1, Float(f % stride) / Float(stride))
        }
        nonisolated(unsafe) let pa = positions + a * moving * 3
        nonisolated(unsafe) let pb = positions + b * moving * 3
        nonisolated(unsafe) let oa = orientations + a * moving
        nonisolated(unsafe) let ob = orientations + b * moving
        nonisolated(unsafe) let target = pose
        let (slots, rest) = (slot, rest)
        nonisolated(unsafe) let released = UnsafePointer(releaseFrames)
        let (low, scale) = (low, simd_max(high - low, SIMD3(repeating: 1e-3)) / 65535)
        let chunk = 8192
        DispatchQueue.concurrentPerform(iterations: (bodies + chunk - 1) / chunk) { c in
            for n in (c * chunk)..<min(slots.count, (c + 1) * chunk) {
                let s = Int(slots[n])
                let w: Float = released[n] != UInt16.max && Int(released[n]) <= f ? 1 : 0
                guard s >= 0 else {
                    target[2 * n] = SIMD4(rest[2 * n].x, rest[2 * n].y, rest[2 * n].z, w)
                    target[2 * n + 1] = rest[2 * n + 1]
                    continue
                }
                func position(_ p: UnsafeMutablePointer<UInt16>) -> SIMD3<Float> {
                    low + SIMD3(Float(p[3 * s]), Float(p[3 * s + 1]), Float(p[3 * s + 2])) * scale
                }
                let x = position(pa) + (position(pb) - position(pa)) * t
                var q0 = Self.unpack(oa[s])
                let q1 = Self.unpack(ob[s])
                if simd_dot(q0, q1) < 0 { q0 = -q0 }
                target[2 * n] = SIMD4(x, w)
                target[2 * n + 1] = simd_normalize(q0 + (q1 - q0) * t)
            }
        }
    }
}
