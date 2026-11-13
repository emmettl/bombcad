import AVFoundation
import BlastModel
import BlastRender
import Foundation
import Metal
import simd

func parseVector(_ text: String) -> SIMD3<Float> {
    let v = text.split(separator: ",").compactMap { Float($0) }
    return SIMD3(v[0], v[1], v[2])
}

/// `hillsideblast clip`: a clip made by the window's own Record Clip (`QuarryClipRecorder`, its
/// camera, renderer and dust) from stored poses, offscreen, with frames taken from the movie file
/// itself. The camera is the window's default view unless `--yaw`, `--pitch`, `--distance` or
/// `--focus` say otherwise; `--motion` is Record Clip's camera (still, orbit or pullBack).
/// Illustrative, like the rest of `hillsideblast`.
enum ClipCommand {
    static func run(
        arguments: [String], face: QuarryFace, firings: [QuarryFiring], device: MTLDevice, posesURL: URL,
        dir: URL
    ) throws {
        let handle = try FileHandle(forReadingFrom: posesURL)
        let header = try handle.read(upToCount: 16)!.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
        let bodies = Int(header[0])
        let frames = Int(header[1])
        precondition(bodies == face.blocks.count, "poses and hillside differ")
        let first = try handle.read(upToCount: 32 * bodies)!
        let rest = first.withUnsafeBytes { Array($0.bindMemory(to: SIMD4<Float>.self)) }
        let cache = QuarryPoseCache(
            rest: rest, still: face.blocks.map(\.skin), frames: frames, low: face.low, high: face.high)
        var pose = rest
        for f in 0..<frames {
            if f > 0 {
                let data = try handle.read(upToCount: 32 * bodies)!
                data.withUnsafeBytes { pose = Array($0.bindMemory(to: SIMD4<Float>.self)) }
            }
            pose.withUnsafeBufferPointer { cache.store(frame: f, pose: $0.baseAddress!) }
        }
        try handle.close()
        let view = QuarrySession.defaultOrbit(face)
        if let ridge = face.ridge {
            print(
                String(
                    format:
                        "cut: crest %.2f m at x %.2f, floor %.2f, deep from x %.2f to %.2f, half-width %.1f",
                    ridge.crest, ridge.crestX, ridge.floor, ridge.cutStart, ridge.cutEnd, ridge.halfWidth))
        }
        var camera = QuarryClipCamera(
            focus: option(arguments, "--focus").map(parseVector) ?? view.focus,
            yaw: option(arguments, "--yaw").flatMap(Float.init) ?? view.yaw,
            pitch: option(arguments, "--pitch").flatMap(Float.init) ?? view.pitch,
            distance: option(arguments, "--distance").flatMap(Float.init) ?? view.distance,
            fovDegrees: option(arguments, "--fov").flatMap(Float.init) ?? 32)
        if let motion = option(arguments, "--motion") {
            guard let m = QuarryClipCamera.Motion.allCases.first(where: { "\($0)" == motion }) else {
                print("--motion: one of \(QuarryClipCamera.Motion.allCases.map { "\($0)" })")
                exit(1)
            }
            camera.motion = m
        }
        camera.firstFiring = firings.map(\.time).min() ?? 0
        let url = dir.appendingPathComponent(option(arguments, "--name") ?? "clip.mp4")
        var request = QuarryClipRequest(url: url, camera: camera)
        request.start = option(arguments, "--start").flatMap(Float.init) ?? 0
        request.seconds = option(arguments, "--seconds").flatMap(Float.init) ?? 20
        request.speed = option(arguments, "--speed").flatMap(Float.init) ?? 1
        request.withoutDust = arguments.contains("--no-dust")
        print(
            String(
                format: "camera focus %.1f,%.1f,%.1f yaw %.3f pitch %.3f distance %.1f fov %.0f motion %@",
                camera.focus.x, camera.focus.y, camera.focus.z, camera.yaw, camera.pitch, camera.distance,
                camera.fovDegrees, "\(camera.motion)"))
        let recorder = QuarryClipRecorder(
            device: device, face: face, cache: cache, firings: firings, request: request,
            stillComing: { false })
        let report = try recorder.record { _, _ in }
        print(
            String(
                format: "clip %@: %d frames, %.1f s of movie, made in %.1f s, %.1f ms a frame median",
                url.path, report.frames, report.videoSeconds, report.wallSeconds, report.frameMilliseconds))
        print(
            String(
                format: "clip medians: draw %.2f ms (GPU), dust step %.2f ms (GPU)", report.drawMilliseconds,
                report.dustMilliseconds))
        // Frames from the file itself, at movie times.
        let times = (option(arguments, "--frames")?.split(separator: ",").compactMap { Double($0) } ?? [])
        guard !times.isEmpty else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let stem = url.deletingPathExtension().lastPathComponent
        for t in times {
            nonisolated(unsafe) var taken: CGImage?
            let done = DispatchSemaphore(value: 0)
            generator.generateCGImageAsynchronously(for: CMTime(seconds: t, preferredTimescale: 600)) {
                image, _, _ in
                taken = image
                done.signal()
            }
            done.wait()
            guard let image = taken else { continue }
            let out = dir.appendingPathComponent(String(format: "%@-%05.2f.png", stem, t))
            guard
                let destination = CGImageDestinationCreateWithURL(
                    out as CFURL, "public.png" as CFString, 1, nil)
            else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            print("frame \(out.path)")
        }
    }
}
