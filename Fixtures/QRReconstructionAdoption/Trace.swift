import Foundation
import simd

#if !ORIGINAL_QR
    import Numerics
#endif

func native(_ x: Double) -> [String: String] {
    ["value": String(x), "bits": String(x.bitPattern, radix: 16)]
}
func native(_ x: [Double]) -> [[String: String]] { x.map(native) }
func native(_ x: SIMD3<Double>) -> [[String: String]] { native([x.x, x.y, x.z]) }
func native(_ x: SIMD8<Double>) -> [[String: String]] { native((0..<8).map { x[$0] }) }
func native(_ x: [[Double]]) -> [[[String: String]]] { x.map(native) }
func native(_ x: simd_double3x3) -> [[[String: String]]] {
    native((0..<3).map { c in (0..<3).map { r in x[c][r] } })
}
func scalarSample(_ x: FiniteVolumePressureFit.Sample) -> [String: Any] {
    ["centre": native(x.centre), "covariance": native(x.covariance), "average": native(x.average)]
}
func gasSample(_ x: ConservedGasReconstruction.Sample) -> [String: Any] {
    ["centre": native(x.centre), "covariance": native(x.covariance), "density": native(x.density)]
}
func polynomialRecord(_ x: FiniteVolumePressureFit.Fit) -> [String: Any] {
    [
        "cell": scalarSample(x.cell), "scale": native(x.scale), "coefficients": native(x.coefficients),
        "aware": x.volumeAware, "lower": native(x.lower), "upper": native(x.upper),
        "degree": x.degree, "stencilSize": x.stencilSize,
    ]
}
enum ReconstructionTrace {
    nonisolated(unsafe) static var events: [[String: Any]] = []
    nonisolated(unsafe) static var nextStencil = 0
    nonisolated(unsafe) static var currentComponent = -1
    static func reset() {
        events = []
        nextStencil = 0
        currentComponent = -1
    }
    static func record(_ kind: String, _ values: [String: Any]) {
        var event = values
        event["kind"] = kind
        event["component"] = currentComponent
        events.append(event)
    }
    #if ORIGINAL_QR
        static func factor(_ q: FiniteVolumePressureFit.QR) -> [String: Any] {
            [
                "columns": native(q.vectors), "upper": native(q.upper), "permutation": q.permutation,
                "scaleExponent": 0,
            ]
        }
    #else
        static func factor(_ q: PivotedQR) -> [String: Any] {
            [
                "columns": native(q.orthogonalColumns()), "upper": native(q.scaledUpperTriangular),
                "permutation": q.permutation, "scaleExponent": q.matrixScaleExponent,
                "condition": native(q.reciprocalConditionEstimate),
                "tolerance": native(q.relativeRankTolerance),
            ]
        }
    #endif
    static func stencil(
        cell: FiniteVolumePressureFit.Sample, neighbours: [FiniteVolumePressureFit.Sample],
        scale: Double, aware: Bool, rows: [[Double]], weights: [Double],
        quadratic: [String: Any]?, linear: [String: Any]?
    ) -> Int {
        let id = nextStencil
        nextStencil += 1
        record(
            "stencil",
            [
                "stencil": id, "cell": scalarSample(cell), "neighbours": neighbours.map(scalarSample),
                "scale": native(scale), "aware": aware, "rows": native(rows), "weights": native(weights),
                "quadratic": quadratic as Any? ?? NSNull(), "linear": linear as Any? ?? NSNull(),
            ])
        return id
    }
    static func solve(
        stencil: Int, average: Double, neighbours: [Double], rhs: [Double], quadratic: Bool,
        coefficients: [Double]
    ) {
        record(
            "solve",
            [
                "stencil": stencil, "average": native(average), "neighbours": native(neighbours),
                "rhs": native(rhs), "quadratic": quadratic, "coefficients": native(coefficients),
            ])
    }
    static func limit(
        point: SIMD3<Double>, mean: Double, lower: Double, upper: Double,
        delta: Double, before: Double, after: Double
    ) {
        record(
            "limit",
            [
                "point": native(point), "mean": native(mean), "lower": native(lower),
                "upper": native(upper), "delta": native(delta), "before": native(before),
                "after": native(after),
            ])
    }
    static func limited(_ factor: Double) { record("limited", ["rawFactor": native(factor)]) }
    static func frame(velocity: SIMD3<Double>, densities: [SIMD8<Double>], mean: SIMD8<Double>) {
        record(
            "frame", ["velocity": native(velocity), "densities": densities.map(native), "mean": native(mean)])
    }
    static func beginComponent(_ c: Int) {
        currentComponent = c
        record("begin-component", [:])
    }
    static func component(
        polynomial: FiniteVolumePressureFit.Fit, originalScale: Double, lower: Double,
        upper: Double, bound: Bool, globalFactor: Double, fallback: Bool
    ) {
        record(
            "component",
            [
                "polynomial": polynomialRecord(polynomial), "originalScale": native(originalScale),
                "lower": native(lower), "upper": native(upper), "bound": bound,
                "globalFactor": native(globalFactor), "fallback": fallback,
            ])
    }
    static func deltas(_ values: [SIMD8<Double>]) { record("deltas", ["values": values.map(native)]) }
    static func floors(_ density: Double, _ energy: Double) {
        record("floors", ["density": native(density), "energy": native(energy)])
    }
    static func probe(_ theta: Double) { record("probe", ["theta": native(theta)]) }
    static func answer(_ value: Bool) -> Bool {
        record("answer", ["value": value])
        return value
    }
    static func backoff(beforeLow: Double, beforeHigh: Double, mid: Double, low: Double, high: Double) {
        record(
            "backoff",
            [
                "beforeLow": native(beforeLow), "beforeHigh": native(beforeHigh),
                "mid": native(mid), "low": native(low), "high": native(high),
            ])
    }
    static func selected(factor: Double, reduced: Bool, fallback: Bool) {
        record("selected", ["factor": native(factor), "reduced": reduced, "fallback": fallback])
    }
    static func outputs(_ fit: ConservedGasReconstruction.Fit, controls: [SIMD3<Double>]) {
        record(
            "outputs",
            [
                "states": controls.map { point in
                    let state = fit.state(at: point)
                    return [
                        "point": native(point), "amount": native(state.amount),
                        "volume": native(state.volume),
                        "velocity": native(state.velocity), "pressure": native(state.pressure()),
                    ] as [String: Any]
                }
            ])
    }
    static func admissibleInput(_ u: SIMD8<Double>, density: Double, internalEnergy: Double) {
        record(
            "admissible-input",
            ["density": native(u), "densityFloor": native(density), "internalFloor": native(internalEnergy)])
    }
    static func admissibleResult(_ value: Bool, energy: Double?) -> Bool {
        record("admissible-result", ["value": value, "energy": energy.map(native) as Any? ?? NSNull()])
        return value
    }
}
