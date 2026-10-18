import Foundation
import Metal
import simd

/// NIST's steel moment-frame assemblies under a column's removal (F. Sadek, J. A. Main, H. S. Lew,
/// S. D. Robert, V. P. Chiarito and S. El-Tawil, *An experimental and computational study of steel
/// moment connections under a column removal scenario*, NIST TN 1669, 2010, open): two spans of 6.10
/// m between three columns, the middle one a stub pushed down until the connections at it fractured.
/// - WUF-B: W21×73 beams welded to W18×119 columns; failed at 495 mm, 890 kN, a chord rotation of
///   0.081 rad, the beams pulling 667 kN.
/// - RBS: W24×94 beams with reduced sections to W24×131 columns; failed at 851 mm, 1,780 kN,
///   0.14 rad, the beams pulling 2,447 kN.
/// And a gravity frame's simple connection, from J. M. Weigand and J. W. Berman, *Steel gravity
/// connections subjected to large rotations and axial loads* (Connections VIII, 2016, open, NIST):
/// - SPS: W18×35 beams on single-plate shear connections (three 19 mm bolts, 9.5 mm plate) to
///   W14×90 columns, two simulated spans of 9.1 m. The test loaded one connection as such a system
///   would, its beams taken as rigid; the eight three-bolt connections on that span failed at a
///   median drop of 892 mm (772–972), at a median turn of 0.0905 rad, pull of 431 kN and shear at
///   the column face of 40 kN, so the stub's load about 2 (T sin θ + V cos θ) = 157 kN. The
///   steels' yields were not read; A992's nominal 345 and 450 MPa are taken.
/// Here the members are the shell solver's beams, rectangles scaled to each section's major-axis
/// stiffness, plastic moment and mass (`SteelSection.equivalent`), at the measured yields (Table
/// 3–1) without a strain-rate law, the test being slow. The end columns are taken one storey high
/// (4.19 m, the buildings' 13 ft 9 in), the beams at mid-height, fixed at the foot and held sideways
/// at the top as the test's braces held them (the figure giving their height was not read); out of
/// plane everything is held, as the beams were braced at mid-span. The stub is pushed down at
/// `speed`; the joints are rigid, or hinged by `connection`.
public enum ColumnRemovalTest {
    public enum Specimen: String, Sendable, CaseIterable {
        case weldedFlange = "WUF-B"
        case reducedBeamSection = "RBS"
        case singlePlateShear = "SPS"

        /// The connection the specimen was built with.
        public var connection: SteelConnection {
            switch self {
            case .weldedFlange: .weldedFlange
            case .reducedBeamSection: .reducedBeamSection
            case .singlePlateShear: .singlePlateShear
            }
        }

        /// Each span between columns, m.
        var span: Float { self == .singlePlateShear ? 9.1 : 6.10 }
    }

    public struct Result: Sendable {
        /// Largest load (N) and the stub's drop then (m); the drop at which the load fell to half
        /// its largest after it, if it did (the assembly failed).
        public var peakLoad: Float
        public var dropAtPeak: Float
        public var failedAt: Float?
        public var hingesReleased: Int
        public var curve: [SIMD2<Float>]
    }

    /// The beams' and columns' sections (AISC's tables), their steels' measured yield and ultimate
    /// (Pa), and what the test measured: failure drop (m) and load (N).
    static func specimen(_ s: Specimen) -> (
        beam: SteelSection, column: SteelSection, beamSteel: SIMD2<Float>, columnSteel: SIMD2<Float>,
        measured: (drop: Float, load: Float)
    ) {
        let inch: Float = 0.0254
        func section(_ name: String, d: Float, bf: Float, area: Float, ix: Float, zx: Float) -> SteelSection {
            SteelSection(
                name: name, depth: d * inch, width: bf * inch, area: area * inch * inch,
                secondMoment: ix * pow(inch, 4), plasticModulus: zx * pow(inch, 3))
        }
        switch s {
        case .weldedFlange:
            return (
                section("W21×73", d: 21.2, bf: 8.30, area: 21.6, ix: 1600, zx: 172),
                section("W18×119", d: 19.0, bf: 11.3, area: 35.1, ix: 2190, zx: 262),
                SIMD2(359e6, 496e6), SIMD2(352e6, 456e6), (0.495, 890e3)
            )
        case .reducedBeamSection:
            return (
                section("W24×94", d: 24.3, bf: 9.07, area: 27.7, ix: 2700, zx: 254),
                section("W24×131", d: 24.5, bf: 12.9, area: 38.5, ix: 4020, zx: 370),
                SIMD2(455e6, 554e6), SIMD2(378e6, 494e6), (0.851, 1780e3)
            )
        case .singlePlateShear:
            return (
                section("W18×35", d: 17.7, bf: 6.00, area: 10.3, ix: 510, zx: 66.5),
                section("W14×90", d: 14.0, bf: 14.5, area: 26.5, ix: 999, zx: 157),
                SIMD2(345e6, 450e6), SIMD2(345e6, 450e6), (0.892, 157e3)
            )
        }
    }

