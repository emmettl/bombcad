import BlastCore
import Foundation
import simd

/// Where the fireball's cloud went after a run, drawn over the scene as lines: the track of its
/// centre, its outline at intervals until it stopped rising, where it stopped, and its drift
/// across the ground.
public enum CloudOverlay {
    /// What a line shows, which sets its colour and width.
    public enum Kind: Int, Sendable {
        /// The track of the cloud's centre.
        case track = 0
        /// Its outline at an interval along the track.
        case outline = 1
        /// Its outline and height when it stopped rising.
        case stabilised = 2
        /// Its track across the ground below, and the line down to the ground from where it stopped.
        case ground = 3
    }

    /// The farthest the view's controls zoom out, in metres.
    public static let maximumDistance: Float = 600

    /// When the outlines stop: where the cloud stopped rising, or else its end.
    public static func end(_ result: CloudResult) -> Double {
        result.stabilised?.time ?? result.samples.last?.time ?? result.handOver.time
    }

    /// Seconds between the outlines drawn: a round number giving at most eight from the
    /// hand-over to `end`.
    public static func interval(_ result: CloudResult) -> Double {
        let span = end(result) - result.handOver.time
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800]
        return steps.first { span / $0 <= 8 } ?? 3600
    }

    /// The cloud at `time`, between the samples about it.
    public static func sample(_ result: CloudResult, at time: Double) -> CloudSample? {
        let samples = result.samples
        guard let first = samples.first, let last = samples.last, time >= first.time, time <= last.time else {
            return nil
        }
        let after = samples.firstIndex { $0.time >= time } ?? samples.count - 1
        guard after > 0 else { return first }
        let (a, b) = (samples[after - 1], samples[after])
        let f = b.time > a.time ? (time - a.time) / (b.time - a.time) : 0
        var sample = b
        sample.time = time
        sample.height = a.height + f * (b.height - a.height)
        sample.radius = a.radius + f * (b.radius - a.radius)
        sample.position = a.position + f * (b.position - a.position)
        return sample
    }

    private static func centre(_ sample: CloudSample) -> SIMD3<Float> {
        SIMD3(Float(sample.position.x), Float(sample.position.y), Float(sample.height))
    }

    /// The lines to draw from a view at `eye`: each two vectors, one end and the kind, and the
    /// other end and 0, as `SceneRenderer.setLines` takes them. The outlines are the spheres'
    /// silhouettes from the eye.
    public static func lines(_ result: CloudResult, eye: SIMD3<Float>) -> [SIMD4<Float>] {
        guard result.handOver.mass > 0, result.samples.count > 1 else { return [] }
        var lines: [SIMD4<Float>] = []
        func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ kind: Kind) {
            lines.append(SIMD4(a, Float(kind.rawValue)))
            lines.append(SIMD4(b, 0))
        }
        func circle(_ centre: SIMD3<Float>, _ axes: (SIMD3<Float>, SIMD3<Float>), radius: Float, _ kind: Kind)
        {
            let segments = 64
            var previous = centre + radius * axes.0
            for n in 1...segments {
                let angle = 2 * Float.pi * Float(n) / Float(segments)
                let next = centre + radius * (cos(angle) * axes.0 + sin(angle) * axes.1)
                line(previous, next, kind)
                previous = next
            }
        }
        func outline(_ sample: CloudSample, _ kind: Kind) {
            let middle = centre(sample)
            let view = eye - middle
            let distance = simd_length(view)
            let radius = Float(sample.radius)
            guard distance > radius * 1.01 else { return }
            let direction = view / distance
            let side =
                abs(direction.z) > 0.99
                ? SIMD3<Float>(1, 0, 0) : simd_normalize(simd_cross(direction, [0, 0, 1]))
            let up = simd_cross(side, direction)
            // The silhouette of a sphere seen from a point: nearer the eye than its centre, and smaller.
            let toward = radius * radius / distance
            circle(
                middle + toward * direction, (side, up),
                radius: (radius * radius - toward * toward).squareRoot(), kind)
        }

        let samples = result.samples
        for (a, b) in zip(samples, samples.dropFirst()) {
            line(centre(a), centre(b), .track)
            var (low, high) = (centre(a), centre(b))
            (low.z, high.z) = (0.05, 0.05)
            line(low, high, .ground)
        }
        let step = interval(result)
        var time = result.handOver.time
        while time < end(result) - 1e-9, let cloud = Self.sample(result, at: time) {
            outline(cloud, .outline)
            time += step
        }
        if let stopped = result.stabilised {
            let middle = centre(stopped)
            outline(stopped, .stabilised)
            circle(middle, ([1, 0, 0], [0, 1, 0]), radius: Float(stopped.radius), .stabilised)
            line(middle, SIMD3(middle.x, middle.y, 0.05), .ground)
        }
        return lines
    }

    /// The path from the hand-over to `end`, and the ground below it.
    public static func bounds(_ result: CloudResult) -> Box {
        let end = end(result)
        var low = SIMD3<Float>(repeating: .infinity)
        var high = SIMD3<Float>(repeating: -.infinity)
        for sample in result.samples where sample.time <= end + 1e-9 {
            let middle = centre(sample)
            let radius = Float(sample.radius)
            low = simd_min(low, middle - radius)
            high = simd_max(high, middle + radius)
        }
        low.z = 0
        return Box(min: low, max: high)
    }

    /// A view of the cloud from the side, a little above the ground: the whole of its path up to
    /// where it stopped rising if that is near enough to see whole, and otherwise the cloud where
    /// it stopped, over the ground below it.
    public static func framing(_ result: CloudResult) -> OrbitCamera {
        var box = bounds(result)
        let fieldOfView = OrbitCamera(target: .zero, distance: 1, azimuth: 0, elevation: 0).fieldOfView
        func distance(_ box: Box) -> Float {
            // Far enough for the box's diagonal to fill nine-tenths of the view's height.
            0.5 * simd_length(box.size) / tan(fieldOfView / 2) / 0.9
        }
        if distance(box) > maximumDistance, let stopped = result.stabilised ?? result.samples.last {
            let middle = centre(stopped)
            let radius = Float(stopped.radius)
            box = Box(
                min: SIMD3(middle.x - radius, middle.y - radius, 0),
                max: SIMD3(middle.x + radius, middle.y + radius, middle.z + radius))
        }
        // A little above the middle, which leaves the cloud's top in view when the view is as far
        // out as the controls go.
        var target = (box.min + box.max) / 2
        target.z = box.min.z + 0.55 * box.size.z
        return OrbitCamera(
            target: target, distance: min(max(distance(box), 3), maximumDistance),
            azimuth: -2.45, elevation: 0.35)
    }
}
