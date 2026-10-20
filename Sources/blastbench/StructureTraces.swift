import BlastCore
import Foundation
import Metal
import simd

// Traces and reports of a structure's run that several commands print.
// Split from main.swift (emmettl/bombcad-work#51).

/// `--work`: the work trace (`StructureSolver.tracesWork`), and `--hourglass 0.5` scales the
/// hourglass control, for any bench that builds a solid body.
/// The structure of the last run, kept for a report after it.
nonisolated(unsafe) var lastStructure: StructureSolver?

func prepareTrace(_ solver: StructureSolver) {
    solver.tracesWork = flag("work")
    if let factor = option("hourglass").flatMap({ Float($0) }) { solver.hourglassCoefficient = factor }
    // `--step-divisor 4`: the structure's step a quarter of its elastic limit, which concrete
    // compacted under a contact charge needs (see `ContactSlabTest`).
    if let divisor = option("step-divisor").flatMap({ Float($0) }) {
        solver.stepOverride = solver.stableTimeStep / divisor
    }
    // `--print-step`: the structure's step and the strain-rate filter's window (50 steps unless
    // `--rate-window` fixes it), as the run starts.
    if flag("print-step") {
        let window = solver.model.strainRateWindow ?? 50 * solver.criticalTimeStep
        print(
            "Structure's step \(format(Double(solver.criticalTimeStep) * 1e6, 3)) µs, strain-rate window "
                + "\(format(Double(window) * 1e6, 1)) µs, elements \(format(Double(solver.model.elementSize) * 1000, 2)) mm"
        )
        fflush(stdout)
    }
    applyFragmentThresholds(solver)
}

/// `--fragment-opening 1` (mm) and `--fragment-strain 0.1`: with `--fragments`, the openings that
/// make concrete fragments (`StructureSolver.fragmentOpening`, `fragmentStrain`).
func applyFragmentThresholds(_ solver: StructureSolver) {
    if let opening = option("fragment-opening").flatMap({ Float($0) }) {
        solver.fragmentOpening = opening / 1000
    }
    if let strain = option("fragment-strain").flatMap({ Float($0) }) { solver.fragmentStrain = strain }
}

/// Where hourglass control's work goes (with `--work`): through the whole body, by layer up its
/// depth (z), and by the elements' state, each part's hourglass work (held below the cap, and at
/// it) against all the work done in it. `centre` picks out elements near a charge, if given.
func printHourglassBreakdown(_ s: StructureSolver, label: String, near: ((Int, Int, Int) -> Bool)? = nil) {
    let hourglass = StructureSolver.WorkChannel.hourglass.rawValue
    let capped = StructureSolver.WorkChannel.hourglassCapped.rawValue
    let all = s.workTotals()
    let allHourglass = all[hourglass] + all[capped]
    var parts: [(String, (Int, Int, Int) -> Bool)] = [("all", { _, _, _ in true })]
    // Layers through the depth, among the layers the body has elements in.
    let layers = (0..<s.ez).filter { k in (0..<s.ex).contains { i in s.flag(i, s.ey / 2, k) != .empty } }
    for k in layers { parts.append(("layer \(k - (layers.first ?? 0) + 1)", { _, _, kk in kk == k })) }
    parts += [
        ("uncracked", { i, j, k in s.crackStrain(i, j, k) < 2e-4 }),
        ("cracked < 0.2%", { i, j, k in s.crackStrain(i, j, k) >= 2e-4 && s.crackStrain(i, j, k) < 2e-3 }),
        ("cracked >= 0.2%", { i, j, k in s.crackStrain(i, j, k) >= 2e-3 }),
        ("crushed", { i, j, k in s.plasticStrain(i, j, k) > 0.003 }),
        ("with bars", { i, j, k in simd_reduce_max(s.steelRatio(i, j, k)) > 0 }),
        ("without bars", { i, j, k in simd_reduce_max(s.steelRatio(i, j, k)) <= 0 }),
    ]
    // Fifths of the body's length (x), the end ones holding any supports.
    let occupied = (0..<s.ex).filter { i in (0..<s.ez).contains { k in s.flag(i, s.ey / 2, k) != .empty } }
    if let first = occupied.first, let last = occupied.last {
        for f in 0..<5 {
            let from = first + (last - first + 1) * f / 5
            let to = first + (last - first + 1) * (f + 1) / 5
            parts.append(("length \(f + 1)/5", { i, _, _ in i >= from && i < to }))
        }
    }
    if let near {
        parts.append(("near the charge", near))
        parts.append(("away from it", { !near($0, $1, $2) }))
    }
    print(
        "  hourglass control's work, \(label) (J): held below its cap, at it, all work there, its share there, of all hourglass work; the bars' and bond's work there"
    )
    for (name, include) in parts {
        let t = s.workTotals(where: include)
        let mine = t[hourglass] + t[capped]
        let total = t.reduce(0, +)
        print(
            "    " + pad(name, 18) + pad(format(t[hourglass], 1), 10) + pad(format(t[capped], 1), 10)
                + pad(format(total, 1), 10) + pad("\(format(total != 0 ? 100 * mine / total : 0, 1))%", 9)
                + pad("\(format(allHourglass != 0 ? 100 * mine / allHourglass : 0, 1))%", 9)
                + pad(
                    format(
                        t[StructureSolver.WorkChannel.bars.rawValue]
                            + t[StructureSolver.WorkChannel.bond.rawValue], 1), 10))
    }
}

