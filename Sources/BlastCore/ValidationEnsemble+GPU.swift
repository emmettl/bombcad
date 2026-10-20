import BlastModel
import Foundation
import Metal
import simd

extension ValidationEnsemble {
    static func peterson(_ prefix: String, title: String) -> EnsembleCase {
        let tests = petersonTests(prefix)
        func measured(_ value: (ImpactBenchmark.PetersonTest) -> Float?) -> (Double?, Double?) {
            let values = tests.compactMap(value).map { Double($0) / 1000 }
            return (values.isEmpty ? nil : values.reduce(0, +) / Double(values.count), scatter(values))
        }
        let impact = measured(\.impact)
        let near = measured(\.nearReaction)
        let far = measured(\.farReaction)
        return EnsembleCase(
            id: "peterson-\(prefix.lowercased())", title: title,
            inputs: [
                statedStrength(36e6), tensile, fracture,
            ] + steel(measured: true) + [
                EnsembleInput(
                    key: "pad", name: "the fibreboard's stiffness, as a factor",
                    distribution: .logNormal(median: 1, variation: 0.5),
                    source: "fitted to the impact forces; the board's own stiffness unknown, 50% assumed"),
                EnsembleInput(
                    key: "speed", name: "impact speed, as a factor",
                    distribution: .normal(mean: 1, deviation: 0.02),
                    source: "a drop of 2.4 m through a guiding tube; 2% for its friction, assumed"),
            ],
            outputs: [
                EnsembleOutput(
                    key: "impact", name: "impact force", unit: "kN", measured: impact.0,
                    measuredVariation: impact.1),
                EnsembleOutput(
                    key: "near", name: "near reaction", unit: "kN", measured: near.0,
                    measuredVariation: near.1),
                EnsembleOutput(
                    key: "far", name: "far reaction", unit: "kN", measured: far.0, measuredVariation: far.1),
            ], estimatedSeconds: 12)
    }

    /// Every case: the validation's own, then the calibration's.
    public static let cases: [EnsembleCase] = validationCases + calibrationCases

