import BlastCore
import Foundation
import Metal
import simd

// Probes of a struck slab's run, for closein, contact and twoface.
// Split from main.swift (emmettl/bombcad-work#51).

/// Prints once, at `time`, where along the span elements have failed or been left as bare bars,
/// in 0.2 m bins, and the centre's deflection, with the bolt lines' nodes' slip lengthwise.
func failureProbe(at time: Double) -> (StructureSolver, Double) -> Void {
    var done = false
    return { structure, now in
        guard !done, now >= time else { return }
        done = true
        let h = structure.model.elementSize
        var bins: [Int: (eroded: Int, bare: Int)] = [:]
        for k in 0..<structure.ez {
            for j in 0..<structure.ey {
                for i in 0..<structure.ex {
                    let flag = structure.flag(i, j, k)
                    guard flag == .eroded || flag == .bare else { continue }
                    let x = structure.origin.x + (Float(i) + 0.5) * h
                    let bin = Int(x / 0.2)
                    var entry = bins[bin] ?? (0, 0)
                    if flag == .eroded { entry.eroded += 1 } else { entry.bare += 1 }
                    bins[bin] = entry
                }
            }
        }
        print("  failed / bare elements along the span at \(format(now * 1000, 0)) ms:")
        for bin in bins.keys.sorted() {
            print(
                "    x \(format(Double(bin) * 0.2, 1))-\(format(Double(bin + 1) * 0.2, 1)) m: \(bins[bin]!.eroded) / \(bins[bin]!.bare)"
            )
        }
        let c = CloseInSlabTest.centre
        let j = Int(((c.y - structure.origin.y) / h).rounded())
        for bolt in [Float(1.4), 5.4] {
            let i = Int(((bolt - structure.origin.x) / h).rounded())
            let k = structure.ez / 2
            print(
                "    bolt line \(format(Double(bolt), 1)) m: node displaced \(structure.displacement(i, j, k))"
            )
        }
    }
}

/// Prints, at a few times, the column of elements under the charge from the bottom face up: crack
/// strain, damage, the frozen tensile rate factor, the strain rate and the element's state; and
/// how fast the bottom face moves against the middle of the slab.
func spallProbe() -> (StructureSolver, Double) -> Void {
    var times = [0.0003, 0.0006, 0.001, 0.002, 0.005, 0.01, 0.02]
    return { structure, time in
        guard let next = times.first, time >= next else { return }
        times.removeFirst()
        let h = structure.model.elementSize
        let c = CloseInSlabTest.centre
        let i = Int(((c.x - structure.origin.x) / h).rounded())
        let j = Int(((c.y - structure.origin.y) / h).rounded())
        let top = (0...structure.ez).last { structure.storedNode(i, j, $0) != nil } ?? 0
        print("  t = \(format(time * 1000, 2)) ms: k  crack  damage  factor  rate/s  state")
        for k in 0..<top {
            let flag = structure.flag(i, j, k)
            print(
                "      " + pad("\(k)", 3) + pad(format(Double(structure.crackStrain(i, j, k)), 3), 7)
                    + pad(format(Double(structure.damage(i, j, k)), 2), 8)
                    + pad(format(Double(structure.crackingFactor(i, j, k)), 2), 8)
                    + pad(format(Double(structure.strainRate(i, j, k)), 0), 8) + "  \(flag)")
        }
        let bottom = structure.node(i, j, 0).velocity.z
        let middle = structure.node(i, j, top / 2).velocity.z
        print(
            "      bottom face \(format(Double(bottom), 1)) m/s, mid-depth \(format(Double(middle), 1)) m/s")
    }
}

