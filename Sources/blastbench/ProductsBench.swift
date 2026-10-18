import BlastCore
import Foundation
import RadialBlast

/// `blastbench products`: the one-dimensional start of a surface burst with its products as the
/// air's gas (as runs start) and as detonation products (JWL, TNT's two sets from the LLNL
/// handbook), against Kingery–Bulmash close in: incident peak, impulse and arrival from 0.2
/// m/kg^(1/3), the products' reach and heat over time, and the cost. `--mass` (kg, 1), `--reach`
/// (m/kg^(1/3), 7), `--refined` (times the start's cells, 1).
func runProducts() throws {
    let mass = option("mass").flatMap { Float($0) } ?? 1
    let reach = option("reach").flatMap { Float($0) } ?? 7
    let refined = option("refined").flatMap { Int($0) } ?? 1
    let configuration = SolverConfiguration.recommended
    let variants: [(String, SphericalBlast.JWL?)] = [
        ("hot air", nil), ("JWL (a)", .tnt), ("JWL (b)", .tntLeeFinger),
    ]
    let scaled: [Double] = [0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.75, 1, 1.5, 2, 3, 4, 6]
    let cube = cbrt(Double(mass))
    var solved: [(String, SphericalBlast, Double)] = []
    // The products' reach and mean heat at these scaled times, ms/kg^(1/3).
    let moments: [Double] = [0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 4]
    var fireball: [String: [(reach: Double, temperature: Double)]] = [:]
    for (name, products) in variants {
        var blast = BlastSolver.mappedStartStudy(
            mass: mass, reach: reach, configuration: configuration, products: products, refined: refined)
        let start = Date()
        var rows: [(Double, Double)] = []
        // Run between the moments to see the products, then on to the reach.
        for moment in moments {
            blast.run(toShockRadius: Double(reach) * cube, until: moment * 1e-3 * cube)
            rows.append(productsState(blast))
        }
        blast.run(toShockRadius: Double(reach) * cube)
        let seconds = Date().timeIntervalSince(start)
        fireball[name] = rows.map { (reach: $0.0, temperature: $0.1) }
        solved.append((name, blast, seconds))
    }
    print(
        "Surface burst of \(mass) kg on rigid ground, solved in one dimension (\(solved[0].1.density.count) cells), "
            + "against Kingery–Bulmash")
    for (title, value) in [
        ("Incident peak overpressure", 0), ("Incident positive impulse", 1), ("Arrival", 2),
    ] {
        print("\n\(title)")
        print(
            "     Z  reference"
                + solved.map { String(repeating: " ", count: max(1, 10 - $0.0.count)) + $0.0 }.joined())
        for z in scaled {
            guard let point = KingeryBulmash.point(at: z) else { continue }
            let r = z * cube
            let reference: Double
            switch value {
            case 0: reference = point.incidentPressure
            case 1: reference = point.incidentImpulse(mass: Double(mass))
            default: reference = point.arrival(mass: Double(mass))
            }
            let cells = solved.map { _, blast, _ -> String in
                let model: Double
                switch value {
                case 0: model = blast.extremes(at: r).x
                case 1: model = blast.extremes(at: r).y
                default: model = blast.arrival(at: r) ?? .nan
                }
                return String(format: "%10.0f%%", 100 * model / reference)
            }
            let shown = value == 0 ? reference / 1e3 : value == 1 ? reference : reference * 1e3
            print(String(format: "%6.2f %10.1f", z, shown) + cells.joined())
        }
    }
    print("\nThe products' reach (where they are half the mass, m/kg^(1/3)) and mean heat (K, as air)")
    print("t ms/kg^(1/3)" + variants.map { "  " + $0.0 + " (reach, K)" }.joined())
    for (k, moment) in moments.enumerated() {
        let cells = variants.map { name, _ -> String in
            let row = fireball[name]![k]
            return String(format: "   %6.3f %6.0f       ", row.reach / cube, row.temperature)
        }
        print(String(format: "%8.2f    ", moment) + cells.joined())
    }
    // Mapped at a shock radius of Z: the products' pressure as the grid's hot air reads their
    // state, against their own law, mass-weighted over cells a hundredth products or more, and the
    // worst.
    print("\nHanded over at Z: the products' pressure as hot air reads it, against JWL's (mean, worst)")
    for z in [0.15, 0.25, 0.4, 0.6, 1.0] {
        var blast = BlastSolver.mappedStartStudy(
            mass: mass, reach: Float(z), configuration: configuration, products: .tnt, refined: refined)
        blast.run(toShockRadius: z * cube)
        let air = SphericalBlast.Gas(gamma: blast.gas.gamma, thermallyPerfect: blast.gas.thermallyPerfect)
        var weighted = 0.0
        var weight = 0.0
        var worst = 1.0
        for i in blast.density.indices {
            let rho = blast.density[i]
            let y = blast.products[i] / rho
            guard y > 0.01 else { continue }
            let e = blast.energy[i] - 0.5 * blast.momentum[i] * blast.momentum[i] / rho
            let own = blast.gas.pressure(density: rho, internalEnergy: e, products: y)
            let read = air.pressure(density: rho, internalEnergy: e)
            let r = (Double(i) + 0.5) * blast.cellSize
            weighted += read / own * blast.products[i] * r * r
            weight += blast.products[i] * r * r
            if abs(read / own - 1) > abs(worst - 1) { worst = read / own }
        }
        print(String(format: "  Z %.2f: %.2f, %.2f", z, weighted / max(weight, 1e-30), worst))
    }
    print(
        "\nCost: "
            + solved.map { "\($0.0) \(String(format: "%.1f", $0.2)) s, \($0.1.steps) steps" }.joined(
                separator: "; "))
}