    static let validationCases: [EnsembleCase] = [
        EnsembleCase(
            id: "contest-slab",
            title: "Contest slab (2013 blast blind simulation contest), 8 elements through",
            inputs: [
                statedStrength(5400 * 6894.76), tensile, fracture,
            ] + steel(measured: true) + [
                EnsembleInput(
                    key: "load", name: "pressure record, as a factor",
                    distribution: .normal(mean: 1, deviation: 0.03),
                    source: "two readings of the record differ by 4% in impulse"),
                EnsembleInput(
                    key: "supports", name: "supports: lines of nodes (≤ 0.5) or 1 in bearings free to lift",
                    distribution: .uniform(low: 0, high: 1),
                    source: "the rig is not described; either, equally likely"),
            ],
            outputs: [
                EnsembleOutput(
                    key: "peak", name: "peak deflection", unit: "mm", measured: 109,
                    // The repeat (the contest's slab 4) peaked at 113 mm: range 4 mm on a mean of 111,
                    // over d2 = 1.128 for two.
                    measuredVariation: 0.032)
            ], estimatedSeconds: 27),
        EnsembleCase(
            id: "janney", title: "Janney's beam bent to failure, 12 elements through",
            inputs: [statedStrength(36.2e6), tensile, fracture] + steel(measured: false),
            outputs: [
                EnsembleOutput(
                    key: "moment", name: "peak moment", unit: "kN m", measured: 41.5, measuredVariation: nil),
                EnsembleOutput(
                    key: "failure", name: "deflection at failure", unit: "mm", measured: 42,
                    measuredVariation: nil),
            ], estimatedSeconds: 58),
        EnsembleCase(
            id: "oa1",
            title: "OA1, a beam without stirrups failing in shear, 24 elements through, a 92 mm slice",
            inputs: [measuredStrength(22.6e6), tensile, fracture] + steel(measured: false),
            outputs: [
                EnsembleOutput(
                    key: "peak", name: "peak load", unit: "kN", measured: 332, measuredVariation: nil),
                EnsembleOutput(
                    key: "deflection", name: "deflection at the peak", unit: "mm", measured: 9.2,
                    measuredVariation: nil),
            ], estimatedSeconds: 14),
        EnsembleCase(
            id: "saatci", title: "Saatci's SS2b-1, struck by 600 kg at 8 m/s, 16 elements through",
            inputs: [
                measuredStrength(Double(saatciTest.concreteStrength)),
                EnsembleInput(
                    key: "ftAbsolute", name: "tensile strength (Pa)",
                    distribution: .uniform(low: 3.1e6, high: 3.4e6),
                    source: "measured after the tests: 3.1 to 3.4 MPa"),
                fracture,
            ] + steel(measured: true) + [
                EnsembleInput(
                    key: "speed", name: "impact speed, as a factor",
                    distribution: .normal(mean: 1, deviation: 0.01),
                    source: "a drop of 3.26 m; 1%, assumed")
            ],
            outputs: [
                EnsembleOutput(
                    key: "peak", name: "peak deflection", unit: "mm", measured: 37.9, measuredVariation: nil),
                EnsembleOutput(
                    key: "residual", name: "residual deflection", unit: "mm", measured: 18.5,
                    measuredVariation: nil),
                EnsembleOutput(
                    key: "reaction", name: "largest support reaction", unit: "kN", measured: 592,
                    measuredVariation: nil),
            ], estimatedSeconds: 35),
        peterson("D-1d-NoS", title: "Peterson's D-1d-NoS, struck at one depth from a support, no stirrups"),
        peterson("D-2d-S90", title: "Peterson's D-2d-S90, struck at two depths, stirrups at 90 mm"),
        EnsembleCase(
            id: "wu-s8", title: "Wu et al.'s S8, 1.6 kg at 0.5 m over a 2 m slab, coupled",
            inputs: [
                EnsembleInput(
                    key: "fc", name: "concrete compressive strength",
                    distribution: .normal(mean: 0.8 * 47e6, deviation: 0.8 * 0.9e6),
                    source: "six cubes: 47.0 MPa, 1.9%; taken as 0.8 of the cubes'"),
                EnsembleInput(
                    key: "cylinder", name: "cylinder over cube strength, as a factor on 0.8",
                    distribution: .uniform(low: 0.94, high: 1.06), source: "0.75 to 0.85, assumed"),
                tensile, fracture,
            ] + steel(measured: false) + [
                chargeMass(0.02, source: "TNT, weighed; 2%, assumed"),
                standoff(0.5, deviation: 0.005),
            ],
            outputs: [
                EnsembleOutput(
                    key: "peak", name: "peak deflection, 300 mm from the centre", unit: "mm",
                    measured: Double(wuTest.peak ?? 0) * 1000, measuredVariation: nil),
                EnsembleOutput(
                    key: "residual", name: "residual deflection there", unit: "mm",
                    measured: Double(wuTest.residual ?? 0) * 1000, measuredVariation: nil),
            ], estimatedSeconds: 1000),
        EnsembleCase(
            id: "chiquito-s1", title: "Chiquito et al.'s S1–S3, 2 kg at 1 m over a slab, coupled",
            inputs: [
                statedStrength(33e6), tensile, fracture,
            ] + steel(measured: false) + [
                chargeMass(0.08, source: "PG2 and dynamite stated as TNT; their equivalence ±15%, as 8%"),
                standoff(1.0, deviation: 0.02),
            ],
            outputs: [
                // The text's values; the scatter from the three shots' peaks in its Figure 9.
                EnsembleOutput(
                    key: "near", name: "peak at G1, 1 m", unit: "MPa", measured: 2.5,
                    measuredVariation: scatter([3.3, 3.45, 3.6])),
                EnsembleOutput(
                    key: "far", name: "peak at G3, 2 m", unit: "MPa", measured: 0.5,
                    measuredVariation: scatter([0.47, 0.525, 0.58])),
            ], estimatedSeconds: 300),
        EnsembleCase(
            id: "kb-wall",
            title: "100 kg on a rigid wall at 2 m/kg^(1/3), 0.25 m cells, against Kingery–Bulmash",
            inputs: [
                chargeMass(0.02, source: "a cast charge, weighed; 2%, assumed"),
                standoff(wallDistance * pow(100, 1.0 / 3), deviation: 0.05),
            ],
            outputs: [
                EnsembleOutput(
                    key: "pressure", name: "reflected peak overpressure", unit: "kPa",
                    measured: KingeryBulmash.point(at: wallDistance).map { $0.reflectedPressure / 1000 },
                    measuredVariation: nil),
                EnsembleOutput(
                    key: "impulse", name: "reflected impulse", unit: "Pa s",
                    measured: KingeryBulmash.point(at: wallDistance).map { $0.reflectedImpulse(mass: 100) },
                    measuredVariation: nil),
            ], estimatedSeconds: 5),
        EnsembleCase(
            id: "kb-curve",
            title:
                "The Kingery–Bulmash curves themselves for the wall case's inputs: what its inputs' spread alone does",
            inputs: [
                chargeMass(0.02, source: "a cast charge, weighed; 2%, assumed"),
                standoff(wallDistance * pow(100, 1.0 / 3), deviation: 0.05),
            ],
            outputs: [
                EnsembleOutput(
                    key: "pressure", name: "reflected peak overpressure", unit: "kPa",
                    measured: KingeryBulmash.point(at: wallDistance).map { $0.reflectedPressure / 1000 },
                    measuredVariation: nil),
                EnsembleOutput(
                    key: "impulse", name: "reflected impulse", unit: "Pa s",
                    measured: KingeryBulmash.point(at: wallDistance).map { $0.reflectedImpulse(mass: 100) },
                    measuredVariation: nil),
            ], estimatedSeconds: 0.001),
    ]

