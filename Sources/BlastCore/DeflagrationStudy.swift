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
    /// The air's sub-grid mixing, which flame turbulence turns on in any case.
    public var mixing: SubgridMixing?

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
    /// Obstacles: square posts this wide (m) from floor to ceiling, on a 1 m grid centred on the
    /// room, leaving out any within 0.5 m of the ignition point. nil for an empty room.
    public var postWidth: Float?

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
        /// When the flame reached each point on the line through the ignition point along the vent's
        /// axis, 1.4 m above the floor (where Bauwens et al.'s thermocouples were), every half metre:
        /// the distance from the ignition point, positive towards the vent, and the time, s, at
        /// which the share of the cloud's gas still unburnt there first fell below a half. Points the
        /// flame never reached are left out.
        public var arrivals: [(position: Double, time: Double)]

        /// The flame's speed between neighbouring points of `arrivals`, at their midpoint: (m, m/s),
        /// negative towards the back wall, as Bauwens et al. plot theirs.
        public var flameSpeeds: [(position: Double, speed: Double)] {
            zip(arrivals, arrivals.dropFirst()).compactMap { a, b in
                let dt = b.time - a.time
                let dx = b.position - a.position
                guard dt != 0, a.position * b.position > 0 else { return nil }
                // Away from the ignition point on either side: the later point is the farther.
                let speed = abs(dx / dt) * (a.position + b.position < 0 ? -1 : 1)
                return ((a.position + b.position) / 2, speed)
            }
        }
    }

    /// The points `Result.arrivals` follows: their distances from the ignition point and positions.
    func arrivalProbes(_ scenario: Scenario) -> [(distance: Double, point: SIMD3<Float>)] {
        let ignition = scenario.deflagration?.ignition ?? .zero
        let spacing: Float = 0.5
        var probes: [(Double, SIMD3<Float>)] = []
        let first = Int((-ignition.x / spacing).rounded(.up))
        let last = Int(((scenario.domainSize.x - ignition.x) / spacing).rounded(.down))
        for n in first...last where n != 0 {
            let point = SIMD3(ignition.x + Float(n) * spacing, ignition.y, 1.4)
            guard point.x > 0, point.x < scenario.domainSize.x else { continue }
            probes.append((Double(Float(n) * spacing), point))
        }
        return probes
    }

    /// The scenario: the room's walls as blocks, the vent's cover as a panel, the room full of
    /// mixture and gauges at the middle of the back wall, the room's middle and outside.
    public func scenario() -> Scenario {
        // Air all round the room, and more beyond the vent: vented gas that reaches an open face of the
        // domain can flow back in through it (the faces copy the cell inside them), and burnt gas
        // drawn back in has pressurised a whole domain whose room stood against its face.
        let t = wallThickness
        let margin: Float = 2
        let outside: Float = 5
        let side = ventArea.squareRoot()
        let size = SIMD3(
            margin + t + room.x + t + outside, margin + t + room.y + t + margin, room.z + t + margin)
        let x0 = margin + t
        let y0 = margin + t
        let x1 = x0 + room.x
        let y1 = y0 + room.y
        let z1 = room.z
        var blocks = [
            Box(min: SIMD3(x0 - t, y0 - t, 0), max: SIMD3(x0, y1 + t, z1 + t)),  // back wall
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
        if let width = postWidth {
            let across = Int((room.x - 0.5) / 1)
            let along = Int((room.y - 0.5) / 1)
            for a in 0...across {
                for b in 0...along {
                    let x = middle.x + (Float(a) - Float(across) / 2)
                    let y = middle.y + (Float(b) - Float(along) / 2)
                    guard simd_distance(SIMD2(x, y), SIMD2(lit.x, lit.y)) > 0.5 + width / 2 else { continue }
                    let half = width / 2
                    blocks.append(Box(min: SIMD3(x - half, y - half, 0), max: SIMD3(x + half, y + half, z1)))
                }
            }
        }
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

    public func run(
        device: MTLDevice, progress: ((Double, Double) -> Void)? = nil,
        inspect: ((BlastSolver) -> Void)? = nil, monitor: ((BlastSolver) -> Void)? = nil
    ) throws -> Result {
        let scenario = scenario()
        var configuration = SolverConfiguration()
        configuration.airModel = airModel
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
