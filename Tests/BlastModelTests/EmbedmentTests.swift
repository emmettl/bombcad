import Foundation
import Testing
import simd

@testable import BlastModel

/// Footings set into the soil (`Embedment`, `FootingSides`) against the standard embedment
/// factors: Gazetas's for static stiffness, Brinch Hansen's for bearing, Rankine's passive and
/// active pressures for sliding.
@Suite("Embedded footings")
struct EmbedmentTests {
    let material = StructureMaterial.elastic(density: 2400, youngsModulus: 30e9, poissonRatio: 0.2)

    /// The embedded footing's bed and sides, and Gazetas's surface stiffness for it.
    private func parts(width: Float, length: Float, thickness: Float, soil: Soil, embedment: Embedment) -> (
        bed: FootingBed, sides: FootingSides, surface: [Float]
    ) {
        let bed = FootingBed(
            width: width, length: length, soil: soil, embedment: embedment, thickness: thickness)
        let sides = FootingSides(
            width: width, length: length, thickness: thickness, soil: soil, embedment: embedment,
            base: bed.stiffness)
        let surface = FootingBed(width: width, length: length, soil: soil).stiffness
        return (bed, sides, surface)
    }

    @Test("Base and sides give Gazetas's embedded stiffness vertically and horizontally; rocking follows")
    func stiffness() {
        let soil = Soil(cyclic: nil)
        for (width, length, thickness, depth) in [
            (Float(2), Float(2), Float(1), Float(1)), (2, 2, 0.5, 1), (1.5, 4, 0.8, 0.8),
        ] {
            let embedment = Embedment(depth: depth)
            let (bed, sides, surface) = parts(
                width: width, length: length, thickness: thickness, soil: soil, embedment: embedment)
            let total = zip(bed.stiffness, sides.stiffness).map { $0 + $1 }
            for mode in 0..<3 {
                #expect(
                    abs(total[mode] / sides.target[mode] - 1) < 0.01,
                    "\(mode): \(total[mode]) against \(sides.target[mode])")
                #expect(total[mode] > surface[mode])
            }
            // Rocking: the sides' springs give a fifth to two fifths of what Gazetas says
            // embedment adds, and a spring on the footing the rest.
            for mode in 3..<5 {
                let gain = (total[mode] - surface[mode]) / (sides.target[mode] - surface[mode])
                #expect(gain > 0.15 && gain < 0.45, "\(mode): \(gain)")
                let remainder = mode == 3 ? sides.rocking.x : sides.rocking.y
                #expect(abs((total[mode] + remainder) / sides.target[mode] - 1) < 1e-4)
            }
        }
        // Gazetas's factors for a square 2 m footing 1 m deep, its sides in contact all the way:
        // vertically [1 + (D / 21 B)(1 + 1.3 χ)] [1 + 0.2 (A_w / A_b)^(2/3)] = 1.105 × 1.317.
        let factors = Embedment(depth: 1).gazetasFactors(width: 2, length: 2, thickness: 1)
        #expect(abs(factors.trench[0] - (1 + 1.0 / 21 * 2.3)) < 1e-4)
        #expect(abs(factors.sidewall[0] - (1 + 0.2 * pow(Float(2), 2.0 / 3))) < 1e-4)
    }

    @Test("Hansen's bearing capacity: the overburden's γ D N_q s_q d_q on the surface footing's")
    func bearingFactors() {
        // φ = 35°: N_q = 33.3 (tables give 33.30); s_q = 1 + tan φ for a square; d_q at D / B = 0.5,
        // 1 + 2 tan φ (1 − sin φ)² 0.5 = 1.127.
        let embedment = Embedment(depth: 1)
        let material = SoilMaterial.mediumDenseSand
        let q = embedment.bearingCapacity(surface: 600e3, width: 2, length: 2, material: material)
        let phi: Float = 35 * .pi / 180
        let expected = 600e3 + 1900 * 9.81 * 1 * 33.30 * (1 + tan(phi)) * 1.127
        #expect(abs(q / expected - 1) < 0.005, "\(q) against \(expected)")
        #expect(abs(embedment.passive - 3.690) < 0.001 && abs(embedment.active - 0.271) < 0.001)
        #expect(abs(embedment.atRest - 0.426) < 0.001)
    }
}