    public static func estimatedSeconds(case id: String) -> Double {
        cases.first { $0.id == id }?.estimatedSeconds ?? 60
    }

    /// Each case and its inputs, for `--list`.
    public static var listing: [String] {
        cases.flatMap { item in
            ["\(item.id): \(item.title)"]
                + item.inputs.map { "  \($0.name): \($0.distribution.description) (\($0.source))" }
        }
    }

    /// `count` samples of `case`'s inputs by a Latin hypercube seeded with `seed`, after the run
    /// with every input at its middle value, which comes first.
    public static func samples(case id: String, count: Int, seed: UInt64) throws -> [EnsembleSample] {
        guard let item = cases.first(where: { $0.id == id }) else {
            throw EnsembleError("No validation case \(id).")
        }
        let middle = Dictionary(
            uniqueKeysWithValues: item.inputs.map { ($0.key, $0.distribution.value(at: 0.5)) })
        let points = latinHypercube(count: count, dimensions: item.inputs.count, seed: seed)
        return [EnsembleSample(caseID: id, index: 0, values: middle)]
            + points.enumerated().map { number, point in
                EnsembleSample(
                    caseID: id, index: number + 1,
                    values: Dictionary(
                        uniqueKeysWithValues: zip(item.inputs, point).map {
                            ($0.key, $0.distribution.value(at: $1))
                        }))
            }
    }

    /// `case` run at each of `points`, its own inputs at their middle values and each point's
    /// values over them (a calibration's design: `afterburnTime`, `ft`, `glassK`).
    public static func designSamples(case id: String, points: [[String: Double]]) throws -> [EnsembleSample] {
        let middle = try samples(case: id, count: 0, seed: 0)[0]
        return points.enumerated().map { number, point in
            EnsembleSample(
                caseID: id, index: number, values: middle.values.merging(point) { _, chosen in chosen })
        }
    }

    /// `case`'s run with every input at its middle value, once with each of the kernels'
    /// roundings, the default first: the spread a different rounding gives, which is where results
    /// after failure are one draw among several.
    public static func roundingSamples(case id: String) throws -> [EnsembleSample] {
        let middle = try samples(case: id, count: 0, seed: 0)[0]
        return KernelRounding.allCases.enumerated().map { number, rounding in
            EnsembleSample(caseID: id, index: number, values: middle.values, rounding: rounding)
        }
    }