/// Writes, at every sample until `until` seconds, the state of each element through the slab's
/// thickness at a few distances from under the charge along the span, as CSV: stresses, node
/// velocities, crack and crush histories with the crack planes' tilt, compaction, rate factors.
func closeInTrace(path: String, until: Double) -> (StructureSolver, Double) -> Void {
    FileManager.default.createFile(atPath: path, contents: nil)
    let handle = FileHandle(forWritingAtPath: path)!
    handle.write(
        ("t,dx,k,flag,sxx,syy,szz,vzLow,vzHigh,h0,h1,h2,n0z,n1z,n2z,c0,c1,c2,compaction,factor,rate,"
            + "display,barX,barY,uz,g0,g1,g2,syz,szx\n").data(using: .utf8)!)
    var next = until
    return { structure, time in
        // Every sample until `until`, then every quarter of a millisecond.
        if time > until {
            guard time >= next else { return }
            next += 0.00025
        }
        let h = structure.model.elementSize
        let c = CloseInSlabTest.centre
        let i0 = Int(((c.x - structure.origin.x) / h).rounded())
        let j = Int(((c.y - structure.origin.y) / h).rounded())
        let top = (0...structure.ez).last { structure.storedNode(i0, j, $0) != nil } ?? 0
        var text = ""
        for dx: Float in [0, 0.1, 0.2, 0.3, 0.5, 1.0] {
            let i = i0 + Int((dx / h).rounded())
            for k in 0..<top {
                let s = structure.stress(i, j, k)
                let planes = structure.crackPlanes(i, j, k)
                let nz = planes.normals.map { abs($0.z) } + [0, 0, 0]
                let bars = structure.barPlasticStrain(i, j, k)
                let values: [Float] =
                    [
                        s[0] / 1e6, s[1] / 1e6, s[2] / 1e6, structure.node(i, j, k).velocity.z,
                        structure.node(i, j, k + 1).velocity.z, planes.history.x, planes.history.y,
                        planes.history.z, nz[0], nz[1], nz[2], planes.crush.x, planes.crush.y, planes.crush.z,
                        structure.compaction(i, j, k), structure.crackingFactor(i, j, k),
                        structure.strainRate(i, j, k), structure.damage(i, j, k), bars.x, bars.y,
                        structure.displacement(i, j, k).z,
                    ] + structure.confinement(i, j, k) + [s[4] / 1e6, s[5] / 1e6]
                text +=
                    "\(time),\(dx),\(k),\(structure.flag(i, j, k)),"
                    + values.map { String(format: "%.5g", $0) }.joined(separator: ",") + "\n"
            }
        }
        handle.write(text.data(using: .utf8)!)
    }
}

/// Prints, once at `time`, how far the slab's faces are cracked loose, by distance from under the
/// charge: on the bottom and top layers of elements, the share whose crack most nearly parallel
/// to the face has opened past 0.5, 1, 2 and 5 mm, and the share removed or left bare.
func faceProbe(at time: Double) -> (StructureSolver, Double) -> Void {
    var done = false
    return { structure, now in
        guard !done, now >= time else { return }
        done = true
        let h = structure.model.elementSize
        let c = CloseInSlabTest.centre
        let i0 = Int(((c.x - structure.origin.x) / h).rounded())
        let j0 = Int(((c.y - structure.origin.y) / h).rounded())
        let top = (0...structure.ez).last { structure.storedNode(i0, j0, $0) != nil } ?? 0
        for (name, k) in [("bottom", 0), ("top", top - 1)] {
            print("  \(name) layer at \(format(now * 1000, 1)) ms: r (m)  n  >0.5  >1  >2  >5 mm  gone")
            var bins: [Int: [Int]] = [:]
            for j in 0..<structure.ey {
                for i in 0..<structure.ex where structure.flag(i, j, k) != .empty {
                    let x = (Float(i) + 0.5) * h + structure.origin.x - c.x
                    let y = (Float(j) + 0.5) * h + structure.origin.y - c.y
                    let bin = Int((x * x + y * y).squareRoot() / 0.1)
                    var counts = bins[bin] ?? [0, 0, 0, 0, 0, 0]
                    counts[0] += 1
                    let flag = structure.flag(i, j, k)
                    if flag == .eroded || flag == .bare {
                        counts[5] += 1
                    } else {
                        let planes = structure.crackPlanes(i, j, k)
                        var opening: Float = 0
                        for p in 0..<3 where abs(planes.normals[p].z) > 0.7 {
                            opening = max(opening, planes.history[p] * h)
                        }
                        for (n, limit) in [Float(0.5e-3), 1e-3, 2e-3, 5e-3].enumerated() where opening > limit
                        {
                            counts[n + 1] += 1
                        }
                    }
                    bins[bin] = counts
                }
            }
            for bin in bins.keys.sorted() where bin < 12 {
                let n = bins[bin]!
                let share = n.dropFirst().map { pad(format(Double($0) / Double(n[0]) * 100, 0), 5) }
                print("    " + pad(format(Double(bin) * 0.1, 1), 5) + pad("\(n[0])", 5) + share.joined())
            }
        }
        // Rubble: elements cracked open across all three planes, by distance from under the charge
        // and layer.
        print("  cracked open across all three planes (> 0.25 mm / > 0.5 mm), by r (m) and layer k:")
        var rubble: [Int: [Int]] = [:]
        for k in 0..<top {
            for j in 0..<structure.ey {
                for i in 0..<structure.ex where structure.flag(i, j, k) == .active {
                    let planes = structure.crackPlanes(i, j, k)
                    let least = planes.history.min() * h
                    guard least > 0.25e-3 else { continue }
                    let x = (Float(i) + 0.5) * h + structure.origin.x - c.x
                    let y = (Float(j) + 0.5) * h + structure.origin.y - c.y
                    let bin = min(Int((x * x + y * y).squareRoot() / 0.1), 20)
                    var counts = rubble[bin] ?? Array(repeating: 0, count: 2 * top)
                    counts[k] += 1
                    if least > 0.5e-3 { counts[top + k] += 1 }
                    rubble[bin] = counts
                }
            }
        }
        for bin in rubble.keys.sorted() {
            let n = rubble[bin]!
            print(
                "    " + pad(format(Double(bin) * 0.1, 1), 5) + n.prefix(top).map { pad("\($0)", 5) }.joined()
                    + "  /" + n.suffix(top).map { pad("\($0)", 5) }.joined())
        }
        print("  removed / left bare, by r (m) and layer k:")
        var gone: [Int: [Int]] = [:]
        for k in 0..<top {
            for j in 0..<structure.ey {
                for i in 0..<structure.ex {
                    let flag = structure.flag(i, j, k)
                    guard flag == .eroded || flag == .bare else { continue }
                    let x = (Float(i) + 0.5) * h + structure.origin.x - c.x
                    let y = (Float(j) + 0.5) * h + structure.origin.y - c.y
                    let bin = min(Int((x * x + y * y).squareRoot() / 0.1), 20)
                    var counts = gone[bin] ?? Array(repeating: 0, count: 2 * top)
                    counts[flag == .eroded ? k : top + k] += 1
                    gone[bin] = counts
                }
            }
        }
        for bin in gone.keys.sorted() {
            let n = gone[bin]!
            print(
                "    " + pad(format(Double(bin) * 0.1, 1), 5) + n.prefix(top).map { pad("\($0)", 5) }.joined()
                    + "  /" + n.suffix(top).map { pad("\($0)", 5) }.joined())
        }
    }
}

