import BlastCore
import Foundation
import Metal

/// `blastbench perimeter`: Alsubaei's perimeter walls under field blasts (Western University
/// thesis, 2015; `Fixtures/Alsubaei2015`). `--study air` (the default) runs the air alone with the
/// wall rigid and compares the columns' peaks behind it with the measured ones, with and without
/// the wall.
///
///   --layout half|street|canopied|all   the arrangement (all by default)
///   --dx 0.05 [--refine 2]              air cells, and refinement at the shock
///   --columns 0.2                       rigid square columns this wide, gauges at their faces;
///                                       otherwise gauges in the open, peaks reflected by
///                                       Rankine–Hugoniot
///   --wing 6                            the wall this long instead of across the whole domain
///   --charges 6.46,10.05                ANFO masses to run instead of the measured ones
///   --out dir                           each run's gauge histories as CSV
///
/// `--study wall` runs the walls themselves, loaded by the air, against what was seen of them:
///
///   --wall half|canopied|masonry        the wall (all by default)
///   --bases footing,clamped             its base (footing by default for the concrete walls,
///                                       dowelled and joint for the blockwork)
///   --charges 25,125                    ANFO masses (the tests' by default)
///   --dx 0.05 --h 0.05 --time 0.2       air cells, elements, and how long
///   --no-bars                           blockwork without its bars
///   --no-joints                         blockwork as one material, without its mortar joints
///   --clearance 3                       the air behind and above, in wall heights
///   --footing 2,0.5                     the footing's width and depth (the thesis's 2.2 × 0.6 m
///                                       for the canopied wall, half that taken for the half-scale)
///
/// `--study panel` runs a strip of the blockwork alone, with no air, under a pressure pulse:
///
///   --length 0.2 --peak 2.5e6 --duration 1.3e-3 --time 0.03 --h 0.05   its length, the pulse
///                                       (peak Pa, falling to zero over the duration; near the
///                                       25 kg charge's on the face), how long
///   --free-ends                         its ends free to move along the wall (held by default)
///   --no-bars --no-joints               as for the wall
func runPerimeter(device: MTLDevice) throws {
    switch option("study") ?? "air" {
    case "air": try runPerimeterAir(device: device)
    case "wall": try runPerimeterWall(device: device)
    case "panel":
        let r = try PerimeterWallTests.blockworkPanel(
            device: device, length: option("length").flatMap { Float($0) } ?? 0.2,
            heldEnds: !flag("free-ends"),
            bars: !flag("no-bars"),
            joints: !flag("no-joints"), peak: option("peak").flatMap { Float($0) } ?? 2.5e6,
            duration: option("duration").flatMap { Float($0) } ?? 1.3e-3,
            time: option("time").flatMap { Float($0) } ?? 0.03,
            elementSize: option("h").flatMap { Float($0) } ?? 0.05,
            progress: flag("progress") ? { print("    " + $0) } : nil)
        print(
            "Blockwork panel: top \(format(Double(r.peakTop) * 1000, 1)) mm peak, "
                + "\(format(Double(r.finalTop) * 1000, 1)) left; fastest \(format(Double(r.fastest), 2)) m/s; "
                + "\(format(r.erodedFraction * 100, 1))% removed; compacted to \(format(Double(r.compaction) * 100, 2))%"
        )
    default: print("Unknown study; use --study air, wall or panel")
    }
}