/// Peterson's beams through time, as his high-speed images show them: every 0.1 ms, the elements
/// through the middle of the width cracked open by 1% or more across their widest crack plane, and
/// the crack's line on the side face (its inclination from the beam's axis, and which way it rises);
/// when the first inclined crack (20-75 degrees, three elements or more) opens in the short shear
/// span; the longest inclined crack there (elements in touch, its line by principal axes) at 1, 2
/// and 5 ms; and when concrete within 30 mm of the load (in the top three rows) or of the near
/// support (in the bottom three) first crushes past its peak (0.35%), and first is removed.
/// The row of elements across the width the Peterson traces read: the middle, or with
/// `--trace-face` the side face, which the high-speed images show.
func traceRow(_ solver: StructureSolver) -> Int { flag("trace-face") ? 0 : solver.ey / 2 }

/// `--removal-trace`: why the elements through the middle of a beam's width are removed. Every
/// 0.02 ms it keeps each whole element's cracks (the opening across each plane, its normal) and
/// crushing; when one is removed or left as bars, it reports the state it had last.
final class RemovalTrace {
    var nextSample = 0.0
    var last: [Int: (openings: SIMD3<Float>, normals: [SIMD3<Float>], crushed: Float)] = [:]
    var removed: [(ms: Double, i: Int, k: Int, opening: Float, angle: Float, crushed: Float, bare: Bool)] = []

    lazy var sample: (StructureSolver) -> Void = { [unowned self] solver in
        guard solver.time >= nextSample - 1e-9 else { return }
        nextSample += 0.00002
        let h = solver.model.elementSize
        let j = traceRow(solver)
        for k in 0..<solver.ez {
            for i in 0..<solver.ex {
                let key = i + solver.ex * k
                let flag = solver.flag(i, j, k)
                if flag == .active {
                    let planes = solver.crackPlanes(i, j, k)
                    last[key] = (planes.history * h, planes.normals, solver.plasticStrain(i, j, k))
                } else if flag == .eroded || flag == .bare, let state = last[key] {
                    let p =
                        state.openings.x >= state.openings.y
                        ? (state.openings.x >= state.openings.z ? 0 : 2)
                        : (state.openings.y >= state.openings.z ? 1 : 2)
                    let n = state.normals.count == 3 ? state.normals[p] : SIMD3(0, 0, 1)
                    // The crack plane's normal from the vertical: 0 for a crack along the beam.
                    let angle = atan2(simd_length(SIMD2(n.x, n.y)), abs(n.z)) * 180 / .pi
                    removed.append(
                        (solver.time * 1000, i, k, state.openings[p], angle, state.crushed, flag == .bare))
                    last[key] = nil
                }
            }
        }
    }

    func report() {
        print("  removed through the middle of the width: \(removed.count)")
        var byRow: [Int: Int] = [:]
        for r in removed { byRow[r.k, default: 0] += 1 }
        print(
            "  by row from the bottom: "
                + byRow.keys.sorted().map { "\($0): \(byRow[$0]!)" }.joined(separator: ", "))
        for r in removed.prefix(25) {
            print(
                "    \(format(r.ms, 2)) ms  (\(r.i), \(r.k))  widest crack \(format(Double(r.opening) * 1000, 2)) mm, normal \(format(Double(r.angle), 0))° from vertical, crushed \(format(Double(r.crushed) * 100, 2))%\(r.bare ? ", left as bars" : "")"
            )
        }
    }
}