/// Prints, at a few times, the slab's kinetic energy, its downward momentum and how fast that is
/// changing, and the energy of a rigid-plastic mechanism with the same angular momentum: the two
/// halves turning about their bolt lines.
func energyProbe() -> (StructureSolver, Double) -> Void {
    var times = [0.0005, 0.001, 0.0015, 0.002, 0.003, 0.004, 0.005, 0.0075, 0.01, 0.02, 0.03, 0.05, 0.08]
    var last: (time: Double, momentum: Double)?
    return { structure, time in
        guard let next = times.first, time >= next else { return }
        times.removeFirst()
        let h = structure.model.elementSize
        let mid = CloseInSlabTest.centre.x
        var kinetic = 0.0
        var momentum = 0.0
        var angular = [0.0, 0.0]
        var inertia = [0.0, 0.0]
        for k in 0...structure.ez {
            for j in 0...structure.ey {
                for i in 0...structure.ex where structure.storedNode(i, j, k) != nil {
                    let n = structure.node(i, j, k)
                    let v = SIMD3<Double>(n.velocity)
                    kinetic += 0.5 * Double(n.mass) * simd_length_squared(v)
                    momentum += Double(n.mass) * v.z
                    let x = Double(structure.origin.x + Float(i) * h)
                    let side = x < Double(mid) ? 0 : 1
                    let bolts = CloseInSlabTest.boltLines
                    let arm = Double(side == 0 ? Float(x) - bolts[0] : bolts[1] - Float(x))
                    if arm > 0 {
                        angular[side] += Double(n.mass) * v.z * arm
                        inertia[side] += Double(n.mass) * arm * arm
                    }
                }
            }
        }
        let mechanism = zip(angular, inertia).reduce(0.0) { $0 + 0.5 * $1.0 * $1.0 / $1.1 }
        let rate = last.map { (momentum - $0.momentum) / (time - $0.time) } ?? 0
        last = (time, momentum)
        print(
            "  \(format(time * 1000, 1)) ms: kinetic \(format(kinetic / 1000, 1)) kJ, momentum \(format(-momentum, 0)) N s "
                + "(changing at \(format(-rate / 1000, 0)) kN), halves turning about the bolts \(format(mechanism / 1000, 1)) kJ"
        )
    }
}

