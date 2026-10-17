import Foundation
import Metal
import simd

/// Glulam beams in the University of Ottawa's shock tube: D. N. Lacroix, PhD thesis, University of
/// Ottawa, 2017 (open), with Lacroix and Doudak, J. Struct. Eng. 144(9), 2018.
///
/// Spruce-pine glulam, 80 x 228 mm (20f-E), 86 x 318 mm and 137 x 222 mm (24f-ES), 2,500 mm long
/// and simply supported over 2,235 mm, loaded at the third points through the same hinged device
/// as Poulin's panels (3.55 m^2; 317.3 and 321.0 kg moving with the 86 and 137 mm beams). The
/// thesis tabulates the static tests (its Table 4.3: modulus of rupture and of elasticity), the
/// elastic shots (Table 4.4) and the destructive ones (Table 4.5: the peak deflection recorded, the
/// largest dynamic resistance and the deflection there, which for these brittle beams is where
/// they broke).
///
/// The model calibrates on the static tests and is judged on the shots: each series' measured
/// stiffness and density, its coupons' compressive strength, and a tension strength along the
/// grain equal to its static modulus of rupture (a beam that breaks in tension in bending, as
/// these did); across the grain and in shear, GL24h's. The 80 and 86 mm beams mesh as walls bending
/// in their plane, the 137 mm one as a beam of 4 x 4 fibres. The device's force is shared between
/// the nodes on the load lines (through the walls' depth, as the bearing plates spread it), its
/// mass likewise.
public enum LacroixGlulamTest {
    public struct Series: Sendable {
        public var name: String
        public var width: Float
        public var depth: Float
        public var modulus: Float
        public var rupture: Float
        public var compression: Float
        public var density: Float
        public var movingMass: Float
    }

    /// Table 4.3's means; the coupons' compressive strength (Table 4.1; the 80 mm beams, without
    /// coupons, take the 86 mm ones'); the densities the thesis gives (489 kg/m^3 for the single
    /// laminate, 551 for the others); and the moving masses (the 80 mm beams', not given, from the
    /// device's 283.6 kg that the 86 mm system implies).
    public static let series: [Series] = [
        Series(
            name: "80", width: 0.080, depth: 0.228, modulus: 8.368e9, rupture: 51.2e6, compression: 40.6e6,
            density: 489, movingMass: 283.6 + 0.080 * 0.228 * 2.235 * 489),
        Series(
            name: "86", width: 0.086, depth: 0.318, modulus: 8.025e9, rupture: 41.5e6, compression: 40.6e6,
            density: 551, movingMass: 317.3),
        Series(
            name: "137", width: 0.137, depth: 0.222, modulus: 10.07e9, rupture: 45.6e6, compression: 48.6e6,
            density: 551, movingMass: 321.0),
    ]

    public struct Shot: Sendable {
        public var name: String
        public var series: String
        public var pressure: Float
        public var impulse: Float
        /// Peak deflection recorded (m); for a destructive shot, also the deflection at its
        /// largest resistance, where it broke (m).
        public var deflection: Float
        public var atBreak: Float?
    }