/// `--strut-trace`: the concrete a Peterson beam's strut bears on, under the load and at the near
/// support, every 0.25 ms to 6 ms: of the elements through the middle of the width within 30 mm
/// and three rows of each, the most compressed one's crushing strain, effective strain rate, the
/// compressive strength's rate factor (CEB-FIP 1990, as the kernel takes it), confinement gain,
/// and least principal stress over the cylinder strength.
final class StrutTrace {
    let strike: Float
    let strength: Float
    var nextSample = 0.0
    var lines: [String] = []

    init(strike: Float, strength: Float) {
        self.strike = strike
        self.strength = strength
    }

    func factor(_ rate: Float) -> Float {
        let alpha = 1 / (5 + 9 * strength / 10e6)
        if rate <= 30 { return pow(max(rate, 30e-6) / 30e-6, 1.026 * alpha) }
        return pow(10, 6.156 * alpha - 2) * pow(rate / 30e-6, 1 / 3)
    }

    lazy var sample: (StructureSolver) -> Void = { [unowned self] solver in
        guard solver.time >= nextSample - 1e-9, solver.time <= 0.0062 else { return }
        nextSample += 0.00025
        let h = solver.model.elementSize
        let j = traceRow(solver)
        let rows = Int((0.15 / h).rounded())
        let support = 0.05 - solver.origin.x
        func x(_ i: Int) -> Float { (Float(i) + 0.5) * h - support }
        var line = "    \(format(solver.time * 1000, 2)) ms"
        for (label, near) in [
            ("load", { (i: Int, k: Int) in abs(x(i) - self.strike) < 0.03 && k >= rows - 3 }),
            ("support", { (i: Int, k: Int) in abs(x(i)) < 0.03 && k < 3 }),
        ] {
            var best: (stress: Float, text: String)?
            for k in 0..<min(rows, solver.ez) {
                for i in 0..<solver.ex where near(i, k) && solver.flag(i, j, k) == .active {
                    let s = solver.stress(i, j, k)
                    let tensor = simd_float3x3(
                        SIMD3(s[0], s[3], s[5]), SIMD3(s[3], s[1], s[4]), SIMD3(s[5], s[4], s[2]))
                    // Least principal stress, by the trace and invariants' cubic.
                    let mean = (s[0] + s[1] + s[2]) / 3
                    let deviator = tensor - simd_float3x3(diagonal: SIMD3(repeating: mean))
                    let j2 = 0.5 * (0..<3).reduce(Float(0)) { $0 + simd_length_squared(deviator[$1]) }
                    let r = max(j2 / 3, 1e-12).squareRoot()
                    let cosine = max(-1, min(1, deviator.determinant / (2 * r * r * r)))
                    let least = mean + 2 * r * cos((acos(cosine) + 2 * .pi) / 3)
                    guard best == nil || least < best!.stress else { continue }
                    let rate = solver.strainRate(i, j, k)
                    let planes = solver.crackPlanes(i, j, k)
                    let gain = solver.confinementGain(i, j, k)
                    func f(_ v: Float) -> String { format(Double(v / strength), 2) }
                    best = (
                        least,
                        "\(label) (\(i),\(k)) crush \(format(Double(planes.crush.max()) * 100, 2))%, rate \(format(Double(rate), 0))/s, factor \(format(Double(factor(rate)), 2)), gains \(format(Double(gain.x), 2))/\(format(Double(gain.y), 2))/\(format(Double(gain.z), 2)), least \(format(Double(-least / strength), 2)) f_c, xx \(f(s[0])) yy \(f(s[1])) zz \(f(s[2])) xz \(f(s[5])), axes \(planes.normals.map { "(\(format(Double($0.x), 2)),\(format(Double($0.y), 2)),\(format(Double($0.z), 2)))" }.joined())"
                    )
                }
            }
            line += "  " + (best?.text ?? "\(label) gone")
        }
        lines.append(line)
    }

    func report() { for line in lines { print(line) } }
}

final class PetersonCrackTrace {
    let name: String
    let strike: Float
    var nextSample = 0.0
    var firstInclined: (ms: Double, inclination: Float)?
    var crushLoad: Double?
    var crushSupport: Double?
    var removedLoad: Double?
    var removedSupport: Double?
    var longest: [(ms: Double, inclination: Float, length: Float, rises: String)] = []