/// Prints, every 20 µs, the fastest node of the structure: its speed, lattice position, how
/// many of its elements are whole, and the largest compaction and pressure of those around it.
func fastestNodes() -> (StructureSolver, Double) -> Void {
    var next = 0.0
    return { structure, time in
        guard time >= next else { return }
        next += 0.00002
        var best: (speed: Float, i: Int, j: Int, k: Int) = (0, 0, 0, 0)
        for k in 0...structure.ez {
            for j in 0...structure.ey {
                for i in 0...structure.ex where structure.storedNode(i, j, k) != nil {
                    let speed = simd_length(structure.node(i, j, k).velocity)
                    if speed > best.speed { best = (speed, i, j, k) }
                }
            }
        }
        var whole = 0
        var compaction: Float = 0
        var pressure: Float = 0
        for corner in 0..<8 {
            let (a, b, c) = (
                best.i - (corner & 1), best.j - ((corner >> 1) & 1), best.k - ((corner >> 2) & 1)
            )
            guard a >= 0, b >= 0, c >= 0, a < structure.ex, b < structure.ey, c < structure.ez else {
                continue
            }
            if structure.flag(a, b, c) == .active { whole += 1 }
            compaction = max(compaction, structure.compaction(a, b, c))
            let s = structure.stress(a, b, c)
            pressure = max(pressure, -(s[0] + s[1] + s[2]) / 3)
        }
        print(
            "    \(format(time * 1e6, 0)) µs: fastest node \(format(Double(best.speed), 0)) m/s at (\(best.i), \(best.j), \(best.k)), "
                + "\(whole) whole elements, compaction \(format(Double(compaction), 3)), pressure \(format(Double(pressure) / 1e6, 0)) MPa"
        )
        fflush(stdout)
    }
}

/// Prints, every 0.1 ms, the column of elements under the charge from the protective face up:
/// each element's state (a active, b bare, x removed) and its lower node's downward velocity.
func axisColumn() -> (StructureSolver, Double) -> Void {
    var next = 0.0
    return { structure, time in
        guard time >= next else { return }
        next += 0.0001
        let i = structure.ex / 2
        let j = structure.ey / 2
        var states = ""
        var speeds: [String] = []
        for k in 0..<structure.ez {
            let flag = structure.flag(i, j, k)
            states += flag == .active ? "a" : flag == .bare ? "b" : flag == .eroded ? "x" : "."
            speeds.append(format(Double(-structure.node(i, j, k).velocity.z), 0))
        }
        speeds.append(format(Double(-structure.node(i, j, structure.ez).velocity.z), 0))
        print("    \(format(time * 1000, 2)) ms: \(states)  node v down: \(speeds.joined(separator: " "))")
        fflush(stdout)
    }
}

/// Prints the elements of the column under `point` (a lattice index i, j through the
/// thickness) and of columns `offsets` elements out along x: each element's state, its crack
/// planes' openings (mm, with the plane's tilt from the slab's: | across, - parallel to the
/// face), its largest compressive strain, compaction, confinement gain, the bars' plastic strain
/// and damage; and why it is kept, against the removal rules.
func columnReport(_ structure: StructureSolver, i i0: Int, j: Int, offsets: [Int] = [0, 2, 4, 8]) {
    let h = structure.model.elementSize
    let erosion = structure.model.material.erosionOpening
    print(
        "  column under the charge, from the protective face up (opening mm: |vertical plane, -face-parallel):"
    )
    for offset in offsets {
        let i = i0 + offset
        print("    \(format(Double(Float(offset) * h) * 100, 1)) cm out:")
        for k in 0..<structure.ez {
            let flag = structure.flag(i, j, k)
            let planes = structure.crackPlanes(i, j, k)
            let openings = planes.history.indices.map { p -> String in
                let tilt = abs(planes.normals.isEmpty ? 0 : planes.normals[p].z) > 0.7 ? "-" : "|"
                return tilt + format(Double(planes.history[p] * h) * 1000, 2)
            }
            let bars = structure.barPlasticStrain(i, j, k)
            let barText = [bars.x, bars.y].map { abs($0) > 1e8 ? "cut" : format(Double($0) * 100, 1) }
            let widest = planes.history.max()
            let note: String
            if flag != .active {
                note = ""
            } else if widest * h >= 3 * erosion {
                note = "crack past 3x removal width"
            } else if widest * h >= erosion {
                note = "crack past removal width, bridged"
            } else {
                note = "crack \(format(Double(widest * h / erosion) * 100, 0))% of removal width"
            }
            print(
                "      k\(k) " + pad("\(flag)", 7) + openings.joined(separator: " ")
                    + "  crush \(format(Double(structure.plasticStrain(i, j, k)) * 100, 2))%"
                    + " compaction \(format(Double(structure.compaction(i, j, k)) * 100, 2))%"
                    + " gain \(structure.confinement(i, j, k).map { format(Double($0), 2) }.joined(separator: "/"))"
                    + " bars \(barText.joined(separator: "/"))%  damage \(format(Double(structure.damage(i, j, k)), 2))  \(note)"
            )
        }
    }
}