private func runPerimeterAir(device: MTLDevice) throws {
    let dx = option("dx").flatMap { Float($0) } ?? 0.05
    let refine = option("refine").flatMap { Int($0) } ?? 1
    let columns = option("columns").flatMap { Float($0) }
    let wing = option("wing").flatMap { Float($0) }
    let override = option("charges").map { $0.split(separator: ",").compactMap { Float($0) } }
    let out = option("out")
    if let out { try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true) }
    let chosen = option("layout") ?? "all"
    typealias T = PerimeterWallTests
    print(
        "Alsubaei (2015): the air alone, the wall rigid; ANFO as \(format(Double(T.tntFactor), 2)) of TNT; "
            + "cells of \(format(Double(dx) * 1000, 0)) mm" + (refine > 1 ? " refined by \(refine)" : "")
            + (columns.map {
                "; rigid columns \(format(Double($0) * 1000, 0)) mm square, peaks beside their faces"
            }
                ?? "; gauges in the open, peaks reflected square-on (Rankine–Hugoniot)")
            + (wing.map { "; the wall \(format(Double($0), 1)) m long" }
                ?? "; the wall across the whole domain"))

    func run(_ layout: T.Layout, _ anfo: Float, wall: Bool) throws -> T.AirResult {
        let r = try T.runAir(
            device: device, layout: layout, anfo: anfo, wall: wall, cellSize: dx, refinement: refine,
            columnWidth: columns, wallLength: wing, afterburning: flag("afterburn"),
            progress: flag("progress") ? { print("    " + $0) } : nil)
        print(
            "  \(format(Double(anfo), 2)) kg \(wall ? "with" : "without") the wall: "
                + "\(format(r.wallSeconds, 0)) s")
        if let out {
            var csv = "time_s"
            for c in layout.chargeToColumns.indices {
                for g in layout.gaugeHeights.indices { csv += ",B\(c + 1)P\(g + 1)_Pa" }
            }
            csv += "\n"
            let count = r.histories.map { $0.count }.min() ?? 0
            for n in 0..<count {
                csv += String(format: "%.7f", r.histories[0][n].time)
                for h in r.histories { csv += String(format: ",%.1f", h[n].pressure) }
                csv += "\n"
            }
            let name = String(
                format: "%@%.0fm-%.2fkg-%@-dx%.0fmm%@%@.csv", layout.name.prefix(4).lowercased(),
                layout.chargeToWall, anfo, wall ? "wall" : "open", dx * 1000, refine > 1 ? "-refined" : "",
                columns == nil ? "" : "-columns")
            try csv.write(
                toFile: (out as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return r
    }

    func cells(_ values: [Float?], digits: Int = 0) -> String {
        values.map { pad($0.map { format(Double($0), digits) } ?? "-", 7) }.joined()
    }

    // The no-wall peaks against the measured ones, and the wall's factor on them.
    func compare(
        _ layout: T.Layout, noWall: [T.Measured], factors: [T.Measured],
        absoluteBehind: [(String, [Float])] = [],
        absoluteNoWall: T.Measured? = nil
    ) throws {
        print(
            "\n\(layout.name), \(format(Double(layout.heightOfBurst), 1)) m up; gauges at "
                + layout.gaugeHeights.map { format(Double($0), 2) }.joined(separator: ", ") + " m")
        var masses = Set(noWall.map(\.anfo)).union(factors.map(\.anfo))
        if let absoluteNoWall { masses.insert(absoluteNoWall.anfo) }
        let wallMasses =
            override.map(Set.init) ?? Set(factors.map(\.anfo)).union(absoluteBehind.isEmpty ? [] : masses)
        if let override { masses = Set(override) }
        var open: [Float: T.AirResult] = [:]
        var walled: [Float: T.AirResult] = [:]
        for anfo in masses.sorted() {
            open[anfo] = try run(layout, anfo, wall: false)
            if wallMasses.contains(anfo) { walled[anfo] = try run(layout, anfo, wall: true) }
        }
        func column(_ distance: Float) -> Int? {
            layout.chargeToColumns.firstIndex { abs($0 - distance) < 0.01 }
        }
        print("No wall: the columns' peak reflected pressure, kPa (model / measured)")
        for m in noWall + (absoluteNoWall.map { [$0] } ?? []) {
            guard let r = open[m.anfo], let c = column(m.chargeToColumn) else { continue }
            let model = r.readings[c].map { Optional($0.reflected / 1000) }
            let ratio = zip(model, m.values).map { a, b -> Float? in
                guard let a, let b, b > 0 else { return nil }
                return a / b
            }
            print(
                "  " + pad("\(format(Double(m.anfo), 2)) kg at \(format(Double(m.chargeToColumn), 2)) m", 22)
                    + "model " + cells(model) + "  measured " + cells(m.values) + "  ratio "
                    + cells(ratio, digits: 2))
        }
        if !factors.isEmpty {
            print("Behind the wall over without it, on the peaks (model / measured)")
            for m in factors {
                guard let a = open[m.anfo], let b = walled[m.anfo], let c = column(m.chargeToColumn) else {
                    continue
                }
                let model = zip(b.readings[c], a.readings[c]).map { Optional($0.reflected / $1.reflected) }
                print(
                    "  "
                        + pad(
                            "\(format(Double(m.anfo), 2)) kg at \(format(Double(m.chargeToColumn), 2)) m", 22)
                        + "model " + cells(model, digits: 2) + "  measured " + cells(m.values, digits: 2))
            }
            // The model's factors at the other columns, where nothing was measured.
            for anfo in walled.keys.sorted() {
                guard let a = open[anfo], let b = walled[anfo] else { continue }
                for (c, distance) in layout.chargeToColumns.enumerated()
                where !factors.contains(where: { $0.anfo == anfo && abs($0.chargeToColumn - distance) < 0.01 }
                ) {
                    let model = zip(b.readings[c], a.readings[c]).map {
                        Optional($0.reflected / $1.reflected)
                    }
                    print(
                        "  " + pad("\(format(Double(anfo), 2)) kg at \(format(Double(distance), 2)) m", 22)
                            + "model " + cells(model, digits: 2) + "  (not measured)")
                }
            }
        }
        if !absoluteBehind.isEmpty, let m = absoluteNoWall, let b = walled[m.anfo], let a = open[m.anfo],
            let c = column(m.chargeToColumn)
        {
            print("Behind the wall: the column's peak reflected pressure, kPa")
            print("  " + pad("model", 22) + cells(b.readings[c].map { Optional($0.reflected / 1000) }))
            for (name, values) in absoluteBehind {
                print("  " + pad("measured, \(name)", 22) + cells(values.map { Optional($0) }))
            }
            let model = zip(b.readings[c], a.readings[c]).map { Optional($0.reflected / $1.reflected) }
            print("  " + pad("model, factor", 22) + cells(model, digits: 2))
            let measured = absoluteBehind.map { _, values in
                zip(values, m.values).map { a, b -> Float? in b.map { a / $0 } }
            }
            for (n, (name, _)) in absoluteBehind.enumerated() {
                print("  " + pad("measured, \(name)", 22) + cells(measured[n], digits: 2))
            }
        }
        // Arrival and impulse at each column, for the record.
        print(
            "Arrival (ms) and positive impulse in the open or on the face (kPa ms), no wall | with the wall")
        for anfo in open.keys.sorted() {
            guard let a = open[anfo] else { continue }
            for (c, distance) in layout.chargeToColumns.enumerated() {
                var line =
                    "  " + pad("\(format(Double(anfo), 2)) kg at \(format(Double(distance), 2)) m", 22)
                    + a.readings[c].map {
                        pad("\(format($0.arrival * 1000, 1))/\(format(Double($0.impulse), 0))", 11)
                    }
                    .joined()
                if let b = walled[anfo] {
                    line +=
                        "| "
                        + b.readings[c].map {
                            pad("\(format($0.arrival * 1000, 1))/\(format(Double($0.impulse), 0))", 11)
                        }.joined()
                }
                print(line)
            }
        }
    }

    if chosen == "half" || chosen == "all" {
        try compare(T.halfScale, noWall: T.halfScaleNoWall, factors: T.halfScaleFactors)
    }
    if chosen == "street" || chosen == "all" {
        try compare(T.halfScaleStreet, noWall: T.streetNoWall, factors: T.streetFactors)
    }
    if chosen == "canopied" || chosen == "all" {
        try compare(
            T.canopied, noWall: [], factors: [], absoluteBehind: T.canopiedBehind,
            absoluteNoWall: T.canopiedNoWall)
    }
}

private func runPerimeterWall(device: MTLDevice) throws {
    typealias T = PerimeterWallTests
    let dx = option("dx").flatMap { Float($0) } ?? 0.05
    let h = option("h").flatMap { Float($0) } ?? 0.05
    let duration = option("time").flatMap { Double($0) }
    let walls =
        option("wall").map {
            $0.split(separator: ",").compactMap { name -> T.Wall? in
                name == "half" ? .halfScale : T.Wall(rawValue: String(name))
            }
        } ?? T.Wall.allCases
    let bars = !flag("no-bars")
    // `--footing 2,0.5`: the footing's width across the wall and its depth.
    let footing = option("footing").flatMap { text -> SIMD2<Float>? in
        let parts = text.split(separator: ",").compactMap { Float($0) }
        return parts.count == 2 ? SIMD2(parts[0], parts[1]) : nil
    }
    for wall in walls {
        let layout = wall.layout
        let charges: [Float] =
            option("charges").map { $0.split(separator: ",").compactMap { Float($0) } }
            ?? (wall == .halfScale ? [14] : wall == .canopied ? [125] : [25, 125])
        let bases: [T.Base] =
            option("bases").map { $0.split(separator: ",").compactMap { T.Base(rawValue: String($0)) } }
            ?? (wall == .masonry ? [.dowelled, .joint] : [.footing])
        print(
            "\n\(layout.name): \(format(Double(wall.length), 0)) m long, rigid wing walls beyond; cells of "
                + "\(format(Double(dx) * 1000, 0)) mm, elements of \(format(Double(h) * 1000, 0)) mm"
                + (wall == .masonry ? (bars ? ", bars bonded" : ", no bars") : ""))
        switch wall {
        case .halfScale:
            print(
                "Seen: after twelve shots rising to 14 kg, light shear cracking at the foot of the front face, "
                    + "no significant deformation; no deflection measured.")
        case .canopied:
            print(
                "Seen (T-RC-W1, no foam): a crack along the foot of the front face, three flexural cracks across "
                    + "the back at mid-height, no significant deformation. The foam-faced walls' mid-height deflection, "
                    + "double-integrated: 7.3, 12.3 and 34.8 mm.")
        case .masonry:
            print(
                "Seen: at 25 kg the top 28 mm out (double-integrated), bed joints cracked on the front at courses "
                    + "1, 4–6 and 10 and on the back at 4–6, the top course slid; at 125 kg collapse, debris to about 15 m."
            )
        }
        for anfo in charges {
            // Kingery–Bulmash's surface burst at the face's distance, for scale.
            let tnt = Double(anfo * T.tntFactor)
            if let point = KingeryBulmash.point(at: Double(layout.chargeToWall) / cbrt(tnt)) {
                print(
                    "  \(format(Double(anfo), 0)) kg: Kingery–Bulmash's surface burst at the face's distance, "
                        + "\(format(point.reflectedPressure / 1000, 0)) kPa reflected, "
                        + "\(format(point.reflectedImpulse(mass: tnt), 0)) Pa s")
            }
            for base in bases {
                let r = try T.runWall(
                    device: device, wall: wall, base: base, anfo: anfo, cellSize: dx, elementSize: h,
                    duration: duration
                        ?? (wall == .halfScale ? 0.15 : anfo > 50 && wall == .masonry ? 1.0 : 0.3),
                    bars: bars, joints: !flag("no-joints"), footing: footing,
                    clearance: option("clearance").flatMap { Float($0) } ?? 3,
                    afterburning: flag("afterburn"),
                    progress: flag("progress") ? { print("    " + $0) } : nil)
                print(
                    "  \(format(Double(anfo), 0)) kg, \(base.rawValue): top \(format(Double(r.peakTop) * 1000, 1)) mm "
                        + "peak, \(format(Double(r.finalTop) * 1000, 1)) left; mid-height "
                        + "\(format(Double(r.peakMiddle) * 1000, 1)) / \(format(Double(r.finalMiddle) * 1000, 1)) mm; face "
                        + "\(format(Double(r.facePeak) / 1000, 0)) kPa, \(format(Double(r.faceImpulse), 0)) Pa s; back "
                        + "\(format(Double(r.backImpulse), 0)) Pa s; base opened \(format(Double(r.baseOpening) * 1000, 2)) mm, "
                        + "\(format(Double(r.baseSeparated) * 100, 0))% of ties broken"
                        + (base == .footing
                            ? "; footing turned \(format(Double(r.footingRotation) * 1000, 2)) mrad, slid "
                                + "\(format(Double(r.footingSlide) * 1000, 1)) mm" : "")
                        + "; \(format(r.erodedFraction * 100, 1))% removed, fastest \(format(Double(r.fastest), 1)) m/s; "
                        + "\(format(r.wallSeconds, 0)) s")
                print(
                    "    Cracks up the faces, widest (mm) and share of the length open past "
                        + "\(format(Double(r.crackWidth) * 1000, 1)) mm (on horizontal planes), front | back:"
                )
                for k in r.frontWidest.indices.reversed() {
                    let z = (Double(k) + 0.5) * Double(r.elementSize)
                    print(
                        "    " + pad("\(format(z, 2)) m", 8)
                            + pad(format(Double(r.frontWidest[k]) * 1000, 2), 7)
                            + pad(
                                "\(format(Double(r.frontSpread[k]) * 100, 0))% (\(format(Double(r.frontHorizontal[k]) * 100, 0))%)",
                                13)
                            + "| " + pad(format(Double(r.backWidest[k]) * 1000, 2), 7)
                            + "\(format(Double(r.backSpread[k]) * 100, 0))% (\(format(Double(r.backHorizontal[k]) * 100, 0))%)"
                    )
                }
            }
        }
    }
}
