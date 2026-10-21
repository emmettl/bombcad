import BlastCore
import Foundation
import Metal
import simd

/// Runs an explicit benchmark deck, without the application's source or model defaults.
/// Histories are signed overpressures in Pa, clocked from the deposited t = 0 state.
func runOpenBenchmark() throws {
    guard let path = option("deck"), let runID = option("run"), let output = option("out") else {
        throw OpenBenchmarkDeck.Invalid.deck("Use open-benchmark --deck FILE --run ID --out HISTORY.csv")
    }
    let deck = try OpenBenchmarkDeck.decode(Data(contentsOf: URL(filePath: path)))
    try deck.validate()
    guard let run = deck.runs.first(where: { $0.id == runID }) else {
        throw OpenBenchmarkDeck.Invalid.deck("Unknown run \(runID)")
    }
    var config = SolverConfiguration()
    config.gamma = Float(deck.physics.gamma)
    config.cfl = Float(deck.numerics.cfl)
    config.limiterTheta = Float(deck.numerics.limiterTheta)
    config.startupSteps = deck.numerics.startupSteps
    config.densityFloor = Float(deck.numerics.densityFloor)
    config.pressureFloor = Float(deck.numerics.pressureFloorPa)
    config.ambientPressure = Float(deck.ambient.pressurePa)
    config.reflectiveFaces = BoundaryFaces(
        rawValue: deck.boundaries.reflectingFaces.reduce(0) { $0 | (1 << $1) })
    config.airModel = .idealGas
    config.afterburning = false
    config.mappedCharge = false
    config.radiativeCooling = nil
    config.gravity = nil
    config.openFaces = .copy
    config.riemannSolver = .hllc
    let n = deck.mesh.counts
    let grid = Grid(nx: n[0], ny: n[1], nz: n[2], cellSize: Float(deck.mesh.cellSizeM))
    let solver = try BlastSolver(device: device, grid: grid, configuration: config)
    solver.fill(
        uniform: Primitive(
            density: Float(deck.ambient.densityKgM3), pressure: Float(deck.ambient.pressurePa)))
    solver.mutateState { cells in
        for initial in run.initialCells {
            let p = initial.index
            let index = grid.index(p[0], p[1], p[2])
            cells[index].density = Float(initial.densityKgM3)
            cells[index].energy = Float(initial.internalEnergyJM3)
        }
    }
    solver.restart()
    let start = solver.totals()
    let volume = Double(grid.cellCount) * pow(Double(grid.cellSize), 3)
    let baseline = solver.cellState(
        Primitive(density: Float(deck.ambient.densityKgM3), pressure: Float(deck.ambient.pressurePa)))
    let addedEnergy = start.energy - Double(baseline.energy) * volume
    let addedMass = start.mass - Double(baseline.density) * volume
    guard abs(addedEnergy / run.source.excessEnergyJ - 1) < 1e-4,
        abs(addedMass / run.source.excessMassKg - 1) < 1e-4
    else {
        throw OpenBenchmarkDeck.Invalid.deck("Float initial state lost the declared source budget")
    }
    let url = URL(filePath: output)
    guard !FileManager.default.fileExists(atPath: output) else {
        throw OpenBenchmarkDeck.Invalid.deck("Refusing to overwrite \(output)")
    }
    guard FileManager.default.createFile(atPath: output, contents: nil) else {
        throw OpenBenchmarkDeck.Invalid.deck("Cannot create history")
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.write(contentsOf: Data("case,run,gauge,time_s,overpressurePa\n".utf8))
    let room = deck.sampling.observable == "volume-mean-overpressure"
    let samples = Int((deck.sampling.stopS / deck.sampling.intervalS).rounded())
    for sample in 0...samples {
        let target = Double(sample) * deck.sampling.intervalS
        if sample > 0 {
            let result = solver.advance(until: target)
            guard result.isStable, abs(solver.time - target) <= deck.sampling.timeToleranceS else {
                throw OpenBenchmarkDeck.Invalid.deck("Unstable or incomplete run at \(target)")
            }
        }
        var values: [Double] = []
        solver.withState { cells in
            func pressure(_ index: Int) -> Double {
                let c = cells[index]
                let kinetic =
                    0.5
                    * (Double(c.momentumX) * Double(c.momentumX)
                        + Double(c.momentumY) * Double(c.momentumY) + Double(c.momentumZ)
                        * Double(c.momentumZ)) / Double(c.density)
                return (deck.physics.gamma - 1) * (Double(c.energy) - kinetic) - deck.ambient.pressurePa
            }
            if room {
                values = [cells.indices.reduce(0.0) { $0 + pressure($1) } / Double(cells.count)]
            } else {
                values = run.gauges.map { gauge in
                    guard let position = gauge.positionM else { return .nan }
                    let f = position.map { $0 / deck.mesh.cellSizeM - 0.5 }
                    let base = f.map { Int(floor($0)) }
                    let fraction = zip(f, base).map { $0 - Double($1) }
                    var value = 0.0
                    for z in 0...1 {
                        for y in 0...1 {
                            for x in 0...1 {
                                let offsets = [x, y, z]
                                let p = (0..<3).map { max(0, min(n[$0] - 1, base[$0] + offsets[$0])) }
                                let weight = (0..<3).reduce(1.0) {
                                    $0 * (offsets[$1] == 0 ? 1 - fraction[$1] : fraction[$1])
                                }
                                value += weight * pressure(grid.index(p[0], p[1], p[2]))
                            }
                        }
                    }
                    return value
                }
            }
        }
        for (gauge, value) in zip(run.gauges, values) {
            guard value.isFinite else { throw OpenBenchmarkDeck.Invalid.deck("Non-finite history") }
            let line = "\(deck.caseId),\(runID),\(gauge.id),\(solver.time),\(value)\n"
            try handle.write(contentsOf: Data(line.utf8))
        }
    }
    let final = solver.totals()
    print(
        "\(deck.caseId)/\(runID): \(samples + 1) samples; initial excess energy \(addedEnergy) J, mass \(addedMass) kg; final total energy / initial \(final.energy / start.energy)"
    )
}
