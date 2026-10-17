import Foundation
import Metal
import simd

/// Langdon's quarter-scale corrugated blast wall panels under pulse pressure (Fixtures/Langdon2003;
/// docs/profiled-sheeting.md): the profiled-sheet model of a corrugated panel judged against
/// measured peak and permanent deflections.
///
/// The panel stands in the x–z plane, 880 mm wide and 915 mm high, as a `ProfiledSheet` of
/// Langdon's profile. Top and bottom it ends on its connection: the 3 mm "flexible" angle as a
/// plate across the panel's width, the flexible length long, held still along its far edge where
/// the rigid angle is. The panel's sides are free. The rig's pressure is applied uniformly to the
/// loaded face as the idealised triangular pulse, with no air. The steel is 316L at its proof
/// stress at 0.42 /s (Langdon's Table 3-4), hardening at its true tangent modulus to its true
/// strain at rupture (Table 3-3).
public enum LangdonPanelTest {
    public struct Panel: Sendable, Codable {
        public var name: String
        public var flexibleLengthMM: Float
        public var direction: String
        public var peakBarg: Float
        public var riseMS: String
        public var durationMS: Duration
        public var peakDeflectionMM: Float?
        public var permanentDeflectionMM: Deflection?

        enum CodingKeys: String, CodingKey {
            case name, direction
            case flexibleLengthMM = "flexibleLength_mm"
            case peakBarg = "peak_barg"
            case riseMS = "rise_ms"
            case durationMS = "duration_ms"
            case peakDeflectionMM = "peakDeflection_mm"
            case permanentDeflectionMM = "permanentDeflection_mm"
        }

        /// A duration in milliseconds, or ">200" where the table gives only a bound.
        public enum Duration: Sendable, Codable {
            case value(Float)
            case atLeast(Float)

            public init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let value = try? container.decode(Float.self) {
                    self = .value(value)
                } else {
                    let text = try container.decode(String.self)
                    self = .atLeast(Float(text.drop { !$0.isNumber }) ?? 200)
                }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .value(let value): try container.encode(value)
                case .atLeast(let value): try container.encode(">\(Int(value))")
                }
            }

