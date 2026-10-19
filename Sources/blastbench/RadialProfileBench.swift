import BlastCore
import Foundation
import RadialBlast

/// `blastbench radial-profile`: the mapped start's one-dimensional surface burst (`--mass` kg,
/// 453,600; today's air) at `--times` ms (0.5,1,1.25,2,5): from the products' edge out through the
/// shock, every `--every`-th cell (4), its radius, temperature, density, unburnt products and
/// absorption as hot air (`HotAir`), to see where the luminous gas is and how thick and hot the
/// shock's layer of air is.
func runRadialProfile() throws {
    let mass = option("mass").flatMap { Float($0) } ?? 453_600
    let times = (option("times") ?? "0.5,1,1.25,2,5").split(separator: ",").compactMap { Double($0) }
        .map { $0 * 1e-3 }
    let every = option("every").flatMap { Int($0) } ?? 4
    let configuration = SolverConfiguration.recommended
    var blast = BlastSolver.mappedStartStudy(
        mass: mass, reach: option("reach").flatMap { Float($0) } ?? 2, configuration: configuration,
        products: nil)
    blast.snapshotTimes = times
    blast.run(toShockRadius: .infinity, until: times.max() ?? 0)
    let model = configuration.airModel
    for snapshot in blast.snapshots {
        let temperature = snapshot.density.indices.map { i -> Float in
            let rho = max(snapshot.density[i], 1e-9)
            let p = model.pressure(
                density: rho, internalEnergy: rho * snapshot.specificEnergy[i], gamma: configuration.gamma)
            return model.temperature(density: rho, pressure: p)
        }
        // The shock: the outermost cell a tenth denser than the air ahead.
        let shock = snapshot.density.lastIndex { $0 > 1.1 * 1.225 } ?? 0
        // The products' edge: the outermost cell holding a hundredth of the air's density of them.
        let edge = snapshot.unburnt.lastIndex { $0 > 0.01 * 1.225 } ?? 0
        print(
            String(
                format: "%.2f ms: products to %.2f m, shock at %.2f m (cells of %.3f m)", snapshot.time * 1e3,
                Double(edge + 1) * blast.cellSize, Double(shock + 1) * blast.cellSize, blast.cellSize))
        // `--dump prefix`: the whole profile as CSV, prefix-<ms>.csv.
        if let prefix = option("dump") {
            var text = "r_m,temperature_K,density,products\n"
            for i in temperature.indices {
                text += String(
                    format: "%.4f,%.1f,%.5g,%.5g\n", (Double(i) + 0.5) * blast.cellSize, temperature[i],
                    snapshot.density[i], snapshot.unburnt[i])
            }
            try text.write(
                toFile: "\(prefix)-\(String(format: "%.2f", snapshot.time * 1e3)).csv", atomically: true,
                encoding: .utf8)
        }
        print("     r m      T K   rho/rho0   products   hot air 1/m")
        let from = max(edge - 8 * every, 0)
        for i in stride(from: from, through: min(shock + 2 * every, temperature.count - 1), by: every) {
            print(
                String(
                    format: "%8.2f %8.0f %10.3f %10.3g %13.3g", (Double(i) + 0.5) * blast.cellSize,
                    temperature[i], snapshot.density[i] / 1.225, snapshot.unburnt[i],
                    HotAir.planckAbsorption(temperature: temperature[i], density: snapshot.density[i])))
        }
    }
}