/// Where the products are half the mass, outermost, and their mass-weighted temperature (as air at
/// their energy per kilogram), from a one-dimensional solution.
private func productsState(_ blast: SphericalBlast) -> (Double, Double) {
    let dx = blast.cellSize
    var reach = 0.0
    var heat = 0.0
    var mass = 0.0
    for i in blast.density.indices {
        let r = (Double(i) + 0.5) * dx
        // The products the solver carries; without their own law, the unburnt and burnt products
        // alike are the charge's mass spread as its fuel species was before burning: use the
        // share of the solution's fuel and burnt fuel there, approximated by the fuel itself.
        let carried =
            blast.products.isEmpty || blast.products.allSatisfy({ $0 == 0 })
            ? blast.fuel[i] : blast.products[i]
        let share = carried / max(blast.density[i], 1e-9)
        if share > 0.5 { reach = r + 0.5 * dx }
        let volume = 4 * Double.pi * r * r * dx
        let rho = blast.density[i]
        let specific =
            (blast.energy[i] - 0.5 * blast.momentum[i] * blast.momentum[i] / max(rho, 1e-9)) / max(rho, 1e-9)
        heat += carried * volume * airTemperature(specific)
        mass += carried * volume
    }
    return (reach, mass > 0 ? heat / mass : 0)
}

/// The temperature of air at `specific` J/kg internal energy (translation, rotation, N2 and O2's
/// vibration).
private func airTemperature(_ specific: Double) -> Double {
    let r = 287.05
    var t = max(specific, 1) / (2.5 * r)
    for _ in 0..<12 {
        let x = 3390 / max(t, 1)
        let y = 2270 / max(t, 1)
        let ex = exp(min(x, 80))
        let ey = exp(min(y, 80))
        let energy = 2.5 * r * t + r * (0.79 * 3390 / (ex - 1) + 0.21 * 2270 / (ey - 1))
        let heat =
            2.5 * r + r
            * (0.79 * x * x * ex / ((ex - 1) * (ex - 1)) + 0.21 * y * y * ey / ((ey - 1) * (ey - 1)))
        t = max(t - (energy - specific) / heat, 1)
    }
    return t
}
