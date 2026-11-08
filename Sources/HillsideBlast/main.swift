import Foundation
import Metal
import simd

// An experiment, not a feature: a hillside of about 100,000 blocks blasted for the eye. Output is
// illustrative and makes no claim about real fragmentation, flyrock reach or safe distances.

func option(_ arguments: [String], _ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

/// Compiles one of the target's Metal files, copied beside the program as a resource.
func compile(_ file: String, device: MTLDevice) throws -> MTLLibrary {
    let options = MTLCompileOptions()
    options.languageVersion = .version3_1
    let url = Bundle.module.url(forResource: file, withExtension: "metal")!
    return try device.makeLibrary(source: try String(contentsOf: url, encoding: .utf8), options: options)
}

func library(device: MTLDevice) throws -> MTLLibrary { try compile("Hillside", device: device) }
func dustLibrary(device: MTLDevice) throws -> MTLLibrary { try compile("HillsideDust", device: device) }

func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return .nan }
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}

setlinebuf(stdout)
let arguments = Array(CommandLine.arguments.dropFirst())
let dataRoot = URL(fileURLWithPath: "/Volumes/StudioData/bombcad/hillside-blast")
guard let command = arguments.first else {
    print("hillsideblast: an illustrative spectacle (docs/hillside-blast.md), not a blast-design aid.")
    print(
        "hillsideblast rigid-scaling <counts...> | simulate --blocks N --seconds T --out name | render --poses name --out name [--clip] [--stills t,t,...]"
    )
    exit(0)
}

if command == "rigid-scaling" {
    RigidScaling.run(counts: arguments.dropFirst().compactMap(Int.init))
    exit(0)
}

