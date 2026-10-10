import Foundation
import Metal
import simd

/// A gas–air mixture burning from the centre of a closed sphere, against the thin-flame model
/// (see `DeflagrationReference.closedSphere`) and the deflagration index's cube-root law.
public struct ClosedVesselStudy: Sendable {
    public var gas: FlammableGas = .methane
    public var concentration: Float?
    /// The sphere's radius, m.
    public var radius: Float = 0.5
    /// Cells across the sphere's radius.
    public var cellsPerRadius: Int = 20
    public var airModel: AirModel = .idealGas
    public var acceleration: FlameAcceleration = .laminar

    public init(
        gas: FlammableGas = .methane, concentration: Float? = nil, radius: Float = 0.5,
        cellsPerRadius: Int = 20,
        airModel: AirModel = .idealGas, acceleration: FlameAcceleration = .laminar
    ) {
        self.gas = gas
        self.concentration = concentration
        self.radius = radius
        self.cellsPerRadius = cellsPerRadius
        self.airModel = airModel
        self.acceleration = acceleration
    }

    public struct Result: Sendable {
        public var cellSize: Float
        /// The sphere's fluid volume, m³, and the radius of a sphere that size.
        public var volume: Double
        public var effectiveRadius: Double
        /// Pressure at a gauge just inside the wall, absolute, over time.
        public var times: [Double]
        public var pressures: [Double]
        public var initialPressure: Double
        /// The model's AICC pressure for the mixture (absolute).
        public var modelAICC: Double
        /// The highest pressure reached, smoothed over a hundredth of the burn (absolute), and when.
        public var peakPressure: Double
        public var peakTime: Double
        /// Largest rate of pressure rise, Pa/s, and the deflagration index (dp/dt)_max V^(1/3),
        /// bar m/s.
        public var peakRate: Double
        public var deflagrationIndex: Double
        /// Share of the mixture burnt by the end.
        public var burntFraction: Double
        /// The thin-flame model for the same sphere, mixture and burning velocity.
        public var reference: ClosedVesselHistory
        public var referenceIndex: Double
        /// Energy the gas gained over the heat its burnt mixture released, less one.
        public var energyError: Double
        public var burningVelocity: Double
        /// When the pressure has risen by half and by nine tenths of the way to the model's AICC
        /// pressure, s: simulated, then the thin-flame model's.
        public var halfRise: Double
        public var mostRise: Double
        public var referenceHalfRise: Double
        public var referenceMostRise: Double
    }

    /// When `values` first reach `level`, interpolated between samples; nil if never.
    static func crossing(times: [Double], values: [Double], level: Double) -> Double? {
        guard let n = values.firstIndex(where: { $0 >= level }) else { return nil }
        guard n > 0 else { return times[0] }
        let share = (level - values[n - 1]) / (values[n] - values[n - 1])
        return times[n - 1] + share * (times[n] - times[n - 1])
    }

    public func run(
        device: MTLDevice, duration: Double? = nil,
        report: ((Double, DeflagrationState, Float) -> Void)? = nil
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
        if let report {
            // Every twentieth of the run: the time, the flame and the gauge's pressure.
            for n in 1...20 {
                solver.advance(until: end * Double(n) / 20)
                if let state = solver.deflagrationState() {
                    report(solver.time, state, solver.gaugeHistories[0].last?.pressure ?? 0)
                }
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

    /// `values` averaged over `window` (s) centred on each sample.
    static func smoothed(times: [Double], values: [Double], window: Double) -> [Double] {
        var result = values
        var low = 0
        var high = 0
        var sum = 0.0
        for n in times.indices {
            while high < times.count, times[high] <= times[n] + window / 2 {
                sum += values[high]
                high += 1
            }
            while times[low] < times[n] - window / 2 {
                sum -= values[low]
                low += 1
            }
            result[n] = sum / Double(high - low)
        }
        return result
    }

    /// The largest slope of `values` over `window` (s), by differences of the smoothed values a
    /// window apart.
    static func maximumRate(times: [Double], values: [Double], window: Double) -> Double {
        let smooth = smoothed(times: times, values: values, window: window)
        var best = 0.0
        var later = 0
        for n in times.indices {
            while later < times.count - 1, times[later] < times[n] + window { later += 1 }
            let span = times[later] - times[n]
            if span > 0.5 * window { best = max(best, (smooth[later] - smooth[n]) / span) }
        }
        return best
    }
}

/// `try #require`-like unwrapping for library code.
private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw BlastError.allocationFailed("deflagration state") }
    return value
}

/// A room full of a gas–air mixture, ignited inside, with one square vent in the middle of a wall,
/// against the venting correlations (see `VentCorrelations`). The default room is FM Global's
/// 63.7 m³ chamber as Bauwens, Chaffee and Dorofeev (2008) used it: 4.6 × 4.6 × 3.0 m inside,
/// with the vent in a 4.6 × 3.0 m wall.
public struct VentedRoomStudy: Sendable {
    public enum Ignition: String, Sendable, CaseIterable {
        /// The middle of the room.
        case centre
        /// 0.25 m from the middle of the wall opposite the vent.
        case backWall
    }

