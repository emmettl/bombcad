import AVFoundation
import BlastCore
import BlastModel
import CoreVideo
import Foundation
import Metal
import simd

extension QuarryRenderer {
    /// Copies the frame into a new pixel buffer for AVFoundation.
    public func pixelBuffer(pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let pixel = out else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        output.getBytes(
            CVPixelBufferGetBaseAddress(pixel)!, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixel
    }
}

/// Writes a renderer's frames to an H.264 movie, one call a frame, in order.
public final class QuarryClipWriter {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    public private(set) var frame = 0
    let fps: Int32

    public init(url: URL, width: Int, height: Int, fps: Int32, bitrate: Int = 10_000_000) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
            ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        self.fps = fps
    }

    public func append(_ renderer: QuarryRenderer) {
        guard let pool = adaptor.pixelBufferPool, let pixel = renderer.pixelBuffer(pool: pool) else { return }
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
        adaptor.append(pixel, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        frame += 1
    }

    /// Ends the movie; returns once it is written.
    public func finish() {
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
    }

    /// Stops without a movie.
    public func abandon() {
        writer.cancelWriting()
    }
}

/// Where a clip looks from: the window's orbit as it stands, held still, turned slowly round its
/// focus over the clip, or pulled back to it from close in as the rock lets go.
public struct QuarryClipCamera: Sendable, Equatable {
    public enum Motion: String, CaseIterable, Sendable {
        case still = "This view"
        case orbit = "Slow orbit"
        /// Close in on what the view looks at until just after the first firing, then back to this
        /// view as the rock spills (`QuarryPullBack`), by event time, so at any speed it is the same
        /// moment.
        case pullBack = "Pull back"
    }
    public var focus: SIMD3<Float>
    public var yaw: Float
    public var pitch: Float
    public var distance: Float
    public var fovDegrees: Float
    public var motion = Motion.still
    /// The turn over the whole clip when orbiting (radians).
    public var turn: Float = 0.6
    /// The event's first firing (s), which a pull-back is timed from.
    public var firstFiring: Float = 1.8

    public init(focus: SIMD3<Float>, yaw: Float, pitch: Float, distance: Float, fovDegrees: Float) {
        self.focus = focus
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
        self.fovDegrees = fovDegrees
    }

    /// The view `share` of the way through the clip, at event time `time`, its eye kept above the
    /// ground as the window's orbit keeps it.
    public func view(at share: Float, time: Float = 0, face: QuarryFace) -> (
        eye: SIMD3<Float>, target: SIMD3<Float>, fovY: Float
    ) {
        if motion == .pullBack {
            var v = QuarryPullBack.view(
                orbit: QuarryOrbit(focus: focus, yaw: yaw, pitch: pitch, distance: distance),
                fovY: fovDegrees * .pi / 180, time: time, firstFiring: firstFiring)
            v.eye.z = max(v.eye.z, face.height(face.terrain.heights, v.eye.x, v.eye.y) + 2)
            return v
        }
        let s = max(0, min(1, share))
        // Eased at both ends, so the turn starts and stops gently.
        let eased = s * s * (3 - 2 * s)
        let yaw = self.yaw + (motion == .orbit ? turn * (eased - 0.5) : 0)
        let direction = SIMD3<Float>(sin(yaw) * cos(pitch), -cos(yaw) * cos(pitch), sin(pitch))
        var eye = focus + direction * distance
        eye.z = max(eye.z, face.height(face.terrain.heights, eye.x, eye.y) + 2)
        return (eye, focus, fovDegrees * .pi / 180)
    }
}

/// What to record: where, which stretch of the event, how slowly, and how big.
public struct QuarryClipRequest: Sendable {
    public var url: URL
    public var camera: QuarryClipCamera
    /// The event's own seconds: where the clip starts, and how much of the event it shows.
    public var start: Float = 0
    public var seconds: Float = 10
    /// 1 for real time, 0.5 or 0.25 for slow motion: the moments between the event's frames are
    /// drawn from poses interpolated between them, and the dust and chips step at the finer rate.
    public var speed: Float = 1
    public var width = 1920
    public var height = 1080
    public var supersample = 1
    public var videoRate = 30
    public var bitrate = 14_000_000
    /// The window's dust cells (m), so the clip looks as the window does.
    public var dustGrid: Float = QuarrySession.dustGrid

