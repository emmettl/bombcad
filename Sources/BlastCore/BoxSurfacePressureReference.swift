import Foundation
import simd

/// Whole uncut rectangular faces, independent of grid clipping, gas averaging, grouping
/// and numerical traces. Positive tensor Gauss rules integrate a supplied pressure field.
enum BoxSurfacePressureReference {
    enum Failure: Error { case invalidOrder, invalidPressure, nonconverged }
    struct Load {
        let force: SIMD3<Double>
        let torque: SIMD3<Double>
    }
    static func rule(order: Int) throws -> [(point: Double, weight: Double)] {
        guard order >= 2 && order <= 64 else { throw Failure.invalidOrder }
        var nodes = [(point: Double, weight: Double)](repeating: (0, 0), count: order)
        func polynomial(_ z: Double) -> (value: Double, derivative: Double) {
            var previous = 1.0
            var current = z
            for n in 2...order {
                let next = ((2 * Double(n) - 1) * z * current - (Double(n) - 1) * previous) / Double(n)
                previous = current
                current = next
            }
            return (current, Double(order) * (z * current - previous) / (z * z - 1))
        }
        for i in 0..<((order + 1) / 2) {
            var z = cos(.pi * (Double(i) + 0.75) / (Double(order) + 0.5))
            var converged = false
            for _ in 0..<64 {
                let p = polynomial(z)
                let next = z - p.value / p.derivative
                if abs(next - z) < 1e-15 {
                    z = next
                    converged = true
                    break
                }
                z = next
            }
            guard converged else { throw Failure.nonconverged }
            let derivative = polynomial(z).derivative
            let weight = 2 / ((1 - z * z) * derivative * derivative)
            nodes[i] = (-z, weight)
            nodes[order - 1 - i] = (z, weight)
        }
        return nodes
    }
    static func integrate(
        body: RigidBoxBody, order: Int,
        pressure: (SIMD3<Double>) throws -> Double
    ) throws -> Load {
        let nodes = try rule(order: order)
        var force = SIMD3<Double>.zero
        var torque = SIMD3<Double>.zero
        for axis in 0..<3 {
            let a = (axis + 1) % 3
            let b = (axis + 2) % 3
            for sign in [-1.0, 1.0] {
                var unit = SIMD3<Double>.zero
                unit[axis] = sign
                let normal = body.orientation.act(unit)
                for u in nodes {
                    for v in nodes {
                        var local = SIMD3<Double>.zero
                        local[axis] = sign * body.size[axis] / 2
                        local[a] = u.point * body.size[a] / 2
                        local[b] = v.point * body.size[b] / 2
                        let point = body.worldPoint(local)
                        let p = try pressure(point)
                        guard p.isFinite && p >= 0 else { throw Failure.invalidPressure }
                        let area = body.size[a] * body.size[b] / 4 * u.weight * v.weight
                        let applied = -area * p * normal
                        force += applied
                        torque += simd_cross(point - body.position, applied)
                    }
                }
            }
        }
        return .init(force: force, torque: torque)
    }
}
