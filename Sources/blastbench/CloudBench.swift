import BlastCore
import Foundation
import Metal
import simd

// `blastbench bubble` and `blastbench mixinglayer`.
// Split from main.swift (emmettl/bombcad-work#51).

/// A sphere of hot air at the surrounding pressure, `--hot` times the surrounding temperature,
/// released at rest one diameter above the ground under gravity, in a box 12 radii wide and 20
/// high: where its warm gas is through time (the cloud's hand-over's centre, everything 1% warmer
/// than the air), against the cloud's integral model (FireballRise) started from the same gas.
/// The cloud's centre height, rise speed and mass at `time`, between its samples.
func cloudAt(_ cloud: CloudResult, _ time: Double) -> (height: Double, speed: Double, mass: Double) {
    let samples = cloud.samples
    guard let after = samples.firstIndex(where: { $0.time >= time }) else {
        let last = samples[samples.count - 1]
        return (last.height, last.riseSpeed, last.mass)
    }
    guard after > 0 else { return (samples[0].height, samples[0].riseSpeed, samples[0].mass) }
    let a = samples[after - 1]
    let b = samples[after]
    let f = (time - a.time) / max(b.time - a.time, 1e-12)
    return (
        a.height + f * (b.height - a.height), a.riseSpeed + f * (b.riseSpeed - a.riseSpeed),
        a.mass + f * (b.mass - a.mass)
    )
}

