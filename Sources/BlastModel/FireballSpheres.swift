import Foundation
import simd

/// The spheres as the march takes them, under a spec: each shell's absorption coefficient and
/// black-body radiance.
package struct SphericalMedium: Sendable {
    struct Sphere: Sendable {
        var centre: SIMD3<Float>
        var shellSize: Float
        var radius: Float
        /// κ (1/m) and B = σT⁴/π each shell; zero where it is not luminous.
        var shells: [SIMD2<Float>]
    }

    var spheres: [Sphere]

    init(_ spheres: [FireballSphere], spec: ThermalSpec) {
        let sigma = Float(ThermalExposure.stefanBoltzmann / Double.pi)
        let soot = ThermalMedium.sootAbsorption * spec.sootYield / ThermalMedium.sootDensity
        self.spheres = spheres.map { sphere in
            let shells = sphere.temperatures.indices.map { n -> SIMD2<Float> in
                let t = sphere.temperatures[n]
                guard t > 0 else { return .zero }
                let air = spec.hotAirAbsorption ? sphere.airAbsorption[n] : 0
                let kappa = spec.absorption + soot * sphere.products[n] * t + air
                return SIMD2(kappa, sigma * t * t * t * t)
            }
            return Sphere(
                centre: sphere.centre, shellSize: sphere.shellSize, radius: sphere.radius, shells: shells)
        }
    }

    /// The radiance reaching `origin` along `direction` from the spheres, out to `limit`: each
    /// sphere's chord, nearest first, crossed shell by shell, the gas in each piece taken at the
    /// shell it lies in, until less than 10⁻⁴ of what lies beyond could get through.
    func radiance(from origin: SIMD3<Float>, along direction: SIMD3<Float>, limit: Float) -> Float {
        var chords: [(enter: Float, leave: Float, closest: Float, impact: Float, sphere: Int)] = []
        for (n, sphere) in spheres.enumerated() {
            let offset = origin - sphere.centre
            let closest = -simd_dot(offset, direction)
            let impact = max(simd_length_squared(offset) - closest * closest, 0)
            let reach = sphere.radius * sphere.radius - impact
            guard reach > 0 else { continue }
            let half = reach.squareRoot()
            let enter = max(closest - half, 0)
            let leave = min(closest + half, limit)
            if enter < leave { chords.append((enter, leave, closest, impact.squareRoot(), n)) }
        }
        chords.sort { $0.enter < $1.enter }
        var radiance: Float = 0
        var through: Float = 1
        for chord in chords {
            let sphere = spheres[chord.sphere]
            let size = sphere.shellSize
            let count = sphere.shells.count
            let impact2 = chord.impact * chord.impact
            // The ray comes in across the shells' outer boundaries from the outermost down to the
            // one it grazes, and goes out across them again: shell `k - 1` lies between the
            // crossings of boundaries `k` and `k - 1` on the way in, and of `k - 1` and `k` on
            // the way out.
            let innermost = min(Int(chord.impact / size), count - 1)
            var from = chord.enter
            var k = count
            var outward = false
            while true {
                let shellIndex: Int
                let to: Float
                if !outward {
                    shellIndex = k - 1
                    if shellIndex <= innermost {
                        outward = true
                        // The grazed shell, across its chord to its far side.
                        let r = Float(innermost + 1) * size
                        to = chord.closest + max(r * r - impact2, 0).squareRoot()
                        k = innermost + 1
                    } else {
                        let r = Float(k - 1) * size
                        to = chord.closest - max(r * r - impact2, 0).squareRoot()
                        k -= 1
                    }
                } else {
                    guard k < count else { break }
                    shellIndex = k
                    let r = Float(k + 1) * size
                    to = chord.closest + max(r * r - impact2, 0).squareRoot()
                    k += 1
                }
                let end = min(to, chord.leave)
                if end > from {
                    let shell = sphere.shells[shellIndex]
                    if shell.x > 0 {
                        let passed = exp(-shell.x * (end - from))
                        radiance += through * shell.y * (1 - passed)
                        through *= passed
                        if through < 1e-4 { return radiance }
                    }
                    from = end
                }
                if from >= chord.leave { break }
            }
        }
        return radiance
    }
}
