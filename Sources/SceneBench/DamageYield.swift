import BlastCore
import Foundation
import simd

/// `scenebench damage-yield <district-scene's inputs> --loads folder --mass kg [--radius 2500]
/// [--geer Facade_damage.shp] [--structure a.dbf,b.dbf] [--yields 50000,100000,…] [--draws 100]`:
/// what yield the damage surveyed on a scene's own buildings says, at the scene's charge place
/// (emmettl/bombcad-work#18, stage 4). Each survey's chances by the quick estimate at each yield, as
/// the app gives them: GEER's openings blown out (W3) against the openings' fragility
/// (`openingsBlownOut`, fitted to GEER at 0.5 kt, so circular there), and GEER's structural classes
/// against the walls' chances (`structureProbabilities`): stone walls heavily damaged for D3 or
/// worse, concrete moderately for D2 or worse, a class that straddles the line left out. The
/// likelihood by distance bands (beta-binomial, as the inference weighs glass) and building by
/// building; the posterior over the yields' grid with a prior flat in log yield.
enum DamageYield {
    /// A survey's observations: each one's distance from the charge, what was seen, and its chance
    /// at each yield.
    struct Evidence {
        var name: String
        var distances: [Double]
        var observed: [Bool]
        var chances: [[Double]] = []
    }

