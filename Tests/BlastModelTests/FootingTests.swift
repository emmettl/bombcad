import Foundation
import Testing
import simd

@testable import BlastModel

/// Rigid footings on soil (`Footing`, `FootingBed`, `FootingImpedance`) against theory: the
/// half-space's static stiffness, a footing's heel lifting and its toe bearing, the cones'
/// dynamic stiffness, and a layer's.
@Suite("Footings")
struct FootingTests {
    let g: Float = 9.81

    // MARK: - The bed

    @Test("Gazetas's stiffnesses match the rigid disk's for a square, and the bed gives them")
    func bedStiffness() {
        let soil = Soil()
        let g = soil.material.shearModulus
        let nu = soil.material.poissonRatio
        // A unit square and the disk of its area (translation) or second moment (rocking).
        let square = FootingImpedance.gazetas(width: 1, length: 1, material: soil.material)
        let r = (1 / Float.pi).squareRoot()
        let rr = (1 / (3 * Float.pi)).squareRoot().squareRoot()
        #expect(abs(square[0] / (4 * g * r / (1 - nu)) - 1) < 0.02)
        #expect(abs(square[1] / (8 * g * r / (2 - nu)) - 1) < 0.02)
        #expect(abs(square[3] / (8 * g * rr * rr * rr / (3 * (1 - nu))) - 1) < 0.1)
        // The bed turns about both axes as stiffly as the half-space; under a square footing it
        // is as stiff vertically too, and under a long one stiffer, as its edges can only carry
        // so much.
        for (width, length) in [(Float(1.5), Float(1.5)), (1.25, 2.5), (1.25, 12)] {
            let bed = FootingBed(width: width, length: length, soil: soil)
            let target = FootingImpedance.gazetas(width: width, length: length, material: soil.material)
            for mode in [3, 4] {
                #expect(
                    abs(bed.stiffness[mode] / target[mode] - 1) < 0.01,
                    "rocking \(mode), \(width) x \(length): \(bed.stiffness[mode] / target[mode])")
            }
            let vertical = bed.stiffness[0] / target[0]
            #expect(vertical > 0.99 && vertical < (width == length ? 1.01 : 1.7), "vertical \(vertical)")
            #expect(bed.points.allSatisfy { $0.vertical > 0 })
            let area = bed.points.reduce(0) { $0 + $1.area }
            #expect(abs(area - width * length) < 1e-3)
            #expect(abs(bed.stiffness[1] / target[1] - 1) < 1e-3)
        }
    }

    @Test(
        "Over any layer the soil never gives a footing energy: its impedance's imaginary part stays positive")
    func layerPassivity() {
        let beneath: [SoilMaterial?] = [
            nil, .softRock, SoilMaterial(shearModulus: 10e6, poissonRatio: 0.3, density: 1800),
        ]
        for depth: Float in [0.3, 1, 3, 10] {
            for below in beneath {
                let soil = Soil(layerDepth: depth, beneath: below)
                let impedance = FootingBed(width: 1.5, length: 1.5, soil: soil).impedance
                for mode in FootingImpedance.Mode.allCases {
                    let period = 2 * Double(depth) / Double(impedance.waveSpeed[mode.rawValue])
                    let lowest = (1...4000).map { k -> Double in
                        let omega = Double(k) * 20 * .pi / period / 4000
                        return impedance.dynamicStiffness(mode, omega: omega).imaginary
                            / (omega * Double(impedance.dashpot[mode.rawValue]))
                    }.min()!
                    #expect(
                        lowest > -1e-4, "\(mode) over \(depth) m on \(String(describing: below)): \(lowest)")
                }
            }
        }
    }
}