func runBubble() throws {
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.5
    let radius = option("radius").flatMap { Float($0) } ?? 4
    let hot = option("hot").flatMap { Float($0) } ?? 2
    let duration = option("time").flatMap { Double($0) } ?? 20
    let lapse = (option("lapse").flatMap { Float($0) } ?? 6.5) / 1000
    let side = 12 * radius
    let height = 20 * radius
    var configuration = SolverConfiguration()
    configuration.gravity = AirGravity(lapseRate: lapse)
    configuration.mixing = chosenMixing()
    configureRefinement(&configuration)
    let solver = try BlastSolver(
        device: device,
        grid: Grid(
            nx: Int(side / cellSize), ny: Int(side / cellSize), nz: Int(height / cellSize), cellSize: cellSize
        ),
        configuration: configuration)
    let ground = Primitive(density: 1.225, pressure: 101_325)
    solver.fill(uniform: ground)
    let centre = SIMD3<Float>(side / 2, side / 2, 2 * radius)
    let grid = solver.grid
    solver.mutateState { cells in
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for i in 0..<grid.nx {
                    let x = (SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5) * cellSize
                    guard simd_distance(x, centre) < radius else { continue }
                    let n = grid.index(i, j, k)
                    // Hotter at the same pressure: lighter in proportion, the same internal energy a volume.
                    cells[n].density /= hot
                }
            }
        }
    }
    solver.restart()
    let ambient = Float(ground.pressure / (ground.density * 287.05))
    let threshold = ambient * 1.01
    let start = solver.cloudHandOver(hotterThan: threshold)
    var spec = CloudSpec()
    spec.handOverTemperature = threshold
    spec.lapseRate = Double(lapse)
    spec.productWater = 0
    spec.spread = false
    spec.duration = duration
    let cloud = CloudResult(spec: spec, handOver: start)
    print(
        String(
            format:
                "A bubble %.1f m in radius at %.0f K in air at %.0f K, its centre %.1f m up, on %.2f m cells, gravity, lapse %.1f K/km",
            radius, Double(ambient * hot), Double(ambient), Double(centre.z), cellSize, Double(lapse * 1000)))
    print("   time   air model: centre, rise speed, mass   integral model: centre, rise speed, mass")
    var lines = [
        "time_s,model_centre_m,model_speed_m_s,model_mass_kg,cloud_centre_m,cloud_speed_m_s,cloud_mass_kg"
    ]
    var times: [Double] = []
    var t = 0.0
    while t < duration - 1e-9 {
        t += t < 2 ? 0.25 : 1
        times.append(min(t, duration))
    }
    let started = ContinuousClock.now
    for target in times {
        while solver.time < target - 1e-9 {
            let result = solver.advance(steps: 256, timeLimit: target)
            if result.steps == 0 || !result.isStable { break }
        }
        let now = solver.cloudHandOver(hotterThan: threshold)
        let sample = cloudAt(cloud, solver.time)
        print(
            String(
                format: "  %5.2f s   %6.1f m %5.2f m/s %8.1f kg        %6.1f m %5.2f m/s %8.1f kg", target,
                Double(now.centre.z), now.riseSpeed, now.mass, sample.height, sample.speed, sample.mass))
        lines.append(
            String(
                format: "%.3f,%.3f,%.4f,%.2f,%.3f,%.4f,%.2f", target, Double(now.centre.z), now.riseSpeed,
                now.mass,
                sample.height, sample.speed, sample.mass))
    }
    print(
        String(
            format: "  %d steps, %.0f s, on %d by %d by %d cells", solver.stepCount,
            (ContinuousClock.now - started) / .seconds(1), grid.nx, grid.ny, grid.nz))
    if let path = option("csv") {
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// A temporal mixing layer: two streams of air at ±`--speed`/2 m/s along x, across a tanh profile
/// of momentum thickness two cells in z, with small random velocities to set it off, in a box 128
/// by 64 by 128 cells, periodic in x and y (`SolverConfiguration.periodicSides`, two cells of halo
/// a side), whose z faces copy the air beyond them. Its momentum thickness from the planes'
/// mean velocity, θ = ∫ (1/4 - (u/ΔU)²) dz, through time; self-similar layers grow at
/// dθ/dt ≈ 0.014 ΔU (Rogers and Moser 1994). `--mixing` turns on the sub-grid mixing.
func runMixingLayer() throws {
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.5
    let speed = option("speed").flatMap { Float($0) } ?? 50
    let duration = option("time").flatMap { Double($0) } ?? 8
    let length = option("length").flatMap { Int($0) } ?? 128
    let (nx, ny, nz) = (length + 4, length / 2 + 4, 128)
    var configuration = SolverConfiguration()
    configuration.reflectiveFaces = []
    configuration.periodicSides = true
    configuration.mixing = chosenMixing()
    let solver = try BlastSolver(
        device: device, grid: Grid(nx: nx, ny: ny, nz: nz, cellSize: cellSize), configuration: configuration)
    let theta0 = 2 * cellSize
    var random = SplitMix64(seed: 1994)
    solver.fill { i, j, k in
        let z = (Float(k) + 0.5 - Float(nz) / 2) * cellSize
        let mean = 0.5 * speed * tanh(z / (2 * theta0))
        // Perturbations a twentieth of the speed difference, where the layer is.
        let envelope = exp(-z * z / (8 * theta0 * theta0)) * 0.05 * speed
        let noise = SIMD3<Float>(random.unit(), random.unit(), random.unit()) * 2 - 1
        return Primitive(density: 1.225, velocity: SIMD3(mean, 0, 0) + envelope * noise, pressure: 101_325)
    }
    func thickness() -> Double {
        solver.withState { cells in
            var total = 0.0
            for k in 0..<nz {
                var sum = 0.0
                for j in 2..<(ny - 2) {
                    for i in 2..<(nx - 2) {
                        let c = cells[i + nx * (j + ny * k)]
                        sum += Double(c.momentumX / c.density)
                    }
                }
                let mean = sum / Double((nx - 4) * (ny - 4)) / Double(speed)
                total += (0.25 - mean * mean) * Double(cellSize)
            }
            return total
        }
    }
    print(
        String(
            format: "A temporal mixing layer, ΔU %.0f m/s, θ0 %.2f m, on %.2f m cells%@", speed, theta0,
            cellSize,
            configuration.mixing == nil ? "" : ", sub-grid mixing"))
    var lines = ["time_s,theta_m"]
    var samples: [(Double, Double)] = [(0, thickness())]
    let started = ContinuousClock.now
    var t = 0.0
    while t < duration - 1e-9 {
        t = min(t + 0.25, duration)
        while solver.time < t - 1e-9 {
            let result = solver.advance(steps: 256, timeLimit: t)
            if result.steps == 0 || !result.isStable { break }
        }
        samples.append((solver.time, thickness()))
    }
    for (time, theta) in samples {
        lines.append(String(format: "%.3f,%.4f", time, theta))
    }
    // The growth over the second half, against ΔU.
    let half = samples.filter { $0.0 >= duration / 2 }
    let n = Double(half.count)
    let mt = half.reduce(0.0) { $0 + $1.0 } / n
    let meanTheta = half.reduce(0.0) { $0 + $1.1 } / n
    let slope =
        half.reduce(0.0) { $0 + ($1.0 - mt) * ($1.1 - meanTheta) }
        / max(half.reduce(0.0) { $0 + ($1.0 - mt) * ($1.0 - mt) }, 1e-12)
    for (time, theta) in samples where time.truncatingRemainder(dividingBy: 1) < 0.01 {
        print(String(format: "  %5.2f s: θ %.3f m", time, theta))
    }
    print(
        String(
            format:
                "  dθ/dt over the second half %.3f m/s, %.4f ΔU (self-similar layers: about 0.014); %d steps, %.0f s",
            slope, slope / Double(speed), solver.stepCount, (ContinuousClock.now - started) / .seconds(1)))
    if let path = option("csv") {
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// A small deterministic random generator, for repeatable perturbations.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
}