    static func run(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        let start = ContinuousClock.now
        let reference = try SurrogateBench.Reference(args)
        let scene = reference.scene
        let objects = reference.objects
        let dx = reference.cellSize
        let charge = scene.charge.position
        let draws = value("draws").flatMap(Int.init) ?? 100
        let yields =
            (value("yields")
            ?? "50000,100000,150000,200000,300000,400000,500000,700000,1000000,1400000,2000000,3000000,5000000")
            .split(separator: ",").compactMap { Double($0) }
        let centre = SurrogateBench.centre(args)
        let metresPerDegree = ElevationGrid.metresPerDegree
        let corner = SIMD2(
            centre.x - Double(reference.radius) / (metresPerDegree * cos(centre.y * .pi / 180)),
            centre.y - Double(reference.radius) / metresPerDegree)
        let placement = MapBuildingPlacement(origin: corner, resolution: dx)
        var evidence: [Evidence] = []

        // GEER's façades: the openings blown out (W3).
        if let path = value("geer") {
            let (sides, matches, records) = try GlassCalibration.geerFacades(
                path, scene: scene, objects: objects, raster: reference.raster, cellSize: dx,
                radius: reference.radius, centre: centre)
            print("GEER: \(matches.count) of \(records.count) façades matched to a side")
            let used = Array(Set(matches.map(\.side))).sorted()
            let index = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($1, $0) })
            var openings = Evidence(
                name: "GEER openings W3 (fragility fitted to GEER at 0.5 kt)",
                distances: matches.map(\.distance), observed: matches.map { $0.observedClass >= 3 })
            for mass in yields {
                let (p, _) = FacadeLoadSurrogate.glassProbabilities(
                    sides: used.map { sides[$0] }, mass: mass, cellSize: dx,
                    uncertainty: FacadeLoadSurrogate.Uncertainty(masses: [mass], samples: draws))
                openings.chances.append(matches.map { p[index[$0.side]!].openingsBlownOut })
            }
            evidence.append(openings)
        }

        // GEER's structural classes, each matched to the map building its centroid lies in (or the
        // nearest within 15 m), built as GEER says.
        if let paths = value("structure") {
            enum Built { case stone, concrete }
            var observations: [(object: Int, built: Built, damaged: Bool, distance: Double, said: Double)] =
                []
            var skipped: [String: Int] = [:]
            let footprints = objects.map { object -> (SIMD2<Float>, SIMD2<Float>) in
                let (low, high) = SurrogateBench.bounds(object)
                return (SIMD2(low.x, low.y), SIMD2(high.x, high.y))
            }
            for path in paths.split(separator: ",").map(String.init) {
                for record in try ChargeInferenceInputs.readDBF(URL(filePath: path)) {
                    func field(_ name: String) -> String? {
                        record[name]?.trimmingCharacters(in: .whitespaces)
                    }
                    guard let lat = field("Latitude").flatMap(Double.init),
                        let lon = field("Longitude").flatMap(Double.init),
                        let damage = field("Damage_Cla"), !damage.isEmpty
                    else {
                        skipped["no place or class", default: 0] += 1
                        continue
                    }
                    // Only the first visit of a building visited twice.
                    if let visit = field("VID"), visit != "0" { continue }
                    let type = (field("Str_Type") ?? "").lowercased()
                    let built: Built
                    if type.hasPrefix("stone masonry bearing") || type.hasPrefix("sandstone bearing") {
                        built = .stone
                    } else if type.hasPrefix("reinforced concrete frame")
                        || type.hasPrefix("reinforced concrete walls")
                        || type == "rc frame"
                    {
                        built = .concrete
                    } else {
                        skipped["mixed or other structure", default: 0] += 1
                        continue
                    }
                    // The classes it may be (D0-D1 is 0 and 1), against the line its kind is judged at.
                    let classes = damage.uppercased().split(separator: "-").compactMap {
                        Int($0.trimmingCharacters(in: .whitespaces).dropFirst())
                    }
                    guard let low = classes.min(), let high = classes.max() else {
                        skipped["class unread", default: 0] += 1
                        continue
                    }
                    let line = built == .stone ? 3 : 2
                    guard low >= line || high < line else {
                        skipped["class straddles the line", default: 0] += 1
                        continue
                    }
                    let at = SIMD2<Float>(placement.position(SIMD2(lon, lat)))
                    var best: (Int, Float)?
                    for (n, (low, high)) in footprints.enumerated() {
                        let d = simd_length(simd_max(simd_max(low - at, at - high), .zero))
                        if d < (best?.1 ?? 15) { best = (n, d) }
                    }
                    guard let (n, _) = best else {
                        skipped["no map building within 15 m", default: 0] += 1
                        continue
                    }
                    observations.append(
                        (
                            n, built, low >= line, Double(simd_distance(at, SIMD2(charge.x, charge.y))),
                            field("Distance").flatMap(Double.init) ?? .nan
                        ))
                }
            }
            // A building matched twice keeps its first.
            var seen = Set<Int>()
            observations = observations.filter { seen.insert($0.object).inserted }
            print(
                "GEER structure: \(observations.count) buildings matched (stone \(observations.filter { $0.built == .stone }.count)); skipped "
                    + skipped.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(
                        separator: ", "))
            let offsets = observations.map { abs($0.distance - $0.said) }.filter(\.isFinite).sorted()
            if !offsets.isEmpty {
                print(
                    String(
                        format: "  distances against GEER's own: median %.0f m apart, most %.0f m",
                        offsets[offsets.count / 2], offsets.last!))
            }
            // The quick estimate of the matched buildings alone, built as GEER says.
            let full = FacadeLoadSurrogate.estimate(scene: scene, cellSize: dx)
            let builtOf = Dictionary(
                observations.map { (objects[$0.object].id, $0.built) }, uniquingKeysWith: { a, _ in a })
            var estimate = full
            let keep = full.components.indices.filter { builtOf[full.components[$0].owner] != nil }
            estimate.components = keep.map { full.components[$0] }
            estimate.owners = keep.map { full.owners[$0] }
            estimate.features = keep.map { full.features[$0] }
            estimate.predictions = keep.map { full.predictions[$0] }
            estimate.loads = keep.map { full.loads[$0] }
            func construction(_ id: UUID) -> EnvelopeConstruction {
                var c = scene.envelopeConstruction(for: id)
                if builtOf[id] == .stone {
                    c.walls = .unreinforcedMasonry
                    c.wallThicknessM = 0.5
                } else {
                    c.walls = .reinforcedConcrete
                }
                return c
            }
            for built in [Built.stone, .concrete] {
                let members = observations.filter { $0.built == built }
                guard !members.isEmpty else { continue }
                var structure = Evidence(
                    name: built == .stone
                        ? "GEER stone buildings D3 or worse, walls heavy or worse"
                        : "GEER concrete buildings D2 or worse, walls moderate or worse",
                    distances: members.map(\.distance), observed: members.map(\.damaged))
                for mass in yields {
                    let (chances, _) = FacadeLoadSurrogate.structureProbabilities(
                        estimate, mass: mass, cellSize: dx, constructions: construction,
                        uncertainty: FacadeLoadSurrogate.Uncertainty(masses: [mass], samples: draws))
                    let byOwner = Dictionary(uniqueKeysWithValues: chances.map { ($0.owner, $0) })
                    structure.chances.append(
                        members.map { m in
                            let c = byOwner[objects[m.object].id]
                            return (built == .stone ? c?.wallsHeavy : c?.wallsModerate) ?? 0
                        })
                }
                evidence.append(structure)
            }
        }

        // Each survey's likelihood at each yield, and the yield it says.
        let bands: [Double] = [500, 750, 1000, 1500, 2500, .infinity]
        for e in evidence {
            print("\n\(e.name): \(e.observed.count) observed, \(e.observed.filter { $0 }.count) damaged")
            let header = bands.map { $0.isFinite ? String(format: "to %.0f m", $0) : "beyond" }
            var counts = [Int](repeating: 0, count: bands.count)
            var damaged = [Int](repeating: 0, count: bands.count)
            for (d, o) in zip(e.distances, e.observed) {
                let b = bands.firstIndex { d < $0 }!
                counts[b] += 1
                damaged[b] += o ? 1 : 0
            }
            print(
                "  seen (damaged of observed): "
                    + zip(header, zip(damaged, counts)).map { "\($0) \($1.0)/\($1.1)" }.joined(
                        separator: ", "))
            var banded: [Double] = []
            var single: [Double] = []
            for (j, mass) in yields.enumerated() {
                var expected = [Double](repeating: 0, count: bands.count)
                var bernoulli = 0.0
                for (k, d) in e.distances.enumerated() {
                    let p = e.chances[j][k]
                    expected[bands.firstIndex { d < $0 }!] += p
                    let chance = min(max(p, 0.02), 0.98)
                    bernoulli += log(e.observed[k] ? chance : 1 - chance)
                }
                var sum = 0.0
                for b in bands.indices where counts[b] > 0 {
                    sum += ChargeInference.logBetaBinomial(
                        k: damaged[b], n: counts[b], p: expected[b] / Double(counts[b]), kappa: 30)
                }
                banded.append(sum)
                single.append(bernoulli)
                print(
                    String(format: "  %6.0f t: expected ", mass / 1000)
                        + expected.map { String(format: "%6.1f", $0) }.joined(separator: " ")
                        + String(format: "   log L banded %8.1f, each %8.1f", sum, bernoulli))
            }
            for (label, logL) in [("banded", banded), ("building by building", single)] {
                let (median, low, high) = posterior(yields: yields, logL: logL)
                print(
                    String(
                        format: "  yield said, %@: %.2f kt (90%%: %.2f–%.2f)%@", label as NSString,
                        median / 1e6, low / 1e6, high / 1e6,
                        (low <= yields.first! * 1.0001 || high >= yields.last! * 0.9999
                            ? ", at the grid's end" : "") as NSString))
            }
        }
        print(String(format: "\nIn %.0f s", DistrictBenchmark.seconds(start)))
    }

    /// The posterior's median and 90% interval over `yields`, the log likelihood interpolated
    /// linearly in log yield between them, the prior flat in log yield.
    static func posterior(yields: [Double], logL: [Double]) -> (Double, Double, Double) {
        let logs = yields.map { log($0) }
        let steps = 2000
        let grid = (0...steps).map { logs.first! + (logs.last! - logs.first!) * Double($0) / Double(steps) }
        let values = grid.map { x -> Double in
            let i = min(max((logs.lastIndex { $0 <= x } ?? 0), 0), logs.count - 2)
            let t = (x - logs[i]) / (logs[i + 1] - logs[i])
            return logL[i] + t * (logL[i + 1] - logL[i])
        }
        let most = values.max()!
        let weights = values.map { exp($0 - most) }
        let total = weights.reduce(0, +)
        var cumulative = 0.0
        var quantiles: [Double] = []
        var targets = [0.05, 0.5, 0.95]
        for (x, w) in zip(grid, weights) {
            cumulative += w / total
            while let t = targets.first, cumulative >= t {
                quantiles.append(exp(x))
                targets.removeFirst()
            }
        }
        while quantiles.count < 3 { quantiles.append(yields.last!) }
        return (quantiles[1], quantiles[0], quantiles[2])
    }
}