    /// Runs `sample` on this Mac's GPU.
    public static func run(_ sample: EnsembleSample) throws -> EnsembleOutcome {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw BlastError.allocationFailed("No Metal device")
        }
        let start = ContinuousClock.now
        // An output that did not happen (a beam that never failed) is left out. In a pool of its own:
        // what building a solver autoreleases keeps it alive until a pool drains, and an ensemble's
        // runs, one after another on a worker's thread, kept every one's memory.
        let outputs = try autoreleasepool {
            try KernelRounding.$current.withValue(sample.rounding) {
                try outputs(sample, device: device).filter(\.value.isFinite)
            }
        }
        let took = start.duration(to: .now)
        return EnsembleOutcome(
            outputs: outputs,
            seconds: Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18,
            device: device.name)
    }

    static func outputs(_ sample: EnsembleSample, device: MTLDevice) throws -> [String: Double] {
        let values = sample.values
        func value(_ key: String, _ fallback: Double = 1) -> Double { values[key] ?? fallback }
        switch sample.caseID {
        case "contest-slab":
            let supports: SlabBenchmark.Supports =
                value("supports", 0) <= 0.5 ? .lines : .bearings(width: 0.0254, holdDown: false)
            let result = try SlabBenchmark.run(
                device: device, loadScale: Float(value("load")), supports: supports,
                adjust: { $0 = perturbed($0, values) })
            return ["peak": Double(result.peak) * 1000]
        case "janney":
            let result = try BeamBenchmark.run(device: device, adjust: { $0 = perturbed($0, values) })
            return [
                "moment": Double(result.peakMoment) / 1000,
                "failure": result.failureDeflection.map { Double($0) * 1000 } ?? .nan,
            ]
        case "oa1":
            let result = try ShearBeamBenchmark.run(
                device: device, elementsThroughDepth: 24, slice: 0.092, adjust: { $0 = perturbed($0, values) }
            )
            return ["peak": Double(result.peak) / 1000, "deflection": Double(result.peakDeflection) * 1000]
        case "saatci":
            var specimen = ImpactBenchmark.specimen(saatciTest)
            specimen.material = perturbed(specimen.material, values)
            let result = try ImpactBenchmark.run(
                device: device, specimen: specimen, weight: saatciTest.weight,
                speed: ImpactBenchmark.impactSpeed * Float(value("speed")))
            return [
                "peak": Double(result.peak) * 1000, "residual": Double(result.residual) * 1000,
                "reaction": Double(result.peakReaction) / 1000,
            ]
        case let id where id.hasPrefix("peterson-"):
            let prefix = String(id.dropFirst("peterson-".count))
            guard
                let test = ImpactBenchmark.petersonTests.first(where: {
                    $0.name.lowercased().hasPrefix(prefix)
                })
            else { throw EnsembleError("No Peterson test \(prefix).") }
            var specimen = ImpactBenchmark.specimen(test)
            specimen.material = perturbed(specimen.material, values)
            specimen.pad = specimen.pad.map { $0 * Float(value("pad")) }
            let result = try ImpactBenchmark.run(
                device: device, specimen: specimen, weight: ImpactBenchmark.petersonWeight,
                speed: ImpactBenchmark.petersonSpeed * Float(value("speed")), duration: 0.03)
            return [
                "impact": Double(result.peakImpactForce) / 1000,
                "near": Double(result.supportReactions.x) / 1000,
                "far": Double(result.supportReactions.y) / 1000,
            ]
        case "wu-s8":
            var test = wuTest
            test.charge *= Float(value("mass"))
            test.standoff = Float(value("standoff", Double(wuTest.standoff ?? 0.5)))
            var concrete = values
            concrete["fc"] = value("fc", 0.8 * 47e6) * value("cylinder")
            // Today's air and start, every open face at the clearance rule (rerun 18 October 2026; the
            // first run, of 11 October, was on the ideal gas in the harness's box).
            let result = try TwoFaceSlabTests.run(
                device: device, test: test, roomy: true,
                adjust: { scenario in
                    if let material = scenario.structure?.material {
                        scenario.structure?.material = perturbed(material, concrete)
                    }
                })
            return ["peak": Double(result.peaks[0]) * 1000, "residual": Double(result.residuals[0]) * 1000]
        case "chiquito-s1":
            var test = chiquitoTest
            test.charge *= Float(value("mass"))
            test.standoff = Float(value("standoff", Double(chiquitoTest.standoff)))
            let result = try CloseInSlabTest.run(
                device: device, test: test, roomy: true,
                adjust: { scenario in
                    if let material = scenario.structure?.material {
                        scenario.structure?.material = perturbed(material, values)
                    }
                })
            func peak(_ prefix: String) -> Double {
                Double(result.gaugePeaks.first { $0.name.hasPrefix(prefix) }?.pressure ?? .nan) / 1e6
            }
            return ["near": peak("G1"), "far": peak("G3")]
        case "kb-curve":
            let mass = 100 * value("mass")
            guard let point = KingeryBulmash.point(at: value("standoff") / cbrt(mass)) else {
                throw EnsembleError("Outside the Kingery–Bulmash curves.")
            }
            return [
                "pressure": point.reflectedPressure / 1000, "impulse": point.reflectedImpulse(mass: mass),
            ]
        case "kb-wall":
            return try wall(
                mass: 100 * Float(value("mass")), standoff: Float(value("standoff")),
                afterburnTime: values["afterburnTime"].map { Float($0) }, device: device)
        case "kb-open":
            return try openBurst(afterburnTime: values["afterburnTime"].map { Float($0) }, device: device)
        case "kb-reflected":
            var outputs: [String: Double] = [:]
            for z in calibrationDistances {
                let wall = try autoreleasepool {
                    try Self.wall(
                        mass: 100, standoff: Float(z * cbrt(100.0)),
                        afterburnTime: values["afterburnTime"].map { Float($0) }, device: device)
                }
                outputs["r\(Int(z))"] = wall["impulse"]
            }
            return outputs
        case "glass-monk":
            return try monkBreakTimes(flawFactor: value("glassK"))
        case "glass-e1300":
            return e1300Resistances(flawFactor: value("glassK"))
        default:
            throw EnsembleError("No validation case \(sample.caseID).")
        }
    }

    /// A hemispherical surface burst of `mass` kg on rigid ground, `standoff` metres from a rigid
    /// wall, as `blastbench validate` runs its reflected cases: the reflected peak overpressure
    /// (kPa) and impulse (Pa s) at the wall's foot.
    static func wall(
        mass: Float, standoff: Float, afterburnTime: Float? = nil, device: MTLDevice
    ) throws -> [String: Double] {
        var wall = ScenarioPreset.openGround.scenario
        wall.charge.mass = mass
        wall.reflectiveFaces = [.zMin, .xMax]
        wall.charge.position = SIMD3(64 - standoff, 32, 0)
        wall.gauges = [Gauge("Wall", at: SIMD3(63.99, 32, 0.05))]
        // The air every run ships with (`SolverConfiguration.recommended`), the mapped start with it.
        var configuration = SolverConfiguration.recommended
        if let afterburnTime { configuration.afterburnTime = afterburnTime }
        let solver = try BlastSolver(
            device: device, scenario: wall, cellSize: wallCell, configuration: configuration)
        solver.advance(until: 0.1)
        let cell = solver.nearestFluidCell(to: wall.gauges[0].position)
        return [
            "pressure": Double(
                (solver.gaugeHistories[0].map(\.pressure).max() ?? 0) - wall.atmosphere.pressure)
                / 1000,
            "impulse": Double(solver.impulse(cell.i, cell.j, cell.k)),
        ]
    }
}