    init(name: String, strike: Float) {
        self.name = name
        self.strike = strike
    }

    lazy var sample: (StructureSolver) -> Void = { [unowned self] solver in
        guard solver.time >= nextSample - 1e-9, solver.time <= 0.0052 else { return }
        nextSample += 0.0001
        let h = solver.model.elementSize
        let j = traceRow(solver)
        let rows = Int((0.15 / h).rounded())
        let support = 0.05 - solver.origin.x  // the near support, from the lattice's origin
        func x(_ i: Int) -> Float { (Float(i) + 0.5) * h - support }  // from the near support
        // Open elements: (i, k, inclination, rises right).
        var open: [(i: Int, k: Int, inclination: Float, right: Bool)] = []
        for k in 0..<min(rows, solver.ez) {
            for i in 0..<solver.ex where solver.flag(i, j, k) != .empty {
                let planes = solver.crackPlanes(i, j, k)
                let p =
                    planes.history.x >= planes.history.y
                    ? (planes.history.x >= planes.history.z ? 0 : 2)
                    : (planes.history.y >= planes.history.z ? 1 : 2)
                if planes.history[p] >= 0.01, planes.normals.count == 3 {
                    let n = planes.normals[p]
                    let inclination = atan2(abs(n.x), abs(n.z)) * 180 / .pi
                    open.append((i, k, inclination, n.x * n.z < 0))
                }
                let near = (abs(x(i) - strike) < 0.03 && k >= rows - 3) || (abs(x(i)) < 0.03 && k < 3)
                if near, solver.flag(i, j, k) == .eroded || solver.plasticStrain(i, j, k) > 0.0035 {
                    if abs(x(i)) < 0.03 {
                        crushSupport = crushSupport ?? solver.time
                    } else {
                        crushLoad = crushLoad ?? solver.time
                    }
                }
                if near, solver.flag(i, j, k) == .eroded || solver.flag(i, j, k) == .bare {
                    if abs(x(i)) < 0.03 {
                        removedSupport = removedSupport ?? solver.time
                    } else {
                        removedLoad = removedLoad ?? solver.time
                    }
                }
            }
        }
        let inSpan = open.filter { x($0.i) > 0 && x($0.i) < strike }
        let inclined = inSpan.filter { $0.inclination >= 20 && $0.inclination <= 75 }
        if firstInclined == nil, inclined.count >= 3 {
            firstInclined = (
                solver.time * 1000, inclined.map(\.inclination).reduce(0, +) / Float(inclined.count)
            )
        }
        let ms = (solver.time * 1000).rounded()
        if [1, 2, 5].contains(ms), !longest.contains(where: { $0.ms == ms }),
            abs(solver.time * 1000 - ms) < 0.06
        {
            // Elements in touch (8-connected) among the inclined open ones in the short span.
            var left = Set(inclined.map { [$0.i, $0.k] })
            var best: [[Int]] = []
            while let seed = left.first {
                var group = [seed]
                left.remove(seed)
                var head = 0
                while head < group.count {
                    let c = group[head]
                    head += 1
                    for di in -1...1 {
                        for dk in -1...1 where left.contains([c[0] + di, c[1] + dk]) {
                            left.remove([c[0] + di, c[1] + dk])
                            group.append([c[0] + di, c[1] + dk])
                        }
                    }
                }
                if group.count > best.count { best = group }
            }
            if best.count >= 3 {
                let pts = best.map { SIMD2(Float($0[0]) * h, Float($0[1]) * h) }
                let mean = pts.reduce(.zero, +) / Float(pts.count)
                var sxx: Float = 0
                var szz: Float = 0
                var sxz: Float = 0
                for p in pts {
                    let d = p - mean
                    sxx += d.x * d.x
                    szz += d.y * d.y
                    sxz += d.x * d.y
                }
                let theta = 0.5 * atan2(2 * sxz, sxx - szz)
                let along = SIMD2(cos(theta), sin(theta))
                let spread = pts.map { simd_dot($0 - mean, along) }
                let inclination = abs(atan2(along.y, along.x) * 180 / .pi)
                longest.append(
                    (
                        ms, inclination > 90 ? 180 - inclination : inclination,
                        ((spread.max() ?? 0) - (spread.min() ?? 0) + h) * 1000,
                        along.x * along.y > 0 ? "right" : "left"
                    ))
            } else {
                longest.append((ms, 0, 0, "-"))
            }
        }
    }

