import Foundation
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

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            cellSize: Float,
            volume: Double,
            effectiveRadius: Double,
            times: [Double],
            pressures: [Double],
            initialPressure: Double,
            modelAICC: Double,
            peakPressure: Double,
            peakTime: Double,
            peakRate: Double,
            deflagrationIndex: Double,
            burntFraction: Double,
            reference: ClosedVesselHistory,
            referenceIndex: Double,
            energyError: Double,
            burningVelocity: Double,
            halfRise: Double,
            mostRise: Double,
            referenceHalfRise: Double,
            referenceMostRise: Double
        ) {
            self.cellSize = cellSize
            self.volume = volume
            self.effectiveRadius = effectiveRadius
            self.times = times
            self.pressures = pressures
            self.initialPressure = initialPressure
            self.modelAICC = modelAICC
            self.peakPressure = peakPressure
            self.peakTime = peakTime
            self.peakRate = peakRate
            self.deflagrationIndex = deflagrationIndex
            self.burntFraction = burntFraction
            self.reference = reference
            self.referenceIndex = referenceIndex
            self.energyError = energyError
            self.burningVelocity = burningVelocity
            self.halfRise = halfRise
            self.mostRise = mostRise
            self.referenceHalfRise = referenceHalfRise
            self.referenceMostRise = referenceMostRise
        }
    }

    /// When `values` first reach `level`, interpolated between samples; nil if never.
    package static func crossing(times: [Double], values: [Double], level: Double) -> Double? {
        guard let n = values.firstIndex(where: { $0 >= level }) else { return nil }
        guard n > 0 else { return times[0] }
        let share = (level - values[n - 1]) / (values[n] - values[n - 1])
        return times[n - 1] + share * (times[n] - times[n - 1])
    }

    /// `values` averaged over `window` (s) centred on each sample.
    package static func smoothed(times: [Double], values: [Double], window: Double) -> [Double] {
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
    package static func maximumRate(times: [Double], values: [Double], window: Double) -> Double {
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
    /// The domain's open faces: ambient air beyond them (since 16 October 2026; copies of the cells
    /// inside drained the domain below ambient, which raised test 1's peak by 30% when removed).
    public var openFaces: OpenFaces = .farField
    /// The walls' and roof's thickness, m: the same at every resolution.
    public var wallThickness: Float = 0.2
    /// The longest the run may go on, s.
    public var maximumTime: Double = 4
    /// Obstacles: square posts this wide (m) from floor to ceiling, on a 1 m grid centred on the
    /// room, leaving out any within 0.5 m of the ignition point. nil for an empty room.
    public var postWidth: Float?
    /// The vent's opening in the far wall, across and up (m), centred; nil for a square of
    /// `ventArea`. The room's own cross-section opens the whole wall, as a container's doors do.
    public var ventOpening: SIMD2<Float>?
    /// Openings in the roof instead of the far wall: their centres along and across the room (m,
    /// from its back corner), each `roofOpeningSize` square. The far wall is then closed.
    public var roofOpenings: [SIMD2<Float>] = []
    public var roofOpeningSize: Float = 1
    /// How far the back-wall ignition point stands from the wall, m, and its height (nil: the
    /// room's mid-height).
    public var backWallOffset: Float = 0.25
    public var ignitionHeight: Float?
    /// The floor-centre ignition point: the middle of the floor, this high (m), for roof venting.
    public var floorIgnition: Float?
    /// Solid obstacles inside the room, in its own coordinates (m, from its back corner on the
    /// floor: along the vent's axis, across it, up), such as a frame on its floor.
    public var obstacles: [Box] = []
    /// Air above the roof, m: room for a cloud vented through the roof to burn above it.
    public var clearanceAbove: Float = 2
    /// Gravity in the air (`SolverConfiguration.gravity`), for the burnt gas's buoyancy; nil for none.
    public var gravity: AirGravity?

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

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            reducedPressure: Double,
            rawPeak: Double,
            peakTime: Double,
            ventOpened: Double? = nil,
            burntFraction: Double,
            duration: Double,
            times: [Double],
            overpressures: [Double],
            correlations: VentCorrelations,
            cellSize: Float,
            steps: Int,
            arrivals: [(position: Double, time: Double)]
        ) {
            self.reducedPressure = reducedPressure
            self.rawPeak = rawPeak
            self.peakTime = peakTime
            self.ventOpened = ventOpened
            self.burntFraction = burntFraction
            self.duration = duration
            self.times = times
            self.overpressures = overpressures
            self.correlations = correlations
            self.cellSize = cellSize
            self.steps = steps
            self.arrivals = arrivals
        }
    }

    /// The points `Result.arrivals` follows: their distances from the ignition point and positions.
    package func arrivalProbes(_ scenario: Scenario) -> [(distance: Double, point: SIMD3<Float>)] {
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
        let opening =
            ventOpening.map { simd_min($0, SIMD2(room.y, room.z)) } ?? SIMD2(repeating: ventArea.squareRoot())
        let size = SIMD3(
            margin + t + room.x + t + outside, margin + t + room.y + t + margin, room.z + t + clearanceAbove)
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
        // The vent wall, around its opening in the middle; closed when the roof vents instead.
        let vy0 = 0.5 * (y0 + y1) - 0.5 * opening.x
        let vy1 = vy0 + opening.x
        let vz0 = 0.5 * z1 - 0.5 * opening.y
        let vz1 = vz0 + opening.y
        if roofOpenings.isEmpty {
            blocks += [
                Box(min: SIMD3(x1, y0 - t, 0), max: SIMD3(x1 + t, vy0, z1 + t)),
                Box(min: SIMD3(x1, vy1, 0), max: SIMD3(x1 + t, y1 + t, z1 + t)),
                Box(min: SIMD3(x1, vy0, 0), max: SIMD3(x1 + t, vy1, vz0)),
                Box(min: SIMD3(x1, vy0, vz1), max: SIMD3(x1 + t, vy1, z1 + t)),
            ]
        } else {
            blocks.append(Box(min: SIMD3(x1, y0 - t, 0), max: SIMD3(x1 + t, y1 + t, z1 + t)))
            // The roof, cut round each opening: a box over every column of the roof the openings leave.
            blocks.removeAll { $0.min.z == z1 && $0.max.z == z1 + t && $0.min.x == x0 }
            let half = 0.5 * roofOpeningSize
            let step = cellSize
            var x = x0
            while x < x1 - 1e-4 {
                let x2 = min(x + step, x1)
                var y = y0
                while y < y1 - 1e-4 {
                    let y2 = min(y + step, y1)
                    let centre = SIMD2(0.5 * (x + x2) - x0, 0.5 * (y + y2) - y0)
                    let open = roofOpenings.contains {
                        abs(centre.x - $0.x) < half && abs(centre.y - $0.y) < half
                    }
                    if !open { blocks.append(Box(min: SIMD3(x, y, z1), max: SIMD3(x2, y2, z1 + t))) }
                    y = y2
                }
                x = x2
            }
        }
        for obstacle in obstacles {
            blocks.append(
                Box(min: obstacle.min + SIMD3(x0, y0, 0), max: obstacle.max + SIMD3(x0, y0, 0)))
        }
        let middle = SIMD3(0.5 * (x0 + x1), 0.5 * (y0 + y1), 0.5 * z1)
        var lit =
            ignition == .centre ? middle : SIMD3(x0 + backWallOffset, middle.y, ignitionHeight ?? middle.z)
        if let height = floorIgnition { lit = SIMD3(middle.x, middle.y, height) }
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
        let area =
            !roofOpenings.isEmpty
            ? Double(Float(roofOpenings.count) * roofOpeningSize * roofOpeningSize)
            : Double(ventOpening.map { min($0.x, room.y) * min($0.y, room.z) } ?? ventArea)
        var correlations = VentCorrelations(
            volume: volume, surfaceArea: surface, ventArea: area,
            releasePressure: Double(releasePressure),
            gas: gas)
        correlations.concentration = concentration
        return correlations
    }
}