// MARK: - Calibration's cases (docs/calibration.md)

extension ValidationEnsemble {
    /// The scaled distances, m/kg^(1/3), of the calibration's open-air comparisons.
    static let calibrationDistances: [Double] = [1, 2, 4]

    /// Cases for calibrating the model's own parameters (`afterburnTime`, `ft`, `glassK` in a
    /// sample's values) rather than a specimen's inputs: none of their own inputs is uncertain.
    static let calibrationCases: [EnsembleCase] = {
        let points = calibrationDistances.compactMap { KingeryBulmash.point(at: $0) }
        let monk = (try? monkFixture()).map { fixture in
            fixture.panes.map { pane in
                EnsembleOutput(
                    key: "t" + pane.aspect.replacingOccurrences(of: ":", with: "-"),
                    name: "break time, aspect \(pane.aspect)", unit: "ms",
                    measured: pane.breakTime[0],
                    measuredVariation: fixture.breakTimes[pane.aspect].flatMap { scatter($0) })
            }
        }
        return [
            EnsembleCase(
                id: "kb-open",
                title:
                    "100 kg surface burst on rigid ground, 0.25 m cells: incident impulse against Kingery–Bulmash",
                inputs: [],
                outputs: zip(calibrationDistances, points).map { z, point in
                    EnsembleOutput(
                        key: "i\(Int(z))", name: "incident impulse at Z = \(Int(z))", unit: "Pa s",
                        measured: point.incidentImpulse(mass: 100))
                }, estimatedSeconds: 30),
            EnsembleCase(
                id: "kb-reflected",
                title:
                    "100 kg on a rigid wall at Z = 1, 2, 4, 0.25 m cells: reflected impulse against Kingery–Bulmash",
                inputs: [],
                outputs: zip(calibrationDistances, points).map { z, point in
                    EnsembleOutput(
                        key: "r\(Int(z))", name: "reflected impulse at Z = \(Int(z))", unit: "Pa s",
                        measured: point.reflectedImpulse(mass: 100))
                }, estimatedSeconds: 20),
            EnsembleCase(
                id: "glass-monk",
                title:
                    "Monk and Clubley's 4 mm annealed panes at Shoeburyness: break times (large deflection)",
                inputs: [], outputs: monk ?? [], estimatedSeconds: 1),
            EnsembleCase(
                id: "glass-e1300",
                title: "ASTM E1300's load resistance of four annealed panes (Soules, Morse and Norville)",
                inputs: [],
                outputs: e1300Panes.map { pane in
                    EnsembleOutput(
                        key: "lr" + pane.name, name: "load resistance, pane \(pane.name)", unit: "kPa",
                        measured: pane.load)
                }, estimatedSeconds: 1),
        ]
    }()