            public var milliseconds: Float {
                switch self {
                case .value(let value), .atLeast(let value): value
                }
            }
        }

        /// A permanent deflection in millimetres, or a range ("4.0 to 5.0", "469/483"), kept by its
        /// middle.
        public struct Deflection: Sendable, Codable {
            public var millimetres: Float
            public var text: String

            public init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let value = try? container.decode(Float.self) {
                    millimetres = value
                    text = "\(value)"
                } else {
                    text = try container.decode(String.self)
                    let numbers = text.split { !($0.isNumber || $0 == ".") }.compactMap { Float($0) }
                    millimetres = numbers.isEmpty ? 0 : numbers.reduce(0, +) / Float(numbers.count)
                }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(text)
            }
        }

        public var isPositive: Bool { direction == "positive" }

        /// The rise time (s): the middle of the two where the table gives two.
        public var rise: Float {
            let numbers = riseMS.split(separator: "/").compactMap { Float($0) }
            return (numbers.isEmpty ? 0 : numbers.reduce(0, +) / Float(numbers.count)) / 1000
        }

        /// The idealised triangular pulse: time (s) and pressure (Pa).
        public var pulse: [SIMD2<Float>] {
            let duration = durationMS.milliseconds / 1000
            return [SIMD2(0, 0), SIMD2(rise, peakBarg * 1e5), SIMD2(duration, 0), SIMD2(duration + 10, 0)]
        }
    }

    struct Fixture: Decodable {
        var tests: [Panel]
    }

    /// The panels of `Fixtures/Langdon2003/panels.json`.
    public static func panels(from url: URL) throws -> [Panel] {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).tests
    }

    public struct Settings: Sendable {
        /// Shell element size (m): 16 along the span by default.
        public var elementSize: Float = 0.915 / 16
        /// The steel's yield (Pa): the 2 mm sheet's proof stress at 0.42 /s, the mean of its two
        /// directions; and the flexible angle's (3 mm).
        public var sheetYield: Float = 356e6
        public var angleYield: Float = 330e6
        /// Their true strains at rupture (Table 3-3, the means of the two directions), where an
        /// element is removed.
        public var sheetRupture: Float = 0.97
        public var angleRupture: Float = 1.12
        /// Simulated time after the pulse ends, over whose second half the permanent deflection is
        /// taken as the mean (s).
        public var after: Float = 0.08
        public var skinShare: Float = 0.05

        public init() {}
    }

    public struct Result: Sendable {
        public var panel: Panel
        /// Peak and permanent deflection at mid-span of the middle of the panel, along the load (m).
        public var peak: Float
        public var permanent: Float
        /// Mid-span deflection along the load against time (s, m).
        public var history: [SIMD2<Float>]
        /// How far the panel's bottom end moved in along its span at mid-width at the end (m), as the
        /// connection gave; and the shells and beams removed by failure.
        public var pullIn: Float
        public var failedShells: Int
        public var failedBeams: Int
    }

    /// The panel and its connections as a shell model.
    public static func model(flexibleLength: Float, settings: Settings) -> StructureModel {
        let steel316L = StructureMaterial(
            name: "316L stainless, 2 mm", density: 7900, youngsModulus: 200e9, poissonRatio: 0.3,
            yieldStress: settings.sheetYield, hardeningModulus: 1.25e9, failureStrain: settings.sheetRupture)
        var angle = steel316L
        angle.name = "316L stainless, 3 mm"
        angle.yieldStress = settings.angleYield
        angle.hardeningModulus = 1.35e9
        angle.failureStrain = settings.angleRupture
        var model = StructureModel(
            solids: [], material: angle, elementSize: settings.elementSize, fixedBase: false)
        model.elementKind = .shell
        model.shellLayers = 4
        let (width, span): (Float, Float) = (0.88, 0.915)
        var profile = SheetProfile.langdonBlastWall
        profile.yieldStress = settings.sheetYield
        let sheet = ProfiledSheet(
            profile: profile, region: Box(min: SIMD3(0, -0.01, 0), max: SIMD3(width, 0.01, span)), span: 2,
            steel: steel316L, skinShare: settings.skinShare)
        sheet.add(to: &model)
        // The flexible angles, top and bottom, out to −y; their far edges held where the rigid
        // angles are.
        let t: Float = 0.003
        let arm = flexibleLength
        for z in [Float(0), span] {
            model.solids.append(Box(min: SIMD3(0, -arm, z - t / 2), max: SIMD3(width, 0, z + t / 2)))
            model.supports.append(
                Box(
                    min: SIMD3(-0.01, -arm - 0.002, z - 0.01),
                    max: SIMD3(width + 0.01, -arm + 0.002, z + 0.01)))
        }
        return model
    }

    /// Runs one panel's test.
    public static func run(_ panel: Panel, settings: Settings = Settings(), device: MTLDevice) throws
        -> Result
    {
        let model = model(flexibleLength: panel.flexibleLengthMM / 1000, settings: settings)
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        solver.damping = 0
        // "Positive" pushes the panel towards its connections' side, −y.
        solver.appliedLoad = PressureLoad(axis: 1, positiveSide: panel.isPositive, history: panel.pulse)
        let gauge = solver.nearestNode(to: SIMD3(0.44, 0, 0.4575))
        let sign: Float = panel.isPositive ? -1 : 1
        let end = panel.durationMS.milliseconds / 1000 + settings.after
        let step = solver.criticalTimeStep
        let stepsPerSample = max(1, Int((0.0005 / step).rounded()))
        var history: [SIMD2<Float>] = []
        var time: Float = 0
        while time < end {
            solver.advance(steps: stepsPerSample)
            time += Float(stepsPerSample) * step
            history.append(SIMD2(time, sign * solver.node(gauge).displacement.y))
        }
        let peak = history.map(\.y).max() ?? 0
        let tail = history.filter { $0.x > end - settings.after / 2 }.map(\.y)
        let permanent = tail.reduce(0, +) / Float(max(tail.count, 1))
        let foot = solver.nearestNode(to: SIMD3(0.44, 0, 0))
        let failedShells = (0..<solver.elementCount).filter { solver.flag($0) != .active }.count
        let failedBeams = (0..<solver.beamCount).filter { solver.beamFlag($0) != .active }.count
        return Result(
            panel: panel, peak: peak, permanent: permanent, history: history,
            pullIn: solver.node(foot).displacement.z, failedShells: failedShells, failedBeams: failedBeams)
    }
}
