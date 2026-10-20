import Foundation
import RadialBlast
import Testing
import simd

@testable import BlastModel

@Suite("The fireball as a partly transparent volume")
struct FireballVolumeTests {
    private let sigma = Float(ThermalExposure.stefanBoltzmann)

    private func spec(absorption: Float, samples: Int = 2048) -> ThermalSpec {
        var spec = ThermalSpec()
        spec.fireball = .volume
        spec.absorption = absorption
        spec.sootYield = 0
        spec.samples = samples
        spec.groundSpacing = 20
        spec.surfaceSpacing = 20
        return spec
    }

    @Test("The products' soot absorbs as Rayleigh particles do, 1817 f T a metre")
    func soot() {
        var spec = spec(absorption: 0.1)
        spec.sootYield = 0.2
        let cells = LuminousCells(
            voxelSize: 1, first: .zero, counts: SIMD3(2, 1, 1), fills: [255, 128],
            temperatures: [2000, 1500],
            products: [0.05, 0.1])
        let medium = ThermalMedium(cells, spec: spec)
        let f = 0.2 * 0.05 / 1800 as Float
        #expect(abs(medium.voxels[0].y / (0.1 + 1817 * f * 2000) - 1) < 1e-3)
        #expect(
            abs(medium.voxels[1].y / (128 / 255 * (0.1 + 1817 * 0.2 * Float(Float16(0.1)) / 1800 * 1500)) - 1)
                < 1e-3)
        #expect(abs(medium.voxels[0].z / medium.voxels[0].y / (sigma * pow(2000, 4) / .pi) - 1) < 1e-5)
        // At the first voxel's centre, the gas is its own.
        let gas = medium.gas(at: SIMD3(0.5, 0.5, 0.5))
        #expect(abs(gas.absorption / medium.voxels[0].y - 1) < 1e-5 && gas.radiance > 0)
    }

    @Test("Hot air absorbs as Kivel and Bailey predict it emits, and the volume adds it where asked")
    func hotAir() {
        // NASA TN D-1031's correlation at 6,000 K: E/2 = 123.1 W/cm³ at the normal density, rising
        // as its power 1.337; κ = E / 4σT⁴.
        let sigma = 5.670374e-8
        let atNormal = 2e6 * 123.1 / (4 * sigma * pow(6000, 4))
        #expect(abs(Double(HotAir.planckAbsorption(temperature: 6000, density: 1.293)) / atNormal - 1) < 1e-4)
        #expect(
            abs(
                Double(HotAir.planckAbsorption(temperature: 6000, density: 8 * 1.293))
                    / (atNormal * pow(8, 1.337))
                    - 1) < 1e-4)
        // A shock's layer at 8,000 K and eight times the density is opaque within centimetres; the
        // fireball's gas at 2,500 K and a tenth of it all but transparent.
        #expect(HotAir.planckAbsorption(temperature: 8000, density: 8 * 1.293) > 40)
        #expect(HotAir.planckAbsorption(temperature: 2500, density: 0.13) < 1e-3)
        // Between the correlation's temperatures, monotonic.
        let rising = stride(from: Float(1000), through: 18000, by: 250).map {
            HotAir.planckAbsorption(temperature: $0, density: 1.293)
        }
        #expect(zip(rising, rising.dropFirst()).allSatisfy { $0 < $1 })
        let cells = LuminousCells(
            voxelSize: 1, first: .zero, counts: SIMD3(1, 1, 1), fills: [255], temperatures: [6000],
            products: nil,
            airAbsorption: [5])
        var spec = spec(absorption: 0.1)
        spec.hotAirAbsorption = false
        #expect(abs(ThermalMedium(cells, spec: spec).voxels[0].y - 0.1) < 1e-6)
        spec.hotAirAbsorption = true
        #expect(abs(ThermalMedium(cells, spec: spec).voxels[0].y - 5.1) < 1e-5)
    }

    @Test("Rays through the early frames' shells come out exact, ground or block cutting them short")
    func shells() throws {
        var spec = spec(absorption: 0)
        spec.hotAirAbsorption = true
        let sigma = Float(ThermalExposure.stefanBoltzmann / Double.pi)
        // Ten shells of 0.1 m: the outer two hot air at 6,600 K absorbing 10/m, the rest a core at
        // 3,500 K absorbing 5,000/m, opaque.
        let sphere = FireballSphere(
            centre: SIMD3(5, 5, 5), shellSize: 0.1, temperatures: (0..<10).map { $0 >= 8 ? 6600 : 3500 },
            products: [Float](repeating: 0, count: 10),
            airAbsorption: (0..<10).map { $0 >= 8 ? 10 : 5000 })
        let medium = SphericalMedium([sphere], spec: spec)
        let hot = sigma * pow(6600, 4)
        let core = sigma * pow(3500, 4)
        // Through the middle: 0.2 m of hot air, then the black core.
        let passed = exp(-10 * Float(0.2))
        let middle = medium.radiance(from: SIMD3(0, 5, 5), along: SIMD3(1, 0, 0), limit: .infinity)
        #expect(abs(middle / (hot * (1 - passed) + passed * core) - 1) < 1e-4)
        // Grazing the outer shell only, 0.95 m off the centre: its chord, 2√(1 − 0.95²) m.
        let chord = 2 * (1 - 0.95 * 0.95 as Float).squareRoot()
        let grazing = medium.radiance(from: SIMD3(0, 5.95, 5), along: SIMD3(1, 0, 0), limit: .infinity)
        #expect(abs(grazing / (hot * (1 - exp(-10 * chord))) - 1) < 1e-3)
        // Cut short where the hot air begins, nothing; and missing it, nothing.
        #expect(medium.radiance(from: SIMD3(0, 5, 5), along: SIMD3(1, 0, 0), limit: 4) == 0)
        #expect(medium.radiance(from: SIMD3(0, 6.5, 5), along: SIMD3(1, 0, 0), limit: .infinity) == 0)
        // Without the hot air's absorption the outer shells absorb nothing at all here.
        spec.hotAirAbsorption = false
        let grey = SphericalMedium([sphere], spec: spec)
        #expect(grey.radiance(from: SIMD3(0, 5.95, 5), along: SIMD3(1, 0, 0), limit: .infinity) == 0)
        // They travel intact, and a kept frame drops them.
        let frame = FireballFrame(
            time: 0.001, volume: 4, centre: sphere.centre, temperature: 4000, hottest: 6600, spheres: [sphere]
        )
        #expect(try JSONDecoder().decode(FireballFrame.self, from: JSONEncoder().encode(frame)) == frame)
        #expect(frame.withoutShape.spheres == nil)
    }

    @Test("The cells travel intact, and a fireball too large is merged until it fits")
    func cells() throws {
        let cells = LuminousCells(
            voxelSize: 0.25, first: SIMD3(3, 4, 0), counts: SIMD3(2, 2, 1), fills: [255, 0, 255, 255],
            temperatures: [2000, 0, 1800, 2400], products: [0.5, 0, 1, 0.25])
        #expect(try LuminousCells(binary: cells.binary) == cells)
        let frame = FireballFrame(
            time: 0.01, volume: 1, centre: .zero, temperature: 2000, hottest: 2400, cells: cells)
        #expect(try JSONDecoder().decode(FireballFrame.self, from: JSONEncoder().encode(frame)) == frame)
        #expect(frame.withoutShape.cells == nil && frame.withoutCells.cells == nil)
        #expect(throws: (any Error).self) { try LuminousCells(binary: cells.binary.dropLast()) }
        // 128 by 128 by 128 cells, all luminous, merged in twos.
        let counts = SIMD3(128, 128, 128)
        let merged = try #require(
            LuminousCells(cellSize: 0.1, low: SIMD3(10, 10, 0), counts: counts, hasProducts: false) { _ in
                SIMD2(2000, UInt32(Float16(0.5).bitPattern))
            })
        #expect(
            merged.voxelSize == 0.2 && merged.counts == SIMD3(64, 64, 64) && merged.first == SIMD3(5, 5, 0))
        #expect(merged.fills.allSatisfy { $0 == 255 } && merged.temperatures.allSatisfy { $0 == 2000 })
        #expect(merged.airAbsorption?.allSatisfy { $0 == 0.5 } == true)
        // With the hot air's absorption as well, and without the products.
        let absorbing = LuminousCells(
            voxelSize: 0.25, first: .zero, counts: SIMD3(2, 1, 1), fills: [255, 64],
            temperatures: [6000, 2000],
            products: nil, airAbsorption: [40, 0.001])
        #expect(try LuminousCells(binary: absorbing.binary) == absorbing)
        #expect(absorbing.binary.count == 32 + 2 * 5)
        #expect(abs(merged.volume - 12.8 * 12.8 * 12.8) < 1e-3)
    }

    @Test("A description is the volume unless it says otherwise, and older ones keep their model")
    func model() throws {
        let defaults = try JSONDecoder().decode(ThermalSpec.self, from: Data("{}".utf8))
        #expect(defaults.fireball == .volume && defaults.absorption == 0.1 && defaults.sootYield == 0.185)
        let shape = try JSONDecoder().decode(ThermalSpec.self, from: Data(#"{"fireball": "shape"}"#.utf8))
        #expect(shape.fireball == .shape)
        var bad = ThermalSpec()
        bad.absorption = -1
        #expect(throws: (any Error).self) { try bad.validate() }
    }
}
