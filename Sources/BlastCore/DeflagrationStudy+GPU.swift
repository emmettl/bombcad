import BlastModel
import Foundation
import Metal
import simd

extension ClosedVesselStudy {
    public func run(
        device: MTLDevice, duration: Double? = nil,
        report: ((Double, DeflagrationState, Float) -> Void)? = nil, monitor: ((BlastSolver) -> Void)? = nil
    ) throws -> Result {
        let dx = radius / Float(cellsPerRadius)
        let side = 2 * radius + 2 * dx
        let centre = SIMD3<Float>(repeating: side / 2)
        let cloud = Deflagration(
            gas: gas, concentration: concentration, region: Box(min: .zero, max: SIMD3(repeating: side)),
            ignition: centre, acceleration: acceleration)
        var scenario = Scenario(
            name: "Closed sphere", domainSize: SIMD3(repeating: side), boxes: [],
            charge: Charge(mass: 0, position: centre),
            gauges: [Gauge("wall", at: centre + SIMD3(radius - 1.5 * dx, 0, 0))])
        scenario.reflectiveFaces = .all
        scenario.deflagration = cloud
        var configuration = SolverConfiguration()
        configuration.airModel = airModel
        configuration.mixing = mixing
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: dx, configuration: configuration)
        // The sphere: every cell whose centre lies outside it is solid.
        let grid = solver.grid
        solver.mutateMask { mask in
            for k in 0..<grid.nz {
                for j in 0..<grid.ny {
                    for i in 0..<grid.nx where simd_distance(grid.cellCentre(i, j, k), centre) > radius {
                        mask[grid.index(i, j, k)] = 1
                    }
                }
            }
        }
        solver.restart()
        let start = try require(solver.deflagrationState())
        solver.deflagrationStage?.initialUnburnt = start.unburnt
        var fluid = 0
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for i in 0..<grid.nx where !solver.isSolid(i, j, k) { fluid += 1 }
            }
        }
        let volume = Double(fluid) * Double(dx * dx * dx)
        let effectiveRadius = cbrt(3 * volume / (4 * Double.pi))
        let p0 = Double(scenario.atmosphere.pressure)
        let gamma = Double(configuration.gamma)
        let aicc = Double(
            cloud.modelAICCPressure(
                atmosphere: scenario.atmosphere, airModel: airModel, gamma: configuration.gamma))
        let burning = Double(cloud.laminarBurningVelocity)
        let reference = DeflagrationReference.closedSphere(
            radius: effectiveRadius, initialPressure: p0, maximumPressure: aicc, gamma: gamma,
            burningVelocity: burning)
        let energyStart = solver.totals().energy

        let end = duration ?? 1.8 * reference.completion
        if report != nil || monitor != nil {
            // Every fortieth of the run: the time, the flame and the gauge's pressure.
            for n in 1...40 {
                solver.advance(until: end * Double(n) / 40)
                if let state = solver.deflagrationState() {
                    report?(solver.time, state, solver.gaugeHistories[0].last?.pressure ?? 0)
                }
                monitor?(solver)
            }
        } else {
            solver.advance(until: end)
        }

        let history = solver.gaugeHistories[0]
        let times = history.map(\.time)
        let pressures = history.map { Double($0.pressure) }
        let window = reference.completion / 100
        let smoothed = Self.smoothed(times: times, values: pressures, window: window)
        let peakIndex = smoothed.indices.max { smoothed[$0] < smoothed[$1] } ?? 0
        let rate = Self.maximumRate(times: times, values: pressures, window: window)
        let finish = try require(solver.deflagrationState())
        let heat = Double(
            cloud.heatPerKilogram(
                atmosphere: scenario.atmosphere, airModel: airModel, gamma: configuration.gamma))
        let released = heat * (finish.initialUnburnt - finish.unburnt)
        let gained = solver.totals().energy - energyStart
        let smoothedRise = Self.smoothed(times: times, values: pressures, window: window)
        func rise(_ share: Double, _ t: [Double], _ p: [Double]) -> Double {
            Self.crossing(times: t, values: p, level: p0 + share * (aicc - p0)) ?? .nan
        }
        return Result(
            cellSize: dx, volume: volume, effectiveRadius: effectiveRadius, times: times,
            pressures: pressures,
            initialPressure: p0, modelAICC: aicc, peakPressure: smoothed[peakIndex],
            peakTime: times[peakIndex],
            peakRate: rate, deflagrationIndex: rate * cbrt(volume) / 1e5, burntFraction: finish.burntFraction,
            reference: reference,
            referenceIndex: DeflagrationReference.deflagrationIndex(
                initialPressure: p0, maximumPressure: aicc, gamma: gamma, burningVelocity: burning) / 1e5,
            energyError: released > 0 ? gained / released - 1 : 0, burningVelocity: burning,
            halfRise: rise(0.5, times, smoothedRise), mostRise: rise(0.9, times, smoothedRise),
            referenceHalfRise: rise(0.5, reference.times, reference.pressures),
            referenceMostRise: rise(0.9, reference.times, reference.pressures))
    }
}

