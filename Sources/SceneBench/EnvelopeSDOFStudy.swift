import BlastCore
import Foundation
import simd

/// Stage 2 of envelope damage (component-spec.md v1.2): the one-way SDOF model driven by each
/// component's load on the envelope run, judged against the same component of the detailed
/// building free to respond (stage 3a's records), with the cost of each and what not venting
/// leaves out.
///
///     scenebench envelope-sdof <reference directory> [--edges=fixed|simple] [--out=<file.json>]
enum EnvelopeSDOFStudy {
    typealias Record = EnvelopeDamageBenchmark.Record
    typealias Component = EnvelopeDamageBenchmark.Component

    struct Row: Codable {
        var run: String
        var id: String
        var kind: String
        var material: String
        var shortSpanM: Double
        /// The detailed building's: support rotation (°), whether a pane broke and when.
        var detailedRotationDeg: Double
        var detailedBroken: Bool?
        var detailedBrokenAtS: Double?
        var detailedInteriorFailedShare: Double
        /// SDOF on the envelope run's loads: rotation (°), ductility, and for a pane its break.
        var sdofRotationDeg: Double
        var sdofDuctility: Double
        var sdofBroken: Bool?
        var sdofBrokenAtS: Double?
        /// SDOF on the detailed run's own loads, to tell the load from the model.
        var sdofOnDetailedLoadsRotationDeg: Double
        var sdofOnDetailedLoadsBrokenAtS: Double?
        var envelopePeakNetKPa: Double
        var envelopeImpulsePaS: Double
        var periodMs: Double
        var ultimateKPa: Double
    }

    struct Run: Codable {
        var run: String
        var buildings: Int
        var detailedWallClockS: Double
        var envelopeWallClockS: Double
        /// The SDOF's own time for every component of the run.
        var sdofS: Double
        /// Inside each building: the detailed run's peak and positive impulse, which the envelope
        /// (ambient inside) leaves out.
        var insidePeakKPa: [Double]
        var insideImpulsePaS: [Double]
        /// The same from a one-way fill: each pane, once SDOF breaks it, an orifice into the
        /// building's room, driven by the pane's own outer pressure on the envelope run.
        var fillPeakKPa: [Double]
        var fillImpulsePaS: [Double]
    }

    /// Inside overpressure of a sealed room of `volume` m³ filled through orifices that open
    /// when their panes break: each `(area m², opens at s, outer mean pressures per bin Pa)`.
    /// Mass flows as through a sharp-edged orifice (discharge 0.6) on the pressure difference,
    /// at the upstream side's isentropic density; the room's air compresses adiabatically.
    static func fill(volume: Double, openings: [(area: Double, opens: Double, outer: [Double])], bin: Double)
        -> (peak: Double, impulse: Double)
    {
        let ambient = 101_325.0
        let density = 1.204
        let gamma = 1.4
        let count = openings.map(\.outer.count).max() ?? 0
        var mass = density * volume
        var peak = 0.0
        var impulse = 0.0
        let substeps = 20
        let h = bin / Double(substeps)
        for index in 0..<count {
            for sub in 0..<substeps {
                let time = Double(index) * bin + Double(sub) * h
                let inside = ambient * pow(mass / (density * volume), gamma)
                var flow = 0.0
                for opening in openings where time >= opening.opens && index < opening.outer.count {
                    let outside = ambient + opening.outer[index]
                    let difference = outside - inside
                    let upstream = max(outside, inside)
                    let rho = density * pow(upstream / ambient, 1 / gamma)
                    flow +=
                        (difference >= 0 ? 1 : -1) * 0.6 * opening.area
                        * (2 * rho * abs(difference)).squareRoot()
                }
                mass = max(mass + flow * h, 1e-3)
                let over = ambient * pow(mass / (density * volume), gamma) - ambient
                peak = max(peak, over)
                impulse += max(over, 0) * h
            }
        }
        return (peak, impulse)
    }

    struct Summary: Codable {
        var edges: String
        var notes: [String]
        var runs: [Run]
        var components: [Row]
    }

