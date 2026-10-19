import BlastCore
import Foundation
import RadialBlast
import simd

/// `blastbench shell-sphere`: the thermal volume's march against the exact answer for a sphere of
/// `--radius` m (10) whose outer `--shell` m (0.6) is hot air at `--hot` K (6,600) absorbing
/// `--hot-kappa`/m (10) round a core at `--core` K (3,500) absorbing `--core-kappa`/m (5,000), on
/// voxels of `--voxel` m (0.5 and 0.25), each sampled four times a side: the
/// intensity toward a receiver 1,700 m off, in W/sr, as the march and as exact rays give it.
func runShellSphere() throws {
    let radius = option("radius").flatMap { Float($0) } ?? 10
    let shell = option("shell").flatMap { Float($0) } ?? 0.6
    let hot = option("hot").flatMap { Float($0) } ?? 6600
    let hotKappa = option("hot-kappa").flatMap { Float($0) } ?? 10
    let core = option("core").flatMap { Float($0) } ?? 3500
    let coreKappa = option("core-kappa").flatMap { Float($0) } ?? 5000
    let sizes = (option("voxel") ?? "0.5,0.25").split(separator: ",").compactMap { Float($0) }
    let centre = SIMD3<Float>(50, 50, 50)
    let range: Float = 1700
    let sigma = 5.670374e-8
    // `--profile file.csv --mass kg`: instead, a one-dimensional profile `radial-profile --dump`
    // wrote, its gas absorbing 0.1/m, as hot air, and as soot within the charge's own mass.
    var profile: [(t: Float, kappa: Float)] = []
    var cell: Float = 0
    if let path = option("profile") {
        let mass = option("mass").flatMap { Double($0) } ?? 907_184
        let rows = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").dropFirst().map {
            $0.split(separator: ",").compactMap { Double($0) }
        }
        cell = Float(rows[1][0] - rows[0][0])
        var held = 0.0
        var inside = true
        for (i, row) in rows.enumerated() {
            held +=
                4 * Double.pi / 3 * (pow(Double(i + 1), 3) - pow(Double(i), 3)) * pow(Double(cell), 3)
                * row[2]
            let t = Float(row[1])
            let soot = inside ? 1817 * 0.185 / 1800 * Float(row[3]) * t : 0
            if held >= mass { inside = false }
            profile.append(
                t >= 1500
                    ? (t, 0.1 + soot + HotAir.planckAbsorption(temperature: t, density: Float(row[2])))
                    : (0, 0))
        }
    }
    let outer = profile.isEmpty ? radius : Float((profile.lastIndex { $0.t > 0 } ?? 0) + 1) * cell
    func layer(_ r: Float) -> (t: Float, kappa: Float)? {
        if !profile.isEmpty {
            let i = Int(r / cell)
            return i < profile.count && profile[i].t > 0 ? profile[i] : nil
        }
        return r > radius ? nil : (r > radius - shell ? (hot, hotKappa) : (core, coreKappa))
    }
    // Exact: rays through the shells, far side to near.
    var exact = 0.0
    let rays = 4000
    for n in 0..<rays {
        let b = (Double(n) + 0.5) / Double(rays) * Double(outer)
        var intensity = 0.0
        let length = (Double(outer) * Double(outer) - b * b).squareRoot()
        let steps = 20000
        let ds = 2 * length / Double(steps)
        for s in 0..<steps {
            let z = -length + (Double(s) + 0.5) * ds
            guard let gas = layer(Float((b * b + z * z).squareRoot())) else { continue }
            let passed = exp(-Double(gas.kappa) * ds)
            intensity = intensity * passed + sigma * pow(Double(gas.t), 4) / Double.pi * (1 - passed)
        }
        exact += 2 * Double.pi * b * Double(outer) / Double(rays) * intensity
    }
    print(
        String(
            format:
                "Sphere of %.1f m, its outer %.2f m at %.0f K absorbing %g/m round %.0f K absorbing %g/m: exact %.4g W/sr",
            radius, shell, hot, hotKappa, core, coreKappa, exact))
    var scenario = Scenario(
        name: "Shell", domainSize: SIMD3(range + 100, 100, 100), boxes: [],
        charge: Charge(mass: 0, position: centre))
    scenario.reflectiveFaces = []
    let receiver = ThermalReceiver(
        position: centre + SIMD3(range, 0, 0), normal: SIMD3(-1, 0, 0), surface: "instrument")
    for size in sizes {
        let first = SIMD3<Int32>(((centre - outer) / size).rounded(.down))
        let last = SIMD3<Int32>(((centre + outer) / size).rounded(.up))
        let counts = last &- first
        let total = Int(counts.x) * Int(counts.y) * Int(counts.z)
        var fills = [UInt8](repeating: 0, count: total)
        var temperatures = [UInt16](repeating: 0, count: total)
        var absorption = [Float16](repeating: 0, count: total)
        let s = 4
        for k in 0..<Int(counts.z) {
            for j in 0..<Int(counts.y) {
                for i in 0..<Int(counts.x) {
                    var lit = 0
                    var fourth = 0.0
                    var kappa = 0.0
                    for c in 0..<s {
                        for b in 0..<s {
                            for a in 0..<s {
                                let p =
                                    (SIMD3<Float>(first &+ SIMD3(Int32(i), Int32(j), Int32(k)))
                                        + (SIMD3(Float(a), Float(b), Float(c)) + 0.5) / Float(s)) * size
                                guard let gas = layer(simd_distance(p, centre)) else { continue }
                                lit += 1
                                fourth += pow(Double(gas.t), 4)
                                kappa += Double(gas.kappa)
                            }
                        }
                    }
                    guard lit > 0 else { continue }
                    let v = i + Int(counts.x) * (j + Int(counts.y) * k)
                    fills[v] = UInt8((255 * Double(lit) / Double(s * s * s)).rounded())
                    temperatures[v] = UInt16(pow(fourth / Double(lit), 0.25).rounded())
                    absorption[v] = Float16(kappa / Double(lit))
                }
            }
        }
        let cells = LuminousCells(
            voxelSize: size, first: first, counts: counts, fills: fills, temperatures: temperatures,
            products: nil,
            airAbsorption: absorption)
        var spec = ThermalSpec()
        spec.absorption = 0
        spec.sootYield = 0
        spec.hotAirAbsorption = true
        spec.samples = 4096
        let exposure = ThermalExposure(spec: spec, scene: FragmentScene(scenario))
        let frame = FireballFrame(
            time: 0.001, volume: 4 / 3 * .pi * pow(Double(outer), 3), centre: centre, temperature: hot,
            hottest: hot, cells: cells)
        let irradiance = exposure.irradiance(frame, at: [receiver])[0]
        let intensity = Double(irradiance) * Double(range) * Double(range)
        print(
            String(
                format: "  voxels of %.3f m: march %.4g W/sr, %.2f of exact", size, intensity,
                intensity / exact))
    }
}