/// `try #require`-like unwrapping for library code.
private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw BlastError.allocationFailed("deflagration state") }
    return value
}

extension VentedRoomStudy {
    public func run(
        device: MTLDevice, progress: ((Double, Double) -> Void)? = nil,
        inspect: ((BlastSolver) -> Void)? = nil, monitor: ((BlastSolver) -> Void)? = nil
    ) throws -> Result {
        let scenario = scenario()
        var configuration = SolverConfiguration()
        configuration.airModel = airModel
        configuration.openFaces = openFaces
        configuration.gravity = gravity
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
        // The flame's arrival at points along the vent's axis, from the unburnt share there every
        // 5 ms, interpolated to where it crosses a half; probes in walls are left out.
        let grid = solver.grid
        let probes = arrivalProbes(scenario).compactMap { probe -> (Double, Int)? in
            let cell = grid.cell(containing: probe.point)
            return solver.isSolid(cell.i, cell.j, cell.k)
                ? nil : (probe.distance, grid.index(cell.i, cell.j, cell.k))
        }
        var previous = [Float](repeating: 1, count: probes.count)
        var arrived = [Double?](repeating: nil, count: probes.count)
        var previousTime = 0.0
        func checkArrivals() {
            solver.readSpecies { species in
                guard let species else { return }
                for (n, probe) in probes.enumerated() where arrived[n] == nil {
                    let s = species[probe.1]
                    let b = s.y > 1e-6 ? min(max(s.x / s.y, 0), 1) : 1
                    if b < 0.5 {
                        let share = Double((previous[n] - 0.5) / max(previous[n] - b, 1e-6))
                        arrived[n] = previousTime + share * (solver.time - previousTime)
                    }
                    previous[n] = b
                }
            }
            previousTime = solver.time
        }
        // Until most of the mixture has gone (burnt, or blown out of the domain unburnt) and no more
        // than half a percent of it has gone in the last fifth of a second.
        var steps = 0
        var gone: [Double] = []
        while solver.time < maximumTime {
            let target = solver.time + 0.05
            for n in 1...10 {
                steps += solver.advance(until: target - 0.05 + 0.005 * Double(n)).steps
                checkArrivals()
            }
            let burnt = solver.deflagrationState()?.burntFraction ?? 1
            progress?(solver.time, burnt)
            monitor?(solver)
            gone.append(burnt)
            if burnt > 0.5, gone.count > 4, burnt - gone[gone.count - 5] < 0.005 { break }
        }
        inspect?(solver)
        let state = try require(solver.deflagrationState())
        let history = solver.gaugeHistories[0]
        let ambient = Double(scenario.atmosphere.pressure)
        let times = history.map(\.time)
        let overpressures = history.map { Double($0.pressure) - ambient }
        let filtered = ClosedVesselStudy.smoothed(times: times, values: overpressures, window: 1.0 / 80)
        let peak = filtered.indices.max { filtered[$0] < filtered[$1] } ?? 0
        return Result(
            reducedPressure: filtered[peak], rawPeak: overpressures.max() ?? 0, peakTime: times[peak],
            ventOpened: state.panelOpenTimes.first ?? nil, burntFraction: state.burntFraction,
            duration: solver.time,
            times: times, overpressures: overpressures, correlations: correlations, cellSize: cellSize,
            steps: steps,
            arrivals: zip(probes, arrived).compactMap { probe, time in time.map { (probe.0, $0) } })
    }
}