    /// The surface burst of `blastbench validate`, 100 kg on 0.25 m cells with the recommended
    /// air: each distance's incident positive impulse (Pa s) 5 cm above the ground.
    static func openBurst(afterburnTime: Float?, device: MTLDevice) throws -> [String: Double] {
        var scenario = ScenarioPreset.openGround.scenario
        scenario.charge.mass = 100
        scenario.charge.position = SIMD3(32, 32, 0)
        let points = calibrationDistances.compactMap { KingeryBulmash.point(at: $0) }
        scenario.gauges = points.map { point in
            Gauge("Z = \(point.scaledDistance)", at: SIMD3(32 + Float(point.range(mass: 100)), 32, 0.05))
        }
        var configuration = SolverConfiguration.recommended
        if let afterburnTime { configuration.afterburnTime = afterburnTime }
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: wallCell, configuration: configuration)
        solver.advance(until: 0.1)
        var outputs: [String: Double] = [:]
        for (z, gauge) in zip(calibrationDistances, scenario.gauges) {
            let cell = solver.nearestFluidCell(to: gauge.position)
            outputs["i\(Int(z))"] = Double(solver.impulse(cell.i, cell.j, cell.k))
        }
        return outputs
    }

    /// Monk and Clubley's panes (`Fixtures/MonkClubley/windows.json`), as `GlassMeasurementTests`
    /// reads them.
    struct MonkFixture: Decodable {
        struct Pane: Decodable {
            var aspect: String
            var opening: [Double]
            var breakTime: [Double]
            enum CodingKeys: String, CodingKey {
                case aspect
                case opening = "opening_m"
                case breakTime = "breakTime_ms"
            }
        }
        struct Reflected: Decodable { var allTrials: [[Double]] }
        var panes: [Pane]
        var reflectedPressure: Reflected
        var breakTimes: [String: [Double]]
        enum CodingKeys: String, CodingKey {
            case panes, reflectedPressure
            case breakTimes = "breakTimes_ms"
        }
    }

    static func monkFixture() throws -> MonkFixture {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures/MonkClubley/windows.json")
        return try JSONDecoder().decode(MonkFixture.self, from: Data(contentsOf: url))
    }

    /// Each aspect ratio's break time (ms) on the median of the trials' reflected pressure, the
    /// app's large-deflection pane with its 60 s strength times `flawFactor`^(−1/7): the flaw
    /// constant, or the share of the pane at its largest stress, times `flawFactor`.
    static func monkBreakTimes(flawFactor: Double) throws -> [String: Double] {
        let fixture = try monkFixture()
        let step = 1e-5
        let points = [[0.0, 0.0]] + fixture.reflectedPressure.allTrials.map { [$0[0], $0[1]] }
        let load = (0..<2000).map { n -> Double in
            let ms = Double(n) * step * 1000
            guard let i = points.firstIndex(where: { $0[0] >= ms }) else { return points.last![1] * 1000 }
            if i == 0 { return 0 }
            let (a, b) = (points[i - 1], points[i])
            return (a[1] + (ms - a[0]) / (b[0] - a[0]) * (b[1] - a[1])) * 1000
        }
        var outputs: [String: Double] = [:]
        for pane in fixture.panes {
            let (a, b) = (pane.opening[0], pane.opening[1])
            let glass = EnvelopePanel.largeDeflectionGlass(
                thickness: 0.004, material: .annealedGlass, a: a, b: b,
                sixtySecondStrength: GlassStrength.sixtySecond(area: a * b)
                    * pow(flawFactor, -1 / GlassStrength.weibullModulus))
            let response = glass.response(pressures: load, step: step)
            outputs["t" + pane.aspect.replacingOccurrences(of: ":", with: "-")] =
                response.lostResistanceAt.map { $0 * 1000 } ?? .nan
        }
        return outputs
    }

    /// Four of the eight panes `GlassMeasurementTests.e1300` takes from Soules, Morse and Norville
    /// (the largest, a square, a strip and a long one): long and short side, thickness (m), E1300's
    /// load resistance (kPa).
    static let e1300Panes: [(name: String, a: Double, b: Double, t: Double, load: Double)] = [
        ("A", 1.930, 0.965, 0.00556, 2.0), ("D", 1.676, 1.676, 0.00457, 1.4),
        ("T", 1.829, 0.254, 0.00556, 21.3), ("CC", 3.048, 2.286, 0.01191, 2.0),
    ]

    /// Each pane's load (kPa) breaking 8 in 1,000 held for 3 s on Moore's plate, with the whole
    /// pane at its largest stress and the flaw constant times `flawFactor`.
    static func e1300Resistances(flawFactor: Double) -> [String: Double] {
        let modulus = 71.7e9 / (12 * (1 - 0.22 * 0.22))
        var outputs: [String: Double] = [:]
        for c in e1300Panes {
            func stress(_ q: Double) -> Double {
                let r = MooreGlassCurves.response(load: q * pow(c.b / c.t, 4) / modulus, aspect: c.a / c.b)
                return r.stress * modulus * pow(c.t / c.b, 2)
            }
            let breaking =
                GlassStrength.sixtySecond(area: c.a * c.b, probability: 0.008)
                * pow(flawFactor, -1 / GlassStrength.weibullModulus)
                / pow(3 / 60, 1 / GlassStrength.fatigueExponent)
            var (low, high) = (1.0, 1e7)
            for _ in 0..<100 {
                let mid = (low * high).squareRoot()
                if stress(mid) < breaking { low = mid } else { high = mid }
            }
            outputs["lr" + c.name] = low / 1000
        }
        return outputs
    }
}