    static func system(for component: Component, edges: EnvelopePanel.Edges) -> SDOFSystem? {
        let a = Double(component.shortSpanM)
        let b = Double(component.longSpanM)
        switch component.material {
        case "reinforcedConcrete":
            // 0.2 m with one central mat of 600 mm²/m each way (stage 3a's README).
            return EnvelopePanel.reinforcedConcrete(
                thickness: 0.2, depth: 0.1, steelArea: 600e-6, material: .reinforcedConcrete, a: a, b: b,
                edges: edges)
        case "masonry":
            var masonry = StructureMaterial.masonry
            masonry.steel = nil
            return EnvelopePanel.unreinforcedMasonry(
                thickness: 0.215, material: masonry, a: a, b: b, edges: edges)
        case "annealedGlass":
            return EnvelopePanel.glass(thickness: 0.006, material: .annealedGlass, a: a, b: b, edges: edges)
        default:
            return nil
        }
    }

    /// The net pressure on a component as mean pressures per bin: (∫ p_outer − ∫ p_inner) / bin.
    static func pressures(_ component: Component, bin: Double) -> [Double] {
        zip(
            component.outerImpulsePaS,
            component.innerImpulsePaS
                + Array(
                    repeating: 0,
                    count: max(0, component.outerImpulsePaS.count - component.innerImpulsePaS.count))
        )
        .map { Double($0 - $1) / bin }
    }

    static func rotation(_ response: SDOFResponse, span: Double) -> Double {
        atan(max(response.peakDeflection, -response.reboundDeflection) / (span / 2)) * 180 / .pi
    }

