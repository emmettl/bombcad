import BlastCore
import Foundation
import Metal
import simd

/// MERGE's congested rigs through the congestion model (`CongestedRigStudy`), against their measured
/// peaks: `blastbench merge [--rigs A,C,E,C*] [--gas methane,propane] [--dx 0.25] [--factor 1]
/// [--out f.json]`. The cell is `--dx` for the medium rigs and twice it for the large.
func runMerge(device: MTLDevice) throws {
    let names = (option("rigs") ?? "A,C,E,C*").split(separator: ",").map(String.init)
    let rigs = MergeRig.allCases.filter { names.contains($0.name) }
    let gases: [FlammableGas] = (option("gas") ?? "methane,propane").split(separator: ",").map {
        $0 == "propane" ? .propane : .methane
    }
    let dx = Float(option("dx") ?? "0.25") ?? 0.25
    var rows: [[String: Any]] = []
    for rig in rigs {
        for gas in gases {
            // `--per-pitch r`: cells r pitches across, for every rig alike.
            let cell =
                option("per-pitch").flatMap(Float.init).map { $0 * rig.pitch }
                ?? (rig.width > 6 ? 2 * dx : dx)
            var study = CongestedRigStudy(rig: rig, gas: gas, cellSize: cell)
            if let factor = option("factor").flatMap(Float.init) { study.acceleration.factor = factor }
            let start = Date()
            let probes = (option("probe") ?? "").split(separator: ",").compactMap { Double($0) }
            var probed = Set<Int>()
            let result = try study.run(
                device: device,
                report: { time, burnt, peak in
                    if flag("verbose") {
                        print(String(format: "  %.3f s  burnt %.3f  peak %.4f bar", time, burnt, peak / 1e5))
                    }
                },
                monitor: { solver in
                    for (n, time) in probes.enumerated() where solver.time >= time && !probed.contains(n) {
                        probed.insert(n)
                        probeFlame(solver, study: study)
                    }
                })
            let seconds = Date().timeIntervalSince(start)
            print(
                String(
                    format:
                        "%@ %@ dx %.3f: peak %.4f barg at %.2f m (measured %.3f), ratio %.2f; flame %.0f m/s (Mach %.2f); burnt %.3f by %.3f s; %.0f s",
                    rig.name, "\(gas)", study.cellSize, result.peak / 1e5, result.peakAt,
                    result.measured / 1e5,
                    result.ratio, result.flameSpeed, result.flameMach, result.burntFraction, result.duration,
                    seconds))
            print(
                "  arrivals: "
                    + zip(result.gaugeDistances, result.arrivals).map { distance, arrival in
                        arrival.map { String(format: "%.2f m %.4f s", distance, $0) }
                            ?? String(format: "%.2f m -", distance)
                    }.joined(separator: ", "))
            print(
                "  gauges: "
                    + zip(result.gaugeDistances, result.gaugePeaks).map {
                        String(format: "%.2f m %.4f", $0, $1 / 1e5)
                    }.joined(separator: ", "))
            rows.append([
                "rig": rig.name, "gas": "\(gas)", "dx": study.cellSize, "peak": result.peak,
                "measured": result.measured, "ratio": result.ratio, "burnt": result.burntFraction,
                "flameSpeed": result.flameSpeed,
                "arrivals": result.arrivals.map { $0 ?? -1 },
                "gaugePeaks": result.gaugePeaks, "gaugeDistances": result.gaugeDistances, "seconds": seconds,
            ])
        }
    }
    if let out = option("out") {
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: out))
    }
}

/// The flame's terms along the rig's x axis on the ground, as the shader works them out (without the
/// unburnt gas's compression): b, |u|, the obstacle turbulence's k, ε, u′ and length, the sub-grid
/// u′, the wrinklings and the folding.
func probeFlame(_ solver: BlastSolver, study: CongestedRigStudy) {
    let grid = solver.grid
    guard let turbulence = solver.obstacleTurbulence(), let share = solver.unburntShare() else { return }
    let viscosity = solver.eddyViscosities()
    let field = CongestionField(arrays: study.scenario().congestion ?? [], grid: grid)
    let dx = grid.cellSize
    let laminar = study.gas.laminarBurningVelocity(
        fraction: study.concentration ?? study.gas.stoichiometricFraction)
    let thickness = FlameTurbulence.kinematicViscosity / laminar
    let j = grid.ny / 2
    let i0 = grid.nx / 2
    print(String(format: "  probe at %.3f s (S_L %.3f m/s):", solver.time, laminar))
    print("    x     b     |u|     k       eps      u'obs  schelkin u'sgs  W_obs  W_sgs  Xi_sub  total")
    for i in i0..<min(grid.nx, i0 + Int(0.75 * study.rig.width / dx)) {
        let index = grid.index(i, j, 0)
        let air = solver.primitive(i, j, 0)
        let u = air.velocity
        let speed = simd_length(u)
        let kEps = turbulence[index]
        let k = kEps.x
        let epsilon = max(kEps.y, 0.1643 * k * k.squareRoot() / dx)
        let up0 = (2.0 / 3 * k).squareRoot()
        let sgs =
            max(viscosity?[index] ?? 0, 0) * (2.0 / 3).squareRoot() / (FlameTurbulence.energyCoefficient * dx)
        let a = FlameTurbulence.bradleyCoefficient * (study.acceleration.turbulence?.scale ?? 0.7)
        let wSgs = a * (sgs / laminar).squareRoot() * pow(dx / thickness, 1.0 / 6)
        let along = (u / (speed + 1e-4)) * (u / (speed + 1e-4))
        let blocked = field.blockage[index]
        let parallel = SIMD3(field.parallel[index].x, field.parallel[index].y, field.parallel[index].z)
        let count = max(blocked.w - simd_dot(along, parallel), 1e-4)
        let made = SIMD3(field.generation[index].x, field.generation[index].y, field.generation[index].z)
        let schelkin =
            (simd_dot(along * speed * speed, made) * field.unitWidth[index]).squareRoot()
            * (max(1, pow(count, 0.25)) - 1)
        let up = up0 + schelkin
        let nu = FlameTurbulence.kinematicViscosity
        let ratio = up / laminar
        let guelder = 1 + 0.62 * ratio.squareRoot() * up / pow(nu * epsilon, 0.25)
        let integral = 0.336 * Float(1.5).squareRoot() * up * k / epsilon
        let karlovitz = 0.157 * ratio / max(up * integral / nu, 1e-12).squareRoot()
        let scope = 1.6 * pow(max(karlovitz * 3.739, 1e-12), -1.0 / 3) * ratio
        let wObs = pow(pow(guelder, -4) + pow(max(scope, 1e-6), -4), -0.25)
        let folding = (simd_dot(along, SIMD3(blocked.x, blocked.y, blocked.z)) / count.squareRoot())
            .squareRoot()
        let vScale = (sgs * sgs + up0 * up0).squareRoot()
        let xiSub =
            1 + max(2.2 * folding, min(0.34 * speed / max(vScale, 1e-4) * folding, 1.6)) * min(count, 1)
        let total = max(max(wObs, wSgs), 1) * xiSub / field.porosityDrag[index].x
        let length = schelkin
        print(
            String(
                format:
                    "    %.2f  %.2f  %6.1f  %7.3f  %8.1f  %5.2f  %6.2f  %5.2f  %5.2f  %5.2f  %5.2f  %6.2f",
                (Float(i - i0) + 0.5) * dx, share[index], speed, kEps.x, kEps.y, up0, length, sgs, wObs,
                wSgs, xiSub, total))
    }
}