    public var gas: FlammableGas = .methane
    public var concentration: Float?
    /// Inside dimensions: along the vent's axis, across it, and the height.
    public var room = SIMD3<Float>(4.6, 4.6, 3.0)
    public var ventArea: Float = 5.4
    /// Overpressure at which the vent's cover releases, Pa (0: an open vent).
    public var releasePressure: Float = 0
    public var ignition: Ignition = .centre
    public var cellSize: Float = 0.1
    public var acceleration = FlameAcceleration()
    public var airModel: AirModel = .idealGas
    /// The walls' and roof's thickness, m: the same at every resolution.
    public var wallThickness: Float = 0.2
    /// The longest the run may go on, s.
    public var maximumTime: Double = 4

    public init() {}

    public struct Result: Sendable {
        /// The peak overpressure at the middle of the back wall, Pa: after an 80 Hz low-pass
        /// filter (a moving average over 1/80 s, as Bauwens et al. filtered theirs), and as
        /// sampled every step.
        public var reducedPressure: Double
        public var rawPeak: Double
        public var peakTime: Double
        /// When the vent's cover released, s.
        public var ventOpened: Double?
        /// The share of the mixture gone by the end: burnt, or carried out of the domain unburnt.
        public var burntFraction: Double
        public var duration: Double
        /// The back wall's overpressure over time (Pa).
        public var times: [Double]
        public var overpressures: [Double]
        public var correlations: VentCorrelations
        public var cellSize: Float
        public var steps: Int
    }

    /// The scenario: the room's walls as blocks, the vent's cover as a panel, the room full of
    /// mixture and gauges at the middle of the back wall, the room's middle and outside.
    public func scenario() -> Scenario {
        let t = wallThickness
        let margin: Float = 1
        let outside: Float = 4
        let side = ventArea.squareRoot()
        let size = SIMD3(t + room.x + t + outside, margin + t + room.y + t + margin, room.z + t + 1.5)
        let x0 = t
        let y0 = margin + t
        let x1 = x0 + room.x
        let y1 = y0 + room.y
        let z1 = room.z
        var blocks = [
            Box(min: SIMD3(0, y0 - t, 0), max: SIMD3(x0, y1 + t, z1 + t)),  // back wall
            Box(min: SIMD3(x0, y0 - t, 0), max: SIMD3(x1, y0, z1 + t)),  // side walls
            Box(min: SIMD3(x0, y1, 0), max: SIMD3(x1, y1 + t, z1 + t)),
            Box(min: SIMD3(x0, y0, z1), max: SIMD3(x1, y1, z1 + t)),  // roof
        ]
        // The vent wall, around a square opening in its middle.
        let vy0 = 0.5 * (y0 + y1) - 0.5 * side
        let vy1 = vy0 + side
        let vz0 = 0.5 * z1 - 0.5 * side
        let vz1 = vz0 + side
        blocks += [
            Box(min: SIMD3(x1, y0 - t, 0), max: SIMD3(x1 + t, vy0, z1 + t)),
            Box(min: SIMD3(x1, vy1, 0), max: SIMD3(x1 + t, y1 + t, z1 + t)),
            Box(min: SIMD3(x1, vy0, 0), max: SIMD3(x1 + t, vy1, vz0)),
            Box(min: SIMD3(x1, vy0, vz1), max: SIMD3(x1 + t, vy1, z1 + t)),
        ]
        let middle = SIMD3(0.5 * (x0 + x1), 0.5 * (y0 + y1), 0.5 * z1)
        let lit = ignition == .centre ? middle : SIMD3(x0 + 0.25, middle.y, middle.z)
        var scenario = Scenario(
            name: "Vented room", domainSize: size, boxes: blocks, charge: Charge(mass: 0, position: lit),
            gauges: [
                Gauge("Back wall", at: SIMD3(x0 + 0.5 * cellSize, middle.y, middle.z)),
                Gauge("Middle", at: middle),
                Gauge("Outside", at: SIMD3(x1 + t + 1.17, middle.y, 0.3)),
            ])
        scenario.deflagration = Deflagration(
            gas: gas, concentration: concentration,
            region: Box(min: SIMD3(x0, y0, 0), max: SIMD3(x1, y1, z1)),
            ignition: lit, acceleration: acceleration)
        if releasePressure > 0 {
            scenario.ventPanels = [
                VentPanel(
                    box: Box(min: SIMD3(x1, vy0, vz0), max: SIMD3(x1 + t, vy1, vz1)),
                    releasePressure: releasePressure)
            ]
        }
        return scenario
    }

    public var correlations: VentCorrelations {
        let volume = Double(room.x * room.y * room.z)
        let surface = Double(2 * (room.x * room.y + room.x * room.z + room.y * room.z))
        return VentCorrelations(
            volume: volume, surfaceArea: surface, ventArea: Double(ventArea),
            releasePressure: Double(releasePressure),
            gas: gas)
    }

    public func run(device: MTLDevice, progress: ((Double, Double) -> Void)? = nil) throws -> Result {
        let scenario = scenario()
        var configuration = SolverConfiguration()
        configuration.airModel = airModel
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
        // Until most of the mixture has gone (burnt, or blown out of the domain unburnt) and no more
        // than half a percent of it has gone in the last fifth of a second.
        var steps = 0
        var gone: [Double] = []
        while solver.time < maximumTime {
            steps += solver.advance(until: solver.time + 0.05).steps
            let burnt = solver.deflagrationState()?.burntFraction ?? 1
            progress?(solver.time, burnt)
            gone.append(burnt)
            if burnt > 0.5, gone.count > 4, burnt - gone[gone.count - 5] < 0.005 { break }
        }
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
            steps: steps)
    }
}