/// For candidate removal rules, applied after the fact to the state at the end: the hole each
/// would leave about `(i0, j0)` (the equivalent diameter of the columns whose concrete is gone
/// through the thickness, already or by the rule) and how many more elements it would remove,
/// within 0.3 m of the axis and beyond. Openings are each crack plane's strain times the
/// element size; "softened" is past the end of tension softening's tail (1% of the strength).
func removalCensus(_ structure: StructureSolver, i i0: Int, j j0: Int) {
    let h = structure.model.elementSize
    struct Rule {
        var name: String
        var removes: (_ openings: [Float], _ crush: Float, _ compaction: Float) -> Bool
    }
    func planesOpen(_ w: [Float], _ limit: Float) -> Int { w.filter { $0 >= limit }.count }
    let rules = [
        Rule(name: "now") { _, _, _ in false },
        Rule(name: "2 planes >= 1 mm") { w, _, _ in planesOpen(w, 1e-3) >= 2 },
        Rule(name: "3 planes >= 0.5 mm") { w, _, _ in planesOpen(w, 0.5e-3) >= 3 },
        Rule(name: "any plane >= 5% strain") { w, _, _ in (w.max() ?? 0) >= 0.05 * h },
        Rule(name: "any plane >= 5% & 2 open >= 0.5 mm") { w, _, _ in
            (w.max() ?? 0) >= 0.05 * h && planesOpen(w, 0.5e-3) >= 2
        },
        Rule(name: "compacted & 2 planes >= 0.5 mm") { w, _, m in m > 0 && planesOpen(w, 0.5e-3) >= 2 },
        Rule(name: "compacted & 2 planes >= 1 mm") { w, _, m in m > 0 && planesOpen(w, 1e-3) >= 2 },
        Rule(name: "compacted or crushed 1%, 2 >= 1 mm") { w, c, m in
            (m > 0 || c > 0.01) && planesOpen(w, 1e-3) >= 2
        },
        Rule(name: "compacted or crushed 1%, 1 >= 1 mm") { w, c, m in
            (m > 0 || c > 0.01) && planesOpen(w, 1e-3) >= 1
        },
        Rule(name: "crushed >= 5%") { _, c, _ in c >= 0.05 },
    ]
    print("  removal rules tried after the fact: hole (cm), elements more within 0.3 m / beyond")
    for rule in rules {
        var through = 0
        var near = 0
        var far = 0
        for j in 0..<structure.ey {
            for i in 0..<structure.ex where structure.flag(i, j, 0) != .empty {
                let r = Float(simd_length(SIMD2<Float>(Float(i - i0), Float(j - j0)))) * h
                var all = true
                for k in 0..<structure.ez {
                    let flag = structure.flag(i, j, k)
                    if flag == .eroded || flag == .bare { continue }
                    let planes = structure.crackPlanes(i, j, k)
                    let w = (0..<3).map { planes.history[$0] * h }
                    if rule.removes(w, structure.plasticStrain(i, j, k), structure.compaction(i, j, k)) {
                        if r <= 0.3 { near += 1 } else { far += 1 }
                    } else {
                        all = false
                    }
                }
                if all { through += 1 }
            }
        }
        let diameter = (4 * Float(through) * h * h / .pi).squareRoot()
        print("    " + pad(rule.name, 38) + pad(format(Double(diameter) * 100, 1), 8) + "\(near) / \(far)")
    }
}