    func report() {
        func t(_ v: Double?) -> String { v.map { format($0 * 1000, 2) + " ms" } ?? "none" }
        let first =
            firstInclined.map { "\(format($0.ms, 2)) ms at \(format(Double($0.inclination), 0)) deg" }
            ?? "none"
        let main = longest.map {
            "\(format($0.ms, 0)) ms: \($0.length > 0 ? "\(format(Double($0.inclination), 0)) deg, \(format(Double($0.length), 0)) mm, rising \($0.rises)" : "none")"
        }.joined(separator: "; ")
        print(
            "  \(name): first inclined crack \(first); longest inclined crack \(main); crushed near the load \(t(crushLoad)), near the support \(t(crushSupport)); removed near the load \(t(removedLoad)), near the support \(t(removedSupport))"
        )
    }
}

/// The work trace's channels in the order printed.
let workOrder: [StructureSolver.WorkChannel] = [
    .tensionNormal, .tensionHairline, .tensionCracked, .compressionNormal, .compressionCrushed,
    .uncrackedShear, .crackShear,
    .crackShearPressed, .interlock, .interlockPressed, .dowel, .kink, .bars, .bond, .hourglass,
    .hourglassCapped,
    .other, .viscosity,
]

func workHeader(_ first: String, _ width: Int) -> String {
    let short = [
        "tension", "hairline", "cracked", "compr.", "crushed", "uncr. sh.", "crack sh.", "pressed",
        "interlock", "pressed",
        "dowel", "kinking", "bars", "bond", "hourglass", "capped", "other", "viscous",
    ]
    return pad(first, width) + short.map { pad($0, 10) }.joined() + pad("total", 10)
}

/// A row of the work trace: each mechanism's work, in joules.
func workRow(_ label: String, _ width: Int, _ totals: [Double]) -> String {
    pad(label, width) + workOrder.map { pad(format(totals[$0.rawValue], 1), 10) }.joined()
        + pad(format(totals.reduce(0, +), 1), 10)
}

/// `--rubble-trace`: every 0.05 ms, the rubble's count and fastest particle, and where it is.
nonisolated(unsafe) var nextRubbleTrace = 0.0

func rubbleTrace(_ solver: StructureSolver, _ time: Double) {
    guard time >= nextRubbleTrace else { return }
    // `--rubble-trace-from 1.8` (ms): every 2 µs from then on.
    let fine = option("rubble-trace-from").flatMap { Double($0) }.map { time >= $0 / 1000 } ?? false
    nextRubbleTrace = time + (fine ? 0.000002 : 0.00005)
    let particles = solver.rubbleParticles()
    guard
        let fastest = particles.max(by: {
            !(simd_length($1.particle.velocity) <= simd_length($0.particle.velocity))
        })
    else { return }
    let p = fastest.particle
    let (i, j, k) = solver.elementCoordinates(fastest.element)
    let broken = particles.filter { !simd_length($0.particle.velocity).isFinite }.count
    var brokenNodes = 0
    var fastestNode: Float = 0
    solver.mutateNodes { nodes in
        for node in nodes where node.mass > 0 {
            let speed = simd_length(node.velocity)
            if !speed.isFinite { brokenNodes += 1 } else { fastestNode = max(fastestNode, speed) }
        }
    }
    print(
        "  \(format(time * 1000, 3)) ms: \(particles.count) particles, \(broken) not finite, nodes \(brokenNodes) not finite, fastest node \(format(Double(fastestNode), 1)); fastest \(format(Double(simd_length(p.velocity)), 1)) m/s from (\(i), \(j), \(k)) at \(p.position), mass \(p.mass), reach \(p.reach), volume \(p.volume)"
    )
    fflush(stdout)
}

/// With rubble (`--rubble`): how many particles, their mass, and how fast they move.
func printRubble(_ solver: StructureSolver) {
    let particles = solver.rubbleParticles().map(\.particle)
    guard !particles.isEmpty else { return }
    let speeds = particles.map { simd_length($0.velocity) }.sorted()
    let mass = particles.reduce(0) { $0 + $1.mass }
    print(
        "  rubble: \(particles.count) particles, \(format(Double(mass), 1)) kg, speed median \(format(Double(speeds[speeds.count / 2]), 1)) m/s, fastest \(format(Double(speeds.last ?? 0), 1)) m/s"
    )
}
