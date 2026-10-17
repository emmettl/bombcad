import Foundation
import Testing

@testable import BlastCore

/// UFC 3-340-02's interior loads through front-wall openings (`UFCInteriorLoads`), against its
/// own worked Example 2A-11: 6,000 lb TNT 155 ft from a building 30 ft deep, 20 ft wide and 15 ft
/// tall with 1/8 of its front open; Pso 12.6 psi, Lw 38.2 ft.
@Suite("UFC interior loads")
struct UFCInteriorLoadTests {
    @Test("Example 2A-11's wave length, back wall and side walls come out as the UFC works them")
    func example() {
        let feet = 0.3048
        let wavelength = UFCInteriorLoads.wavelength(mass: 6_000 * 0.453_592, range: 155 * feet)
        #expect(abs(wavelength / (38.2 * feet) - 1) < 0.03, "\(wavelength / feet) ft")
        // Step 5: P_RIB / Pso = 0.575 from the back-wall chart at L/H = 2.
        let back = UFCInteriorLoads.backWallRatio(pressurePsi: 12.6, openingRatio: 1.0 / 8, lengthToHeight: 2)
        #expect(abs(back - 0.575) < 0.015, "\(back)")
        // Step 4: 7.60 psi at W/H = 3/2 by equation 2-15.
        let side = UFCInteriorLoads.sideWallPsi(
            pressurePsi: 12.6, openingRatio: 1.0 / 8, wavelengthToLength: 1.27, widthToHeight: 1.5,
            lengthToHeight: 2)
        #expect(abs(side - 7.60) < 0.05, "\(side) psi")
        // Step 3B: Pmax × Lw/H read by eye at W/H = 3/2 and Lw/H = 2.54 as 42.1 psi (Figure
        // 2A-17a), so 16.6 psi; the chart's own data give 11% less.
        let front = UFCInteriorLoads.frontWallPsi(
            pressurePsi: 12.6, openingRatio: 1.0 / 8, wavelengthToHeight: 2.54)
        #expect(abs(front / 16.6 - 1) < 0.15, "\(front) psi")
    }

    @Test("The back wall's share grows with the opening and falls with depth, as the charts do")
    func trends() {
        let small = UFCInteriorLoads.backWallRatio(pressurePsi: 8, openingRatio: 1.0 / 8, lengthToHeight: 2)
        let large = UFCInteriorLoads.backWallRatio(pressurePsi: 8, openingRatio: 1.0 / 4, lengthToHeight: 2)
        let deep = UFCInteriorLoads.backWallRatio(pressurePsi: 8, openingRatio: 1.0 / 4, lengthToHeight: 4)
        #expect(abs(large - 0.8208) < 1e-4)
        #expect(small < large && deep < large)
    }
}
