import Foundation
import Metal
import simd

/// Cross-laminated timber panels in the University of Ottawa's shock tube: M. M. Poulin, MASc
/// thesis, University of Ottawa, 2019 (open), and Poulin, Viau, Lacroix and Doudak, J. Struct.
/// Eng. 144(2), 2018.
///
/// Eighteen Nordic panels, grade E1 of ANSI/APA PRG 320 (35 mm lamellae, 1950f-1.7E machine
/// stress-rated spruce-pine-fir along the panel), 3-ply (105 mm) and 5-ply (175 mm), 445 mm wide,
/// simply supported over 2,235 mm. A hinged steel load-transfer device collected the shock tube's
/// pressure over an equivalent 3.55 m^2 and pressed it onto the panel as two line loads at the
/// third points, as in the static four-point bending tests; with the device, the moving mass was
/// 342.1 kg (3-ply) and 384.5 kg (5-ply). The thesis tabulates every shot's reflected pressure and
/// impulse, the peak mid-span deflection and the failure mode (its Table 4.3), and the static
/// tests' resistance and stiffness (Table 4.1).
///
/// The model: the panel as layered timber shells, one lamella crossed in two (or two in three),
/// on lines held still through the thickness at the supports; the device's force, P(t) x 3.55
/// m^2, shared between strips one element wide under the load lines; and its mass, what the
/// moving mass leaves after the panel's clear span, split between the load lines' nodes. Each
/// shot's pressure is a triangle of its measured peak and impulse (the thesis plots, but does
/// not tabulate, the histories; the positive phase was 5 to 70 ms).
public enum PoulinCLTTest {
    public struct Shot: Sendable {
        public var name: String
        public var plies: Int
        /// Reflected peak (Pa) and impulse (Pa s).
        public var pressure: Float
        public var impulse: Float
        /// Measured peak mid-span deflection (m) and failure mode.
        public var deflection: Float
        public var mode: String
    }

    /// Poulin's Table 4.3.
    public static let shots: [Shot] = [
        Shot(name: "CLT3-4.1", plies: 3, pressure: 11.6e3, impulse: 90, deflection: 0.0161, mode: "elastic"),
        Shot(
            name: "CLT3-4.2", plies: 3, pressure: 38.7e3, impulse: 379, deflection: 0.1052,
            mode: "rolling shear"),
        Shot(name: "CLT3-5.1", plies: 3, pressure: 48.2e3, impulse: 442, deflection: 0.0886, mode: "flexure"),
        Shot(name: "CLT3-6.1", plies: 3, pressure: 52.6e3, impulse: 614, deflection: 0.1437, mode: "flexure"),
        Shot(name: "CLT3-7.1", plies: 3, pressure: 6.5e3, impulse: 79, deflection: 0.0118, mode: "elastic"),
        Shot(
            name: "CLT3-7.2", plies: 3, pressure: 52.8e3, impulse: 440, deflection: 0.1192,
            mode: "rolling shear"),
        Shot(name: "CLT3-8.1", plies: 3, pressure: 5.8e3, impulse: 59, deflection: 0.0101, mode: "elastic"),
        Shot(
            name: "CLT3-8.2", plies: 3, pressure: 49.0e3, impulse: 468, deflection: 0.0895,
            mode: "rolling shear, then flexure"),
        Shot(name: "CLT3-9.1", plies: 3, pressure: 12.2e3, impulse: 131, deflection: 0.0187, mode: "elastic"),
        Shot(
            name: "CLT3-9.2", plies: 3, pressure: 30.9e3, impulse: 322, deflection: 0.0584,
            mode: "rolling shear"),
        Shot(name: "CLT3-10.1", plies: 3, pressure: 9.1e3, impulse: 93, deflection: 0.0123, mode: "elastic"),
        Shot(
            name: "CLT3-10.2", plies: 3, pressure: 34.0e3, impulse: 374, deflection: 0.0994, mode: "flexure"),
        Shot(name: "CLT3-11.1", plies: 3, pressure: 9.2e3, impulse: 107, deflection: 0.0117, mode: "elastic"),
        Shot(
            name: "CLT3-11.2", plies: 3, pressure: 32.9e3, impulse: 345, deflection: 0.0725, mode: "flexure"),
        Shot(name: "CLT5-4.1", plies: 5, pressure: 53.7e3, impulse: 610, deflection: 0.0807, mode: "flexure"),
        Shot(
            name: "CLT5-5.1", plies: 5, pressure: 58.6e3, impulse: 691, deflection: 0.0582,
            mode: "rolling shear"),
        Shot(name: "CLT5-6.1", plies: 5, pressure: 7.2e3, impulse: 82, deflection: 0.0065, mode: "elastic"),
        Shot(name: "CLT5-6.2", plies: 5, pressure: 55.8e3, impulse: 602, deflection: 0.0779, mode: "flexure"),
        Shot(name: "CLT5-7.1", plies: 5, pressure: 7.3e3, impulse: 82, deflection: 0.0064, mode: "elastic"),
        Shot(name: "CLT5-7.2", plies: 5, pressure: 51.2e3, impulse: 481, deflection: 0.0370, mode: "flexure"),
    ]