let device = MTLCreateSystemDefaultDevice()!
var options = Hillside.Options()
options.blocks = option(arguments, "--blocks").flatMap(Int.init) ?? 100_000
options.spheres = option(arguments, "--spheres").flatMap(Int.init) ?? 5
let substepsPerSecond = option(arguments, "--hz").flatMap(Float.init) ?? 240
let seconds = option(arguments, "--seconds").flatMap(Float.init) ?? 20
let name = option(arguments, "--out") ?? "run"
let dir = dataRoot.appendingPathComponent(name, isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
var hillside = Hillside(options: options)
if command != "play" { hillside.generate() }
let firings = FiringPattern.row(hillside: hillside)
var launch = Launch()

func writeReport(_ text: String) {
    print(text)
    try? text.write(to: dir.appendingPathComponent("\(command).txt"), atomically: true, encoding: .utf8)
}

if command == "play" {
    try MainActor.assumeIsolated {
        try PlayApp.run(arguments: arguments, hillside: &hillside, device: device, dataRoot: dataRoot)
    }
    exit(0)
}

if command == "simulate" {
    let lib = try library(device: device)
    let sim = try BlockSimulation(
        device: device, library: lib, hillside: hillside, launch: launch, firings: firings,
        dt: 1 / substepsPerSecond)
    let frameRate: Float = 30
    let substeps = max(1, Int((substepsPerSecond / frameRate).rounded()))
    print("substeps per frame \(substeps) (\(substepsPerSecond) Hz), frame \(1 / frameRate) s")
    let frames = Int(seconds * frameRate)
    var stepTimes: [Double] = []
    var census: [(Double, Int, Int, Int, Float, Float, Float, Int)] = []
    let poseURL = dir.appendingPathComponent("poses.bin")
    FileManager.default.createFile(atPath: poseURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: poseURL)
    var header = [Int32(sim.bodyCount), Int32(frames + 1), Int32(frameRate), 0]
    header.withUnsafeMutableBytes { try? handle.write(contentsOf: Data($0)) }
    func writePose() {
        try? handle.write(contentsOf: Data(bytes: sim.pose.contents(), count: 32 * sim.bodyCount))
    }
    writePose()
    for frame in 0..<frames {
        let gpu = sim.advance(substeps: substeps)
        stepTimes.append(gpu * 1000)
        writePose()
        let c = sim.census()
        census.append(
            (
                Double(frame + 1) / Double(frameRate), c.awake, c.held, c.asleep, c.maxSpeed, c.meanSpeed,
                c.kineticEnergy, c.bad
            ))
        if frame % 15 == 14 {
            print(
                String(
                    format:
                        "t %.2f s  gpu %.1f ms (median so far %.1f)  awake %d held %d asleep %d  vmax %.1f vmean %.2f KE %.3g bad %d",
                    Double(frame + 1) / Double(frameRate), gpu * 1000, percentile(stepTimes, 0.5), c.awake,
                    c.held, c.asleep, c.maxSpeed, c.meanSpeed, c.kineticEnergy, c.bad))
            fflush(stdout)
        }
    }
    try? handle.close()
    var csv = "t_s,awake,held,asleep,max_speed,mean_speed,kinetic_energy,bad,gpu_ms\n"
    for (i, c) in census.enumerated() {
        csv += "\(c.0),\(c.1),\(c.2),\(c.3),\(c.4),\(c.5),\(c.6),\(c.7),\(stepTimes[i])\n"
    }
    try csv.write(to: dir.appendingPathComponent("frames.csv"), atomically: true, encoding: .utf8)
    let p = stepTimes
    let during = stepTimes.indices.filter { census[$0].1 > sim.bodyCount / 20 }.map { stepTimes[$0] }
    let peakAwake = census.map(\.1).max() ?? 0
    writeReport(
        String(
            format:
                "blocks %d spheres %d, %d substeps/frame at %.0f Hz: frame (1/30 s) gpu median %.1f ms p90 %.1f max %.1f; when >5%% awake: median %.1f p90 %.1f (%d frames); finished awake %d asleep %d held %d bad %d; peak awake %d; sim buffers %d MB",
            sim.bodyCount, sim.sphereCount, substeps, substepsPerSecond, percentile(p, 0.5),
            percentile(p, 0.9), p.max() ?? 0, percentile(during, 0.5), percentile(during, 0.9), during.count,
            census.last?.1 ?? 0, census.last?.3 ?? 0, census.last?.2 ?? 0, census.last?.7 ?? 0, peakAwake,
            (MemoryLayout<BlockSimulation.GPUBody>.stride * sim.bodyCount + 60 * sim.sphereCount
                + sim.heads.length + 32 * sim.bodyCount) >> 20))
    print("wrote \(poseURL.path)")
    exit(0)
}

if command == "render" {
    let posesName = option(arguments, "--poses") ?? name
    let posesURL = dataRoot.appendingPathComponent(posesName).appendingPathComponent("poses.bin")
    let handle = try FileHandle(forReadingFrom: posesURL)
    let header = try handle.read(upToCount: 16)!.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
    let bodies = Int(header[0])
    let frames = Int(header[1])
    let fps = header[2]
    precondition(bodies == hillside.blocks.count, "poses and hillside differ")
    let supersample = option(arguments, "--ss").flatMap(Int.init) ?? 2
    let lib = try library(device: device)
    if !arguments.contains("--no-dressing") { hillside.buildDressing() }
    let start = option(arguments, "--eye").map(parseVector) ?? SIMD3<Float>(-46, -74, 3.6)
    let end = option(arguments, "--eye-end").map(parseVector) ?? SIMD3<Float>(-33, -66, 3.4)
    let target = option(arguments, "--target").map(parseVector) ?? SIMD3<Float>(66, 16, 16)
    let targetEnd = option(arguments, "--target-end").map(parseVector) ?? SIMD3<Float>(72, 14, 16)
    let fov = option(arguments, "--fov").flatMap(Float.init) ?? 36
    let path = CameraPath(
        eyes: (start, end), targets: (target, targetEnd), fovY: (fov, fov * 0.93), duration: 20)
    let renderer = try Renderer(
        device: device, library: lib, hillside: hillside, width: 1920, height: 1080, supersample: supersample,
        path: path, frameRate: Float(fps))
    if !arguments.contains("--no-dust") {
        renderer.dust = try DustField(
            device: device, library: try dustLibrary(device: device), hillside: hillside, firings: firings,
            width: 1920 * supersample, height: 1080 * supersample,
            sun: SIMD3(renderer.camera.sun.x, renderer.camera.sun.y, renderer.camera.sun.z),
            gridSize: option(arguments, "--dust-h").flatMap(Float.init) ?? 1)
    }
    let restSizes = hillside.blocks.map(\.size)
    let poseBuffer = device.makeBuffer(length: 32 * bodies, options: .storageModeShared)!
    let previousPose = device.makeBuffer(length: 32 * bodies, options: .storageModeShared)!
    var dustTimes: [Double] = []
    func readFrame(_ i: Int) {
        // Runs the dust up to this frame, in order.
        previousPose.contents().copyMemory(from: poseBuffer.contents(), byteCount: 32 * bodies)
        try? handle.seek(toOffset: UInt64(16 + i * 32 * bodies))
        if let data = try? handle.read(upToCount: 32 * bodies) {
            data.withUnsafeBytes {
                poseBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count)
            }
        }
    }
    /// Reads frame i and advances the dust to it from where it was, in order. Dust and chips only
    /// run forward, so a clip must take the frames in order from the start.
    var dustFrame = -1
    func advance(to i: Int) {
        guard i > dustFrame else { return }
        while dustFrame < i {
            dustFrame += 1
            readFrame(dustFrame)
            if dustFrame > 0, let dust = renderer.dust {
                dustTimes.append(
                    dust.step(
                        pose: poseBuffer, previous: previousPose, bodies: bodies,
                        time: Float(dustFrame) / Float(fps),
                        restSize: restSizes, frameRate: Float(fps)) * 1000)
            }
            if dustFrame > 0 {
                renderer.stepDecor(
                    pose: poseBuffer, previous: previousPose, time: Float(dustFrame) / Float(fps))
            }
        }
    }
    let clip = arguments.contains("--clip")
    let stills = (option(arguments, "--stills")?.split(separator: ",").compactMap { Double($0) } ?? [])
        .sorted()
    var draws: [Double] = []
    // Stills come out of the clip's own run when there is one, so that everything stays in order.
    var stillFrames = Dictionary(
        uniqueKeysWithValues: stills.map { (min(frames - 1, Int($0 * Double(fps))), $0) })
    if !clip {
        for (i, t) in stillFrames.sorted(by: { $0.key < $1.key }) {
            advance(to: i)
            draws.append(
                renderer.render(pose: poseBuffer, previous: previousPose, time: Float(i) / Float(fps)) * 1000)
            renderer.savePNG(dir.appendingPathComponent(String(format: "still-%05.2f.png", t)))
        }
        stillFrames = [:]
    }
    if clip {
        let writer = try ClipWriter(
            url: dir.appendingPathComponent("clip.mp4"), width: 1920, height: 1080, fps: fps)
        let start = Date()
        for i in 0..<frames {
            advance(to: i)
            draws.append(
                renderer.render(pose: poseBuffer, previous: previousPose, time: Float(i) / Float(fps)) * 1000)
            if let t = stillFrames[i] {
                renderer.savePNG(dir.appendingPathComponent(String(format: "still-%05.2f.png", t)))
            }
            writer.append(renderer)
            if i % 60 == 0 {
                print("frame \(i)/\(frames) \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
                fflush(stdout)
            }
        }
        writer.finish()
    }
    writeReport(
        String(
            format:
                "render %dx%d supersample %d: draw gpu median %.1f ms p90 %.1f (%d frames), triangles %d, memory blocks %d MB; dust step median %.1f ms",
            renderer.width, renderer.height, supersample, percentile(draws, 0.5), percentile(draws, 0.9),
            draws.count, hillside.indices.count / 3,
            (hillside.vertices.count * 20 + hillside.indices.count * 4) >> 20, percentile(dustTimes, 0.5)))
    exit(0)
}