    /// Tables 4.4 (elastic) and 4.5 (destructive); shots whose record was unusable are left out.
    public static let shots: [Shot] = [
        Shot(name: "B12.1", series: "80", pressure: 14.2e3, impulse: 158.2, deflection: 0.0156),
        Shot(name: "B13.1", series: "80", pressure: 10.7e3, impulse: 122.9, deflection: 0.0112),
        Shot(name: "B14.1", series: "80", pressure: 9.2e3, impulse: 60.1, deflection: 0.0064),
        Shot(name: "B15.1", series: "80", pressure: 18.9e3, impulse: 188.1, deflection: 0.0185),
        Shot(name: "B17.1", series: "80", pressure: 28.3e3, impulse: 231.8, deflection: 0.0261),
        Shot(name: "B5.1", series: "86", pressure: 14.9e3, impulse: 126.0, deflection: 0.0062),
        Shot(name: "B5.2", series: "86", pressure: 45.9e3, impulse: 448.6, deflection: 0.0217),
        Shot(name: "B6.1", series: "86", pressure: 13.2e3, impulse: 140.5, deflection: 0.0062),
        Shot(name: "B7.1", series: "86", pressure: 16.8e3, impulse: 155.0, deflection: 0.0074),
        Shot(name: "B5.1-137", series: "137", pressure: 11.0e3, impulse: 124.1, deflection: 0.0076),
        Shot(name: "B6.1-137", series: "137", pressure: 13.1e3, impulse: 121.3, deflection: 0.0070),
        Shot(name: "B7.1-137", series: "137", pressure: 11.7e3, impulse: 125.7, deflection: 0.0084),
        Shot(name: "B9.1-137", series: "137", pressure: 10.9e3, impulse: 105.5, deflection: 0.0042),
        Shot(
            name: "B12.2", series: "80", pressure: 40.7e3, impulse: 369.5, deflection: 0.1327, atBreak: 0.0344
        ),
        Shot(
            name: "B13.2", series: "80", pressure: 42.7e3, impulse: 397.1, deflection: 0.0726, atBreak: 0.0297
        ),
        Shot(
            name: "B14.2", series: "80", pressure: 41.4e3, impulse: 333.8, deflection: 0.0378, atBreak: 0.0325
        ),
        Shot(
            name: "B15.2", series: "80", pressure: 40.0e3, impulse: 372.6, deflection: 0.1155, atBreak: 0.0316
        ),
        Shot(
            name: "B16.1", series: "80", pressure: 52.1e3, impulse: 390.5, deflection: 0.1839, atBreak: 0.0446
        ),
        Shot(
            name: "B17.2", series: "80", pressure: 44.7e3, impulse: 328.4, deflection: 0.1379, atBreak: 0.0305
        ),
        Shot(
            name: "B18.1", series: "80", pressure: 49.3e3, impulse: 337.0, deflection: 0.1112, atBreak: 0.0357
        ),
        Shot(
            name: "B19.1", series: "80", pressure: 54.5e3, impulse: 353.4, deflection: 0.0944, atBreak: 0.0219
        ),
        Shot(
            name: "B20.1", series: "80", pressure: 54.8e3, impulse: 347.0, deflection: 0.1598, atBreak: 0.0208
        ),
        Shot(
            name: "B21.1", series: "80", pressure: 58.2e3, impulse: 292.6, deflection: 0.0997, atBreak: 0.0274
        ),
        Shot(
            name: "B5.3", series: "86", pressure: 48.7e3, impulse: 549.7, deflection: 0.0709, atBreak: 0.0222),
        Shot(
            name: "B6.2", series: "86", pressure: 66.4e3, impulse: 697.1, deflection: 0.1144, atBreak: 0.0260),
        Shot(
            name: "B7.2", series: "86", pressure: 56.7e3, impulse: 672.2, deflection: 0.0929, atBreak: 0.0235),
        Shot(
            name: "B8.2", series: "86", pressure: 50.9e3, impulse: 605.1, deflection: 0.1193, atBreak: 0.0162),
        Shot(
            name: "B5.2-137", series: "137", pressure: 54.3e3, impulse: 668.5, deflection: 0.2005,
            atBreak: 0.0245),
        Shot(
            name: "B6.2-137", series: "137", pressure: 50.0e3, impulse: 670.3, deflection: 0.1875,
            atBreak: 0.0206),
        Shot(
            name: "B7.2-137", series: "137", pressure: 54.4e3, impulse: 536.5, deflection: 0.1766,
            atBreak: 0.0291),
        Shot(
            name: "B8.2-137", series: "137", pressure: 50.2e3, impulse: 547.5, deflection: 0.1999,
            atBreak: 0.0290),
        Shot(
            name: "B9.2-137", series: "137", pressure: 53.2e3, impulse: 491.9, deflection: 0.1156,
            atBreak: 0.0309),
    ]

    /// Table 4.3's static means: the peak total load (N) and the mid-span deflection there (m).
    public static func staticMeasured(_ series: String) -> (load: Float, deflection: Float) {
        switch series {
        case "80": (105.8e3, 0.0281)
        case "86": (165.7e3, 0.0189)
        default: (141.6e3, 0.0237)
        }
    }

    public static let span: Float = 2.235
    public static let loadedArea: Float = 3.55

    public static func material(_ series: Series, rate: Float) -> StructureMaterial {
        let gl24 = TimberProperties.strengthClass(.gl24h)
        var properties = TimberProperties(
            alongGrain: series.modulus, acrossGrain: series.modulus / 30, shearModulus: series.modulus / 16,
            rollingShearModulus: series.modulus / 160)
        properties.tensionAlong = series.rupture
        properties.compressionAlong = series.compression
        properties.tensionAcross = gl24.tensionAcross
        properties.compressionAcross = gl24.compressionAcross
        properties.shearStrength = gl24.shearStrength
        properties.rollingStrength = gl24.rollingStrength
        properties.strengthFactor = rate
        return .timber(name: "Glulam \(series.name)", density: series.density, properties: properties)
    }

    public struct Result: Sendable {
        /// Peak mid-span deflection (m) and when (s); the deflection when it broke (its fibres
        /// broken through somewhere), if it did.
        public var deflection: Float
        public var time: Float
        public var atBreak: Float?
        public var curve: [SIMD2<Float>] = []
    }