    public init(url: URL, camera: QuarryClipCamera) {
        self.url = url
        self.camera = camera
    }

    /// Frames in the movie.
    public var videoFrames: Int { max(1, Int((seconds / speed * Float(videoRate)).rounded())) }
    /// The movie's length (s).
    public var videoSeconds: Float { Float(videoFrames) / Float(videoRate) }
    /// Event seconds between one movie frame and the next.
    var step: Float { speed / Float(videoRate) }
}

/// Records a clip of a quarry event from its stored poses, on its own thread, with its own renderer
/// and dust (so the window keeps playing): the dust and chips run from the event's start to the
/// clip's, then each movie frame is drawn and written. Frames not yet simulated are waited for.
/// Illustrative, like the scene.
public final class QuarryClipRecorder: @unchecked Sendable {
    public struct Report: Sendable {
        public var url: URL
        public var frames: Int
        public var videoSeconds: Float
        /// Wall seconds in all, and median milliseconds a movie frame: all of it, the draw's GPU
        /// time and the dust step's.
        public var wallSeconds: Double
        public var frameMilliseconds: Double
        public var drawMilliseconds: Double
        public var dustMilliseconds: Double
        /// Seconds running the dust up to the clip's start.
        public var leadInSeconds: Double
        /// Set when the event stopped being simulated before the clip's end, which it then ends at.
        public var cutShort: Bool
        /// Metal allocated while recording, at its most (bytes).
        public var metalPeak: Int
    }

    public enum Failure: Error, CustomStringConvertible {
        case cancelled
        case nothingToRecord
        public var description: String {
            switch self {
            case .cancelled: "Cancelled."
            case .nothingToRecord: "There is nothing of the event to record yet."
            }
        }
    }

    let device: MTLDevice
    let face: QuarryFace
    let cache: QuarryPoseCache
    let firings: [QuarryFiring]
    public let request: QuarryClipRequest
    /// Whether frames not yet stored are still to come (the event is being simulated).
    let stillComing: @Sendable () -> Bool
    private let lock = NSLock()
    private var cancelled = false

    public init(
        device: MTLDevice, face: QuarryFace, cache: QuarryPoseCache, firings: [QuarryFiring],
        request: QuarryClipRequest, stillComing: @escaping @Sendable () -> Bool
    ) {
        self.device = device
        self.face = face
        self.cache = cache
        self.firings = firings
        self.request = request
        self.stillComing = stillComing
    }

    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }

