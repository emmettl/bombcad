import Foundation
import Metal
import simd

/// A freestanding reinforced concrete wall under a blast, standing on each kind of base
/// connection in turn, to show how much the support assumption changes the response.
///
/// The wall is the deformable-wall preset's, 3 m high and 250 mm thick with a mat of 565 mm²/m
/// near each face, as a strip 1 m long. The blast is applied without the air: a triangular pulse
/// of the Kingery–Bulmash reflected pressure and impulse for a hemispherical surface burst at
/// the wall's distance, uniform over its face and with no clearing. This is a comparison of
/// support assumptions, not a validation: no measured wall is reproduced. Its starter bars
/// (`BaseConnection.dowelled`) are the vertical bars of both mats.
public enum AnchorageStudy {
    public static let height: Float = 3
    public static let thickness: Float = 0.25
    public static let length: Float = 1
    public static let barArea: Float = 565e-6

    public struct Result: Sendable {
        public var base: BaseConnection
        /// Reflected pressure (Pa) and duration (s) of the pulse.
        public var pressure: Float
        public var duration: Float
        /// The top's sway away from the charge: its largest, and where it is at the end.
        public var peakSway: Float
        public var finalSway: Float
        /// The base's largest opening and slip, the fraction of its nodes whose tie failed and its
        /// mean damage (zero when clamped).
        public var peakUplift: Float = 0
        public var maxSlip: Float = 0
        public var separated: Float = 0
        public var meanDamage: Float = 0
        /// The largest moment the base carried, per metre of wall, in N m/m.
        public var peakBaseMoment: Float = 0
        public var summary: StructureSummary
        public var wallSeconds: Double
    }

    /// The calls the study makes of a body, whether of solid elements or of shells.
    private struct Body {
        var step: Double
        var time: () -> Double
        var advance: (Int) -> Void
        var setDamping: (Float) -> Void
        var setLoad: (PressureLoad) -> Void
        /// The top's displacement away from the charge, at mid-length.
        var sway: () -> Float
        var anchors: () -> StructureSolver.AnchorSummary?
        var summary: () -> StructureSummary
    }

    private static func body(_ solver: StructureSolver) -> Body {
        let top = solver.nodeIndex(0, solver.ey / 2, solver.ez)
        return Body(
            step: Double(solver.criticalTimeStep), time: { solver.time }, advance: solver.advance(steps:),
            setDamping: { solver.damping = $0 }, setLoad: { solver.appliedLoad = $0 },
            sway: {
                var value: Float = 0
                solver.mutateNodes { value = $0[top].ux }
                return value
            }, anchors: solver.anchorSummary, summary: solver.summary)
    }

    private static func body(_ solver: ShellSolver) -> Body {
        let top = solver.nearestNode(to: SIMD3(thickness / 2, length / 2, height))
        return Body(
            step: Double(solver.criticalTimeStep), time: { solver.time }, advance: solver.advance(steps:),
            setDamping: { solver.damping = $0 }, setLoad: { solver.appliedLoad = $0 },
            sway: { solver.node(top).ux }, anchors: solver.anchorSummary, summary: solver.summary)
    }

    /// Runs the wall on `base` for `duration` seconds after a charge of `mass` kg of TNT bursts
    /// on the ground `standoff` metres in front of it, meshed with solid elements of
    /// `elementSize`, or with shells of that size if `shells`.
    public static func run(
        device: MTLDevice, base: BaseConnection, mass: Float = 50, standoff: Float = 6, duration: Float = 0.5,
        elementSize: Float = 0.0625, shells: Bool = false
    ) throws -> Result {
        let started = ContinuousClock.now
        let wall = Box(min: .zero, max: SIMD3(thickness, length, height))
        var model = StructureModel(solids: [wall], elementSize: elementSize, fixedBase: true)
        model.addMat(to: wall, thicknessAxis: 0, areaPerMetre: barArea, depth: 0.04)
        model.baseAnchorage = base.anchorage
        let solver: Body
        if shells {
            model.elementKind = .shell
            solver = body(try ShellSolver(device: device, model: model))
        } else {
            solver = body(try StructureSolver(device: device, model: model))
        }

        // Settle under gravity first, with damping that is then removed.
        let dt = solver.step
        solver.setDamping(500)
        solver.advance(Int((0.03 / dt).rounded()))
        solver.setDamping(0)

        let scaled = Double(standoff) / cbrt(Double(mass))
        guard let point = KingeryBulmash.point(at: scaled) else {
            throw BlastError.outsideBlastCurves(scaled)
        }
        let pressure = Float(point.reflectedPressure)
        let pulse = Float(2 * point.reflectedImpulse(mass: Double(mass)) / point.reflectedPressure)
        let start = Float(solver.time())
        solver.setLoad(
            PressureLoad(
                axis: 0, positiveSide: false,
                history: [
                    SIMD2(0, 0), SIMD2(start, pressure), SIMD2(start + pulse, 0), SIMD2(start + 100, 0),
                ]))

        var result = Result(
            base: base, pressure: pressure, duration: pulse, peakSway: 0, finalSway: 0,
            summary: StructureSummary(), wallSeconds: 0)
        let sample = 2e-4
        let stepsPerSample = max(1, Int((sample / dt).rounded()))
        for _ in 0..<Int((Double(duration) / sample).rounded()) {
            solver.advance(stepsPerSample)
            result.peakSway = max(result.peakSway, solver.sway())
            if let anchors = solver.anchors() {
                result.peakUplift = max(result.peakUplift, anchors.maxOpening)
                result.peakBaseMoment = max(result.peakBaseMoment, abs(anchors.moment.y) / length)
            }
        }
        result.finalSway = solver.sway()
        if let anchors = solver.anchors() {
            result.maxSlip = anchors.maxSlip
            result.separated = Float(anchors.separated) / Float(max(anchors.nodes, 1))
            result.meanDamage = anchors.meanDamage
        }
        result.summary = solver.summary()
        let elapsed = ContinuousClock.now - started
        result.wallSeconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        return result
    }
}
