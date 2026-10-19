import BlastCore
import Foundation
import Metal

/// `blastbench delayedcharges`: two alike surface bursts on rigid ground (`--mass` kg each, 1;
/// `--apart` m/kg^(1/3), 4.6), the second fired `--delay` ms after the first (5), each on today's
/// start (mapped, the second laid when its solution reaches its radius, or as the balloon if the
/// air about it is not still by then) on cells of `--dx` m (0.2), against the same scene run
/// without interruption on cells `--reference` times finer (4), both charges as the balloon, the
/// second laid at its firing time. Gauges beyond each charge, between them and off to the side, at
/// `--z` m/kg^(1/3) (2,3,4,6) from their charge: arrival, peak and impulse of the whole record.
func runDelayedCharges(device: MTLDevice) throws {
    let mass = option("mass").flatMap { Float($0) } ?? 1
    let cube = cbrt(mass)
    let apart = (option("apart").flatMap { Float($0) } ?? 4.6) * cube
    let delay = (option("delay").flatMap { Float($0) } ?? 5) / 1000
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.2
    let finer = option("reference").flatMap { Int($0) } ?? 4
    let scaled = option("z").map { $0.split(separator: ",").compactMap { Float($0) } } ?? [2, 3, 4, 6]
    let reach = (scaled.max() ?? 6) * cube
    // Faces 4 m/kg^(1/3) beyond the farthest gauge, and as far either side and above.
    let margin = 4 * cube
    let length = apart + 2 * (reach + margin)
    let width = 2 * (reach + margin)
    let first = SIMD3(reach + margin, width / 2, 0)
    let second = first + SIMD3(apart, 0, 0)
    let height: Float = 1.5
    var gauges: [Gauge] = []
    for z in scaled {
        gauges.append(
            Gauge("beyond the first, Z \(format(Double(z), 1))", at: first - SIMD3(z * cube, 0, -height)))
        gauges.append(
            Gauge("beyond the second, Z \(format(Double(z), 1))", at: second + SIMD3(z * cube, 0, height)))
        gauges.append(
            Gauge("beside the second, Z \(format(Double(z), 1))", at: second + SIMD3(0, z * cube, height)))
    }
    gauges.append(Gauge("between them", at: (first + second) / 2 + SIMD3(0, 0, height)))
    var scenario = Scenario(
        name: "Delayed charges", domainSize: SIMD3(length, width, margin + height), boxes: [],
        charge: Charge(mass: mass, position: first), gauges: gauges)
    scenario.additionalCharges = [Charge(mass: mass, position: second, delay: delay)]
    scenario.reflectiveFaces = .ground
    let end = Double(apart + reach) / 340 * 1.4 + Double(delay) + 0.01

    func solve(_ configuration: SolverConfiguration, cellSize: Float) throws -> (BlastSolver, Double) {
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
        let started = Date()
        solver.advance(until: end)
        return (solver, Date().timeIntervalSince(started))
    }
    var today = SolverConfiguration.recommended
    applyChosenAir(&today)
    var reference = SolverConfiguration.recommended.balloonStart
    applyChosenAir(&reference)
    let (run, seconds) = try solve(today, cellSize: cellSize)
    let (fine, fineSeconds) = try solve(reference, cellSize: cellSize / Float(finer))
    print(
        "Two \(mass) kg surface bursts \(format(Double(apart), 2)) m apart on rigid ground, the second "
            + "\(format(Double(delay) * 1e3, 2)) ms later; cells \(cellSize) m "
            + (run.mappedRadii.isEmpty
                ? "as the balloon"
                : "mapped \(run.mappedRadii.map { format(Double($0), 2) + " m" }.joined(separator: ", ")) out")
            + " (\(format(seconds, 0)) s), against cells \(format(Double(cellSize) / Double(finer), 3)) m as the "
            + "balloon (\(format(fineSeconds, 0)) s)")
    for firing in run.firings {
        print(
            "  The second: \(firing.how.rawValue), laid at \(format(firing.laidAt * 1e3, 2)) ms"
                + (firing.note.map { ". \($0)" } ?? ""))
    }
    let ambient = scenario.atmosphere.pressure
    func reading(_ samples: [GaugeSample]) -> (arrival: Double?, peak: Double, impulse: Double) {
        let peak = Double((samples.map(\.pressure).max() ?? ambient) - ambient)
        let arrival = samples.first { $0.pressure - ambient > 0.1 * Float(peak) }?.time
        var total = 0.0
        for (a, b) in zip(samples, samples.dropFirst()) {
            total += (b.time - a.time) * Double(max(0.5 * (a.pressure + b.pressure) - ambient, 0))
        }
        return (arrival, peak, total)
    }
    print(
        pad("Gauge", 30) + pad("arrival, ms", 18) + pad("peak, kPa", 22) + pad("impulse, Pa s", 22))
    print(
        pad("", 30) + pad("today  fine", 18) + pad("today  fine  ratio", 22) + pad("today  fine  ratio", 22))
    var peakRatios: [Double] = []
    var impulseRatios: [Double] = []
    for (n, gauge) in gauges.enumerated() {
        let a = reading(run.gaugeHistories[n])
        let b = reading(fine.gaugeHistories[n])
        let arrivals = [a.arrival, b.arrival].map { $0.map { format($0 * 1e3, 2) } ?? "-" }
        peakRatios.append(a.peak / b.peak)
        impulseRatios.append(a.impulse / b.impulse)
        print(
            pad(gauge.name, 30) + pad(arrivals.joined(separator: "  "), 18)
                + pad(
                    "\(format(a.peak / 1e3, 1))  \(format(b.peak / 1e3, 1))  \(format(a.peak / b.peak, 2))",
                    22)
                + pad(
                    "\(format(a.impulse, 1))  \(format(b.impulse, 1))  \(format(a.impulse / b.impulse, 2))",
                    22))
    }
    print(
        "Ratios today/fine: peaks \(format(peakRatios.min() ?? 0, 2))–\(format(peakRatios.max() ?? 0, 2)), "
            + "impulses \(format(impulseRatios.min() ?? 0, 2))–\(format(impulseRatios.max() ?? 0, 2))")
}