    /// Poulin's Table 4.1: the static tests' peak total load (N), the mid-span deflection there
    /// (m) and the stiffness (N/m), for 3 and 5 plies.
    public static func staticMeasured(plies: Int) -> (load: Float, deflection: Float, stiffness: Float) {
        plies == 3 ? (68.4e3, 0.0347, 2.1e6) : (128.6e3, 0.0236, 5.9e6)
    }

    public static let span: Float = 2.235
    public static let width: Float = 0.445
    public static let loadedArea: Float = 3.55
    public static func movingMass(plies: Int) -> Float { plies == 3 ? 342.1 : 384.5 }

    /// Grade E1's lamellae (PRG 320-2019, Tables A1 and A3: E 11,700 MPa along the panel; the
    /// Canadian specified strengths along it, f_t 15.4, f_c 19.3 and rolling shear 0.50 MPa), the
    /// other moduli by its Annex X3 (E90 = E/30, G = E/16, G_R = G/10), raised to their means with
    /// the JCSS model's coefficients of variation as `TimberProperties.strengthClass` does; across
    /// the grain and in shear along it, C24's. `rate` is the strengths' dynamic increase factor.
    public static func material(plies: Int, rate: Float, rollingScale: Float = 1) -> StructureMaterial {
        let e: Float = 11.7e9
        var properties = TimberProperties(
            alongGrain: e, acrossGrain: e / 30, shearModulus: e / 16,
            rollingShearModulus: rollingScale * e / 160,
            lamellae: TimberProperties.crossLaminated(plies))
        let c24 = TimberProperties.strengthClass(.c24)
        properties.tensionAlong = 15.4e6 * TimberProperties.lognormalMean(cov: 0.3)
        properties.compressionAlong = 19.3e6 * TimberProperties.lognormalMean(cov: 0.2)
        properties.rollingStrength = 0.50e6 * TimberProperties.lognormalMean(cov: 0.25)
        properties.tensionAcross = c24.tensionAcross
        properties.compressionAcross = c24.compressionAcross
        properties.shearStrength = c24.shearStrength
        properties.strengthFactor = rate
        return .timber(name: "E1 CLT \(plies)-ply", density: 450, properties: properties)
    }

    public struct Result: Sendable {
        /// Peak mid-span deflection (m), and when (s).
        public var deflection: Float
        public var time: Float
        /// The largest damage each mode reached anywhere: fibre, splitting and rolling shear.
        public var fibre: Float
        public var splitting: Float
        public var rolling: Float
        public var removed: Int
        /// For a static push: the total load (N) against mid-span deflection (m).
        public var curve: [SIMD2<Float>] = []
    }

    /// The panel on its supports, with the device's mass on its load lines and its force, of
    /// `history` (total newtons against time), shared between strips under them.
    static func panel(
        device: MTLDevice, plies: Int, elementSize: Float, rate: Float, history: [SIMD2<Float>],
        rollingScale: Float = 1
    ) throws -> (ShellSolver, middle: [Int]) {
        let h = elementSize
        let thickness = 0.035 * Float(plies)
        let overhang = 2 * h
        let lengthwise = (span / h).rounded() * h
        let across = (width / h).rounded() * h
        var model = StructureModel(
            solids: [Box(min: SIMD3(-overhang, 0, 0), max: SIMD3(lengthwise + overhang, across, thickness))],
            material: material(plies: plies, rate: rate, rollingScale: rollingScale), elementSize: h,
            fixedBase: false)
        model.elementKind = .shell
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        let supports = solver.nodes { abs($0.x) < h / 4 || abs($0.x - lengthwise) < h / 4 }
        let lines: [Float] = [lengthwise / 3, 2 * lengthwise / 3]
        let loaded = solver.nodes { p in lines.contains { abs(p.x - $0) < h / 4 } }
        let middle = solver.nodes { abs($0.x - lengthwise / 2) < h / 4 }
        // The panel's clear span and the device take the moving mass.
        let clear = 450 * thickness * across * lengthwise
        let device = max(movingMass(plies: plies) - clear, 0)
        solver.mutateNodes { nodes in
            for n in supports {
                nodes[n].restrain(z: true)
                if solver.position(n).x < h { nodes[n].restrain(x: true) }
            }
            for n in loaded { nodes[n].mass += device / Float(loaded.count) }
        }
        // Strips one element wide, centred on the load lines, take the force.
        var shares: [Float] = []
        for element in solver.mesh.elements {
            let x = (0..<4).map { solver.mesh.positions[Int(element.nodes[$0])].x }
            let (low, high) = (x.min()!, x.max()!)
            let overlap = lines.map { max(0, min(high, $0 + h / 2) - max(low, $0 - h / 2)) }.reduce(0, +)
            shares.append(overlap / h)
        }
        let strip = Float(lines.count) * h * across
        solver.appliedLoad = PressureLoad(
            axis: 2, positiveSide: true, history: history.map { SIMD2($0.x, $0.y / strip) })
        solver.appliedLoad?.elementShares = shares
        return (solver, middle)
    }