    /// Records on a thread of its own. `progress` is told the share done and what is happening,
    /// and `done` the outcome, both on the main thread.
    public func start(
        progress: @escaping @Sendable (Float, String) -> Void,
        done: @escaping @Sendable (Result<Report, Error>) -> Void
    ) {
        let thread = Thread { [self] in
            let result: Result<Report, Error>
            do {
                result = .success(try autoreleasepool { try record(progress: progress) })
            } catch {
                try? FileManager.default.removeItem(at: request.url)
                result = .failure(error)
            }
            DispatchQueue.main.async { done(result) }
        }
        thread.name = "Quarry clip"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Records on the calling thread (not the main one).
    public func record(progress: @escaping @Sendable (Float, String) -> Void) throws -> Report {
        let began = Date()
        let r = request
        func tell(_ share: Float, _ text: String) {
            DispatchQueue.main.async { progress(share, text) }
        }
        tell(0, "Setting up the clip…")
        guard cache.available > 0 else { throw Failure.nothingToRecord }
        let eventRate = QuarrySession.frameRate
        let stepsPerSecond = 1 / r.step
        let path = QuarryCameraPath(
            eyes: (.zero, SIMD3(0, 1, 0)), targets: (SIMD3(0, 1, 0), .zero), fovY: (36, 36), duration: 1)
        let renderer = try QuarryRenderer(
            device: device, face: face, width: r.width, height: r.height, supersample: r.supersample,
            path: path,
            frameRate: stepsPerSecond, quality: .live)
        let sun = SIMD3(renderer.camera.sun.x, renderer.camera.sun.y, renderer.camera.sun.z)
        let dust = try QuarryDustField(
            device: device, face: face, firings: firings, sun: sun, gridSize: r.dustGrid)
        renderer.dust = dust
        let bodies = face.blocks.count
        let restSizes = face.blocks.map(\.size)
        let pose = device.makeBuffer(length: 32 * bodies, options: .storageModeShared)!
        let previous = device.makeBuffer(length: 32 * bodies, options: .storageModeShared)!
        let posePointer = pose.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * bodies)
        cache.decode(frame: 0, into: posePointer)
        previous.contents().copyMemory(from: pose.contents(), byteCount: 32 * bodies)
        let writer = try QuarryClipWriter(
            url: r.url, width: r.width, height: r.height, fps: Int32(r.videoRate), bitrate: r.bitrate)
        var metalPeak = device.currentAllocatedSize
        var frameTimes: [Double] = []
        var drawTimes: [Double] = []
        var dustTimes: [Double] = []
        let leadSteps = Int((r.start / r.step).rounded())
        let total = leadSteps + r.videoFrames
        var leadIn = 0.0
        var cutShort = false
        var written = 0
        // Step k is event time k·step: the dust and chips run through every one, from the start.
        for k in 0..<total {
            if isCancelled {
                writer.abandon()
                throw Failure.cancelled
            }
            let frameStart = Date()
            let time = Float(k) * r.step
            let position = Double(time * eventRate)
            // Wait for the solver if the event is still being simulated past here.
            while Double(cache.available - 1) < position.rounded(.up), !cache.isComplete {
                if isCancelled {
                    writer.abandon()
                    throw Failure.cancelled
                }
                guard stillComing() else { break }
                tell(Float(k) / Float(total), "Waiting for the event to be simulated…")
                Thread.sleep(forTimeInterval: 0.05)
            }
            if Double(cache.available - 1) < position, !cache.isComplete {
                cutShort = true
                break
            }
            try autoreleasepool {
                if k > 0 {
                    previous.contents().copyMemory(from: pose.contents(), byteCount: 32 * bodies)
                    cache.decode(at: position, into: posePointer)
                    let dustTime = dust.step(
                        pose: pose, previous: previous, bodies: bodies, time: time, restSize: restSizes,
                        frameRate: stepsPerSecond)
                    renderer.stepDecor(pose: pose, previous: previous, time: time)
                    if k >= leadSteps { dustTimes.append(dustTime * 1000) }
                }
                guard k >= leadSteps else { return }
                if k == leadSteps { leadIn = Date().timeIntervalSince(began) }
                let share = Float(k - leadSteps) / Float(max(1, r.videoFrames - 1))
                renderer.viewOverride = r.camera.view(at: share, time: time, face: face)
                drawTimes.append(renderer.render(pose: pose, previous: previous, time: time) * 1000)
                writer.append(renderer)
                written += 1
                if isCancelled { throw Failure.cancelled }
            }
            if k >= leadSteps { frameTimes.append(Date().timeIntervalSince(frameStart) * 1000) }
            metalPeak = max(metalPeak, device.currentAllocatedSize)
            if k % 8 == 0 {
                if k < leadSteps {
                    tell(
                        Float(k) / Float(total),
                        String(format: "Running the dust up to %.1f s…", r.start))
                } else {
                    tell(
                        Float(k) / Float(total),
                        "Frame \(k - leadSteps + 1) of \(r.videoFrames)")
                }
            }
        }
        guard written > 0 else {
            writer.abandon()
            throw Failure.nothingToRecord
        }
        tell(1, "Finishing the movie…")
        writer.finish()
        func median(_ values: [Double]) -> Double {
            values.isEmpty ? 0 : values.sorted()[values.count / 2]
        }
        return Report(
            url: r.url, frames: written, videoSeconds: Float(written) / Float(r.videoRate),
            wallSeconds: Date().timeIntervalSince(began), frameMilliseconds: median(frameTimes),
            drawMilliseconds: median(drawTimes), dustMilliseconds: median(dustTimes), leadInSeconds: leadIn,
            cutShort: cutShort, metalPeak: metalPeak)
    }
}
