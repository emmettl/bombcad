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
func runPerimeter(device: MTLDevice) throws {
    switch option("study") ?? "air" {
    case "air": try runPerimeterAir(device: device)
    default: print("Unknown study; use --study air")
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
            columnWidth: columns, wallLength: wing,
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
                format: "%@-%.2fkg-%@-dx%.0fmm%@.csv", layout.name.prefix(4).lowercased(), anfo,
                wall ? "wall" : "open", dx * 1000, columns == nil ? "" : "-columns")
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