    static func run(_ arguments: [String]) throws {
        guard let directory = arguments.first else {
            print(
                "usage: scenebench envelope-sdof <reference directory> [--edges=fixed|simple] [--out=<file.json>]"
            )
            return
        }
        func option(_ name: String) -> String? {
            arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
        }
        let edges: EnvelopePanel.Edges = option("edges") == "simple" ? .simplySupported : .fixed
        let folder = URL(fileURLWithPath: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix("-envelope.json") }
            .sorted()
        let decoder = JSONDecoder()
        var rows: [Row] = []
        var runs: [Run] = []
        for name in names {
            let base = String(name.dropLast(5))
            let twin = folder.appendingPathComponent(base + "-envelope.json")
            guard FileManager.default.fileExists(atPath: twin.path) else { continue }
            let detailed = try decoder.decode(
                Record.self, from: Data(contentsOf: folder.appendingPathComponent(name)))
            let envelope = try decoder.decode(Record.self, from: Data(contentsOf: twin))
            guard detailed.representation == "detailed" else { continue }
            let loads = Dictionary(uniqueKeysWithValues: envelope.components.map { ($0.id, $0) })
            var sdofTime = 0.0
            var openings: [UUID: [(area: Double, opens: Double, outer: [Double])]] = [:]
            for component in detailed.components {
                guard let system = system(for: component, edges: edges), let load = loads[component.id] else {
                    continue
                }
                let span = Double(component.shortSpanM)
                let start = DispatchTime.now().uptimeNanoseconds
                let response = system.response(
                    pressures: pressures(load, bin: envelope.binS), step: envelope.binS)
                sdofTime += Double(DispatchTime.now().uptimeNanoseconds - start) * 1e-9
                let own = system.response(
                    pressures: pressures(component, bin: detailed.binS), step: detailed.binS)
                let isPane = component.material == "annealedGlass"
                if isPane, let opens = response.lostResistanceAt {
                    openings[component.owner, default: []].append(
                        (
                            Double(component.shortSpanM * component.longSpanM), opens,
                            load.outerImpulsePaS.map { Double($0) / envelope.binS }
                        ))
                }
                rows.append(
                    Row(
                        run: base, id: component.id, kind: component.kind, material: component.material,
                        shortSpanM: span, detailedRotationDeg: Double(abs(component.rotationDeg)),
                        detailedBroken: component.broken, detailedBrokenAtS: component.brokenAtS,
                        detailedInteriorFailedShare: Double(component.interiorFailedShare),
                        sdofRotationDeg: rotation(response, span: span), sdofDuctility: response.ductility,
                        sdofBroken: isPane ? response.lostResistanceAt != nil : nil,
                        sdofBrokenAtS: response.lostResistanceAt,
                        sdofOnDetailedLoadsRotationDeg: rotation(own, span: span),
                        sdofOnDetailedLoadsBrokenAtS: own.lostResistanceAt,
                        envelopePeakNetKPa: Double(load.peakNetPa) / 1000,
                        envelopeImpulsePaS: pressures(load, bin: envelope.binS).reduce(0) { $0 + max($1, 0) }
                            * envelope.binS,
                        periodMs: system.period * 1000, ultimateKPa: system.ultimateResistance / 1000))
            }
            let inside = detailed.gauges.filter { $0.name.hasSuffix("inside") }
            // Each building's room: its walls' plan inside their thickness, up to the roof.
            var fills: [(peak: Double, impulse: Double)] = []
            for owner in Set(detailed.components.map(\.owner)).sorted(by: { $0.uuidString < $1.uuidString }) {
                let walls = detailed.components.filter { $0.owner == owner && $0.kind != "pane" }
                let low = walls.flatMap(\.region).reduce(SIMD3<Float>(repeating: .infinity)) {
                    simd_min($0, $1)
                }
                let high = walls.flatMap(\.region).reduce(SIMD3<Float>(repeating: -.infinity)) {
                    simd_max($0, $1)
                }
                let size = SIMD3<Double>(high - low) - SIMD3(0.4, 0.4, 0.2)
                fills.append(
                    fill(
                        volume: size.x * size.y * size.z, openings: openings[owner] ?? [], bin: envelope.binS)
                )
            }
            runs.append(
                Run(
                    run: base, buildings: Set(detailed.components.map(\.owner)).count,
                    detailedWallClockS: detailed.wallClockS, envelopeWallClockS: envelope.wallClockS,
                    sdofS: sdofTime,
                    insidePeakKPa: inside.map { Double($0.peakOverpressurePa) / 1000 },
                    insideImpulsePaS: inside.map { Double($0.positiveImpulsePaS) },
                    fillPeakKPa: fills.map { $0.peak / 1000 }, fillImpulsePaS: fills.map(\.impulse)))
        }
        report(rows: rows, runs: runs)
        if let out = option("out") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let summary = Summary(
                edges: edges.rawValue,
                notes: [
                    "SDOF after UFC 3-340-02 on the envelope run's loads; detailed: stage 3a's buildings free to respond.",
                    "Rotation atan(peak / (short span / 2)), in degrees, either way.",
                ], runs: runs, components: rows)
            try encoder.encode(summary).write(to: URL(fileURLWithPath: out))
        }
    }

    static func report(rows: [Row], runs: [Run]) {
        func f(_ value: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", value) }
        print("run | component | detailed θ° | SDOF θ° (on detailed loads) | μ | T ms | r_u kPa | peak kPa")
        for row in rows where row.material != "annealedGlass" {
            let short = row.id.split(separator: "/").suffix(2).joined(separator: "/")
            print(
                "\(row.run) | \(short) | \(f(row.detailedRotationDeg, 3)) | \(f(row.sdofRotationDeg, 3)) (\(f(row.sdofOnDetailedLoadsRotationDeg, 3))) | \(f(row.sdofDuctility)) | \(f(row.periodMs, 1)) | \(f(row.ultimateKPa, 1)) | \(f(row.envelopePeakNetKPa, 1))"
            )
        }
        print("\nrun | pane | detailed broken (ms) | SDOF broken (ms) | on detailed loads (ms) | peak kPa")
        for row in rows where row.material == "annealedGlass" {
            let short = row.id.split(separator: "/").suffix(2).joined(separator: "/")
            func when(_ broken: Bool?, _ at: Double?) -> String {
                broken == true ? "yes" + (at.map { " (\(f($0 * 1000, 1)))" } ?? "") : "no"
            }
            print(
                "\(row.run) | \(short) | \(when(row.detailedBroken, row.detailedBrokenAtS)) | \(when(row.sdofBroken, row.sdofBrokenAtS)) | \(when(row.sdofOnDetailedLoadsBrokenAtS != nil, row.sdofOnDetailedLoadsBrokenAtS)) | \(f(row.envelopePeakNetKPa, 1))"
            )
        }
        print(
            "\nrun | buildings | detailed s | envelope s | SDOF ms | inside peak kPa (fill) | inside impulse Pa s (fill)"
        )
        for run in runs {
            print(
                "\(run.run) | \(run.buildings) | \(f(run.detailedWallClockS, 1)) | \(f(run.envelopeWallClockS, 1)) | \(f(run.sdofS * 1000, 2)) | \(zip(run.insidePeakKPa, run.fillPeakKPa).map { f($0, 2) + " (" + f($1, 2) + ")" }.joined(separator: ", ")) | \(zip(run.insideImpulsePaS, run.fillImpulsePaS).map { f($0, 1) + " (" + f($1, 1) + ")" }.joined(separator: ", "))"
            )
        }
    }
}