    public static func measured(_ s: Specimen) -> (drop: Float, load: Float) { specimen(s).measured }

    public static func run(
        device: MTLDevice, specimen s: Specimen, connection: SteelConnection?, speed: Float = 0.1,
        drop: Float = 1.1, elementSize: Float = 0.15
    ) throws -> Result {
        let (beam, column, beamSteel, columnSteel, _) = specimen(s)
        func steel(_ strength: SIMD2<Float>) -> StructureMaterial {
            var material = StructureMaterial.structuralSteel
            material.yieldStress = strength.x
            // To the ultimate at 15% strain, and no strain-rate law: the test was slow.
            material.hardeningModulus = (strength.y - strength.x) / 0.15
            material.rateLaw = nil
            return material
        }
        let span = s.span
        let storey: Float = 4.19
        let level = storey / 2
        let stub: Float = 0.75
        let beamWidth = beam.rectangleWidth
        let columnWidth = column.rectangleWidth
        var solids: [Box] = []
        var materials: [StructureMaterial] = []
        // Beams along x, their depth up; columns up, their depth along x.
        solids.append(
            Box(
                min: SIMD3(0, -beamWidth / 2, level - beam.depth / 2),
                max: SIMD3(2 * span, beamWidth / 2, level + beam.depth / 2)))
        materials.append(beam.equivalent(of: steel(beamSteel), width: beamWidth))
        for x in [Float(0), 2 * span] {
            solids.append(
                Box(
                    min: SIMD3(x - column.depth / 2, -columnWidth / 2, 0),
                    max: SIMD3(x + column.depth / 2, columnWidth / 2, storey)))
            materials.append(column.equivalent(of: steel(columnSteel), width: columnWidth))
        }
        solids.append(
            Box(
                min: SIMD3(span - column.depth / 2, -columnWidth / 2, level - stub),
                max: SIMD3(span + column.depth / 2, columnWidth / 2, level + stub)))
        materials.append(column.equivalent(of: steel(columnSteel), width: columnWidth))
        // The two spans as two beams, each ending at the stub, so that each has its connection there.
        solids[0].max.x = span
        solids.insert(
            Box(
                min: SIMD3(span, -beamWidth / 2, level - beam.depth / 2),
                max: SIMD3(2 * span, beamWidth / 2, level + beam.depth / 2)), at: 1)
        materials.insert(materials[0], at: 1)
        var model = StructureModel(
            solids: solids, material: materials[0], elementSize: elementSize, fixedBase: false)
        model.elementKind = .shell
        for (index, material) in materials.enumerated() where material != model.material {
            model.setMaterial(material, of: index)
        }
        model.steelConnection = connection
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        solver.damping = 5
        let positions = solver.referencePositions
        let feet = solver.nodes { $0.z < 1e-4 }
        let tops = solver.nodes { $0.z > storey - 1e-4 }
        let pushed = solver.nodes { abs($0.x - span) < 1e-3 && $0.z > level + stub - 1e-4 }
        solver.mutateNodes { nodes in
            for n in nodes.indices { nodes[n].restrain(y: true) }
            for n in feet { nodes[n].restrain(x: true, y: true, z: true, rotation: true) }
            for n in tops { nodes[n].restrain(x: true, y: true) }
            for n in pushed {
                nodes[n].restrain(x: true, y: true)
                nodes[n].isPrescribed = true
                nodes[n].velocity = SIMD3(0, 0, -speed)
            }
        }
        _ = positions
        // The stub starts at full speed, a jolt the load rings with at first; peak and failure are
        // read past the first tenth of the test's drop.
        let settled = 0.1 * Self.measured(s).drop
        var curve: [SIMD2<Float>] = []
        var peak: Float = 0
        var atPeak: Float = 0
        var failedAt: Float?
        let chunk = max(1, Int(0.005 / solver.criticalTimeStep))
        // The load read every 5 ms rings with the stub's mass; it is judged on its mean over the
        // last 10 mm of drop.
        let window = max(1, Int(0.01 / (speed * 0.005)))
        while Float(solver.time) * speed < drop {
            solver.advance(steps: chunk)
            let down = Float(solver.time) * speed
            curve.append(SIMD2(down, abs(pushed.reduce(Float(0)) { $0 + solver.nodalForce($1).z })))
            let recent = curve.suffix(window)
            let load = recent.reduce(0) { $0 + $1.y } / Float(recent.count)
            guard down > settled else { continue }
            if load > peak {
                peak = load
                atPeak = down
            }
            if failedAt == nil, peak > 0.5 * Self.measured(s).load, load < 0.5 * peak {
                failedAt = down
                break
            }
        }
        return Result(
            peakLoad: peak, dropAtPeak: atPeak, failedAt: failedAt, hingesReleased: solver.hingesReleased,
            curve: curve)
    }
}