    /// The largest damage in each mode, from the timber layers' states: fibre and rolling shear
    /// from their largest indices, as the kernel's `timberDamage`, splitting as stored.
    static func damage(_ solver: ShellSolver, plies: Int, rate: Float) -> (
        fibre: Float, splitting: Float, rolling: Float
    ) {
        guard let timber = material(plies: plies, rate: rate).timber else { return (0, 0, 0) }
        func damage(_ r: Float, _ ratio: Float) -> Float {
            r <= 1 ? 0 : ratio <= 1 ? 1 : min(1, ratio / (ratio - 1) * (1 - 1 / r))
        }
        let h = solver.model.elementSize
        let ft = rate * timber.tensionAlong
        let fr = rate * timber.rollingStrength
        let fibreRatio = (timber.fibreEnergy / h) / (0.5 * ft * ft / timber.alongGrain)
        let rollingRatio = (timber.rollingEnergy / 0.035) / (0.5 * fr * fr / timber.rollingShearModulus)
        let count = solver.layerBuffer.length / 40
        let raw = solver.layerBuffer.contents()
        var fibre: Float = 0
        var splitting: Float = 0
        var rolling: Float = 0
        for n in 0..<count {
            // Stored: crack (the fibre and splitting indices), crush, the rate and its factor as
            // halves, residual (the rolling index and the splitting damage).
            let base = raw + n * 40
            fibre = max(fibre, damage(base.load(as: Float.self), fibreRatio))
            rolling = max(rolling, damage(base.load(fromByteOffset: 20, as: Float.self), rollingRatio))
            splitting = max(splitting, base.load(fromByteOffset: 24, as: Float.self))
        }
        return (fibre, splitting, rolling)
    }

    /// One shot: the triangle of its peak and impulse, run for `duration`.
    public static func run(
        device: MTLDevice, shot: Shot, elementSize: Float = 0.0745, rate: Float = 1.28,
        duration: Double = 0.08
    ) throws -> Result {
        let fall = 2 * shot.impulse / shot.pressure
        let force = shot.pressure * loadedArea
        let (solver, middle) = try panel(
            device: device, plies: shot.plies, elementSize: elementSize, rate: rate,
            history: [SIMD2(0, force), SIMD2(fall, 0), SIMD2(fall + 1, 0)])
        var peak: Float = 0
        var when: Float = 0
        let chunk = max(1, Int(0.0002 / Double(solver.criticalTimeStep)))
        while solver.time < duration {
            solver.advance(steps: chunk)
            let w = middle.map { -solver.node($0).displacement.z }.reduce(0, +) / Float(middle.count)
            if w > peak { (peak, when) = (w, Float(solver.time)) }
        }
        let modes = damage(solver, plies: shot.plies, rate: rate)
        return Result(
            deflection: peak, time: when, fibre: modes.fibre, splitting: modes.splitting,
            rolling: modes.rolling,
            removed: solver.summary().erodedElements)
    }

    /// The static test: the load raised steadily over `time` to `load` (N), damped, without the
    /// dynamic increase; the curve of load against mid-span deflection.
    public static func push(
        device: MTLDevice, plies: Int, load: Float, elementSize: Float = 0.0745,
        time: Double = 1.0, rollingScale: Float = 1
    ) throws -> Result {
        let (solver, middle) = try panel(
            device: device, plies: plies, elementSize: elementSize, rate: 1,
            history: [SIMD2(0, 0), SIMD2(Float(time), load), SIMD2(Float(time) + 1, load)],
            rollingScale: rollingScale)
        solver.damping = 200
        var curve: [SIMD2<Float>] = []
        let chunk = max(1, Int(0.002 / Double(solver.criticalTimeStep)))
        while solver.time < time {
            solver.advance(steps: chunk)
            let w = middle.map { -solver.node($0).displacement.z }.reduce(0, +) / Float(middle.count)
            curve.append(SIMD2(load * Float(solver.time / time), w))
            if w > 0.3 { break }
        }
        let modes = damage(solver, plies: plies, rate: 1)
        return Result(
            deflection: curve.last?.y ?? 0, time: Float(solver.time), fibre: modes.fibre,
            splitting: modes.splitting,
            rolling: modes.rolling, removed: solver.summary().erodedElements, curve: curve)
    }
}