    static func beam(
        device: MTLDevice, series: Series, rate: Float, history: [SIMD2<Float>], withDevice: Bool
    ) throws -> (ShellSolver, middle: [Int]) {
        // Walls get six elements through their depth; the beam a thirtieth of the span.
        let wall = series.width <= 0.5 * series.depth
        let h = wall ? series.depth / 6 : span / 30
        // Supports, third points and mid-span on nodes.
        let lengthwise = (span / (6 * h)).rounded() * 6 * h
        let overhang = (0.1325 / h).rounded() * h
        var model = StructureModel(
            solids: [
                Box(
                    min: SIMD3(-overhang, 0, 0),
                    max: SIMD3(lengthwise + overhang, series.width, series.depth))
            ], material: material(series, rate: rate), elementSize: h, fixedBase: false)
        model.elementKind = .shell
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        let positions = solver.mesh.positions
        let bottom = positions.map(\.z).min() ?? 0
        func on(_ x: Float, _ z: Float) -> [Int] {
            positions.indices.filter { abs(positions[$0].x - x) < h / 4 && abs(positions[$0].z - z) < h / 4 }
        }
        // Through the section: the device's and the supports' steel bearing plates spread the load
        // and the reactions, which on a point of a six-element-deep wall would crush the timber
        // across its grain (at 3 MPa) until the element collapsed. A line held vertically still
        // lets the end rotate.
        func line(_ x: Float) -> [Int] { positions.indices.filter { abs(positions[$0].x - x) < h / 4 } }
        let supports = line(0) + line(lengthwise)
        let lines = line(lengthwise / 3) + line(2 * lengthwise / 3)
        let middle = on(lengthwise / 2, bottom)
        let clear = series.density * series.width * series.depth * lengthwise
        let deviceMass = withDevice ? max(series.movingMass - clear, 0) : 0
        solver.mutateNodes { nodes in
            // Held sideways throughout, as the device and supports held the beams: in bending in
            // their plane, deep narrow members loaded on their top edge would otherwise buckle.
            for n in nodes.indices { nodes[n].restrain(y: true) }
            for n in supports {
                nodes[n].restrain(z: true)
                if positions[n].x < h { nodes[n].restrain(x: true) }
            }
            for n in lines { nodes[n].mass += deviceMass / Float(lines.count) }
            // A beam turns freely about its axis on its supports; mid-span, where symmetry holds
            // every rotation still anyway, holds it.
            if !wall { for n in middle { nodes[n].restrain(rotation: true) } }
        }
        var shares = [Float](repeating: 0, count: positions.count)
        for n in lines { shares[n] = 1 / Float(lines.count) }
        var load = PressureLoad(axis: 2, positiveSide: true, history: history)
        load.nodeShares = shares
        solver.appliedLoad = load
        return (solver, middle)
    }

    static func broken(_ solver: ShellSolver) -> Bool {
        guard let timber = solver.model.material.timber else { return false }
        let ft = timber.strengthFactor * timber.tensionAlong
        // The fibre index past the end of softening anywhere: on the walls' and the beams' bands.
        let wall = solver.mesh.beams.isEmpty
        let band = wall ? solver.model.elementSize : solver.mesh.beams.map(\.length).min() ?? 1
        let ratio = (timber.fibreEnergy / band) / (0.5 * ft * ft / timber.alongGrain)
        let buffer = wall ? solver.layerBuffer : solver.beamFibreBuffer
        let raw = buffer.contents()
        // Broken through: its index past the end of softening, or past one where it breaks at once.
        let end = max(ratio, 1)
        for n in 0..<(buffer.length / 40) where raw.load(fromByteOffset: n * 40, as: Float.self) > end {
            return true
        }
        return false
    }

    public static func run(
        device: MTLDevice, shot: Shot, rate: Float = 1.14, duration: Double = 0.06
    ) throws -> Result {
        guard let series = series.first(where: { $0.name == shot.series }) else {
            throw BlastError.allocationFailed("series \(shot.series)")
        }
        let fall = 2 * shot.impulse / shot.pressure
        let (solver, middle) = try beam(
            device: device, series: series, rate: rate,
            history: [SIMD2(0, shot.pressure * loadedArea), SIMD2(fall, 0), SIMD2(fall + 1, 0)],
            withDevice: true)
        var peak: Float = 0
        var when: Float = 0
        var atBreak: Float?
        let chunk = max(1, Int(0.0002 / Double(solver.criticalTimeStep)))
        while solver.time < duration {
            solver.advance(steps: chunk)
            let w = middle.map { -solver.node($0).displacement.z }.reduce(0, +) / Float(middle.count)
            if w > peak { (peak, when) = (w, Float(solver.time)) }
            if atBreak == nil, broken(solver) { atBreak = w }
        }
        return Result(deflection: peak, time: when, atBreak: atBreak)
    }

    /// The static test: the load raised over `time` to `load` (N), lightly damped, without the
    /// dynamic increase; the load and deflection when it broke.
    public static func push(device: MTLDevice, series: Series, load: Float, time: Double = 3.0) throws
        -> Result
    {
        let (solver, middle) = try beam(
            device: device, series: series, rate: 1,
            history: [SIMD2(0, 0), SIMD2(Float(time), load), SIMD2(Float(time) + 1, load)], withDevice: false)
        solver.damping = 50
        var curve: [SIMD2<Float>] = []
        var atBreak: Float?
        let chunk = max(1, Int(0.005 / Double(solver.criticalTimeStep)))
        while solver.time < time {
            solver.advance(steps: chunk)
            let w = middle.map { -solver.node($0).displacement.z }.reduce(0, +) / Float(middle.count)
            let applied = load * Float(solver.time / time)
            curve.append(SIMD2(applied, w))
            if atBreak == nil, broken(solver) { atBreak = applied }
            if w > 0.2 { break }
        }
        return Result(
            deflection: curve.last?.y ?? 0, time: Float(solver.time), atBreak: atBreak, curve: curve)
    }
}
