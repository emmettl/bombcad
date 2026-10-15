import Foundation
import Metal
import simd

/// Where a brick wall's debris lands: R. A. Keys, *Experimental & computational structural
/// analysis of masonry panels subject to long duration blast loading*, PhD thesis, University
/// of Southampton, 2016 (eprint 413951), and R. Keys and S. K. Clubley, *Engineering Structures*
/// 130 (2017) 229–241. Single-leaf walls of solid brick in running bond, 1 m long, 2 m high and
/// one brick (102.5 mm) thick, "A panels", each brick numbered and the debris collected and
/// weighed over a 0.5 m grid round the wall. The masses here were read from the thesis's
/// longitudinal histograms (Figures 4.17c, 4.20c, 4.22c and 4.30c) by `Scripts/keys2016`; the
/// trial data themselves are the UK Ministry of Defence's. See `Fixtures/Keys2016`.
///
/// The Windrush Arena trials put the walls on radials from 41 kg of TNT on the ground at MoD
/// Shoeburyness, side-on to them. The thesis's long-duration trials in the Air Blast Tunnel,
/// whose walls were thrown 5 to 50 m by the drag behind the shock, are in the fixture but not
/// run: the model cannot load debris with a planar long-duration wave (see docs/validation.md).
public enum MasonryDebrisTests {
    /// One wall: where it stood, the blast measured beside it, and the debris mass in 0.5 m bins
    /// from `firstBin` metres downstream of its upstream face (negative is towards the charge).
    public struct Trial: Sendable {
        public var id: String
        public var standoff: Float
        /// The peak side-on overpressure (Pa) and positive impulse (Pa s) the thesis gives as
        /// recorded at this radius (Tables 5.1 and 5.2): the trials' gauges were on the ground.
        public var measuredPeak: Float
        public var measuredImpulse: Float
        public var firstBin: Float
        public var masses: [Float]
        public var note: String = ""
    }

    public static let binWidth: Float = 0.5

    /// WR1A, WR1B and WR2C; WR1C, rebuilt a week before firing in weaker mortar, is kept but
    /// not compared (WR2C repeated it). Readings under 1 kg (two pixels) are taken as zero.
    public static let trials: [Trial] = [
        Trial(
            id: "WR1A", standoff: 10.6, measuredPeak: 115.1e3, measuredImpulse: 263.1, firstBin: -2,
            masses: [0, 3.9, 39.9, 104.0, 100.1, 44.2, 26.0, 13.9, 6.1, 3.9, 0, 0]),
        Trial(
            id: "WR1B", standoff: 13, measuredPeak: 73.1e3, measuredImpulse: 240.8, firstBin: -2,
            masses: [0, 2.5, 42.4, 104.5, 52.4, 48.3, 46.2, 30.2, 10.5, 8.4, 8.4, 8.4, 4.2, 0, 0, 2.5]),
        Trial(
            id: "WR2C", standoff: 15, measuredPeak: 53.2e3, measuredImpulse: 234.4, firstBin: -2,
            masses: [0, 8.2, 42.2, 102.2, 76.3, 66.0, 48.3, 38.0, 8.2, 4.3, 2.1, 0]),
        Trial(
            id: "WR1C", standoff: 15, measuredPeak: 53.2e3, measuredImpulse: 234.4, firstBin: -4,
            masses: [0, 2.0, 2.0, 8.1, 20.2, 31.9, 70.3, 71.9, 64.2, 52.1, 20.2, 8.1, 6.1, 0, 0],
            note: "rebuilt a week before firing; weaker mortar"),
    ]

    /// Mass-weighted statistics of debris in 0.5 m bins: the mean distance, the median and 90th
    /// percentile bins' centres, and the far end of the furthest bin holding at least `floor`.
    public struct Spread: Sendable, CustomStringConvertible {
        public var total: Float
        public var mean: Float
        public var median: Float
        public var p90: Float
        public var furthest: Float

        public init(
            firstBin: Float, masses: [Float], width: Float = MasonryDebrisTests.binWidth, floor: Float = 1
        ) {
            let centres = masses.indices.map { firstBin + (Float($0) + 0.5) * width }
            let sum = masses.reduce(0, +)
            total = sum
            mean = sum > 0 ? zip(centres, masses).reduce(0) { $0 + $1.0 * $1.1 } / sum : 0
            func quantile(_ q: Float) -> Float {
                var running: Float = 0
                for (centre, mass) in zip(centres, masses) {
                    running += mass
                    if running >= q * sum { return centre }
                }
                return centres.last ?? 0
            }
            median = quantile(0.5)
            p90 = quantile(0.9)
            let last = masses.lastIndex { $0 >= floor } ?? 0
            furthest = firstBin + Float(last + 1) * width
        }

        public var description: String {
            String(
                format: "%5.0f kg, mean %5.2f m, median %5.2f m, 90%% within %5.2f m, furthest %4.1f m",
                total,
                mean, median, p90, furthest)
        }
    }

    public struct Result: Sendable {
        public var trial: Trial
        public var firstBin: Float
        public var masses: [Float]
        /// The model's side-on peak and positive impulse on the ground at the wall's radius, 3 m
        /// to one side of it.
        public var gaugePeak: Float = 0
        public var gaugeImpulse: Float = 0
        /// When everything had come to rest (the fastest node under `restSpeed`), or the time
        /// limit.
        public var settled: Double = 0
        public var summary = StructureSummary()
        public var elementSize: Float = 0
        public var wallSeconds: Double = 0
        /// When the wave reached the face (s), and the bed joints open by 0.1 mm across at least
        /// half the wall at 5, 10, 20, 50, 100 and 200 ms after that.
        public var arrival: Float = 0
        public var crackHistory: [(time: Double, heights: [Float])] = []
        /// The pieces it ended in (`pieces`), heaviest first, kg.
        public var pieces: [Float] = []

        public var spread: Spread { Spread(firstBin: firstBin, masses: masses) }
        public var measuredSpread: Spread { Spread(firstBin: trial.firstBin, masses: trial.masses) }
    }

    /// The wall as built: a brick and its joint are 225 by 75 mm on face, so 37.5 mm elements
    /// give two to a course and six to a brick, and the wall is three elements (112.5 mm) thick
    /// rather than 102.5 mm, its density reduced to keep its mass (1 × 2 × 0.1025 m at
    /// 1900 kg/m³, 390 kg; the trials collected 340 to 400 kg). On a mortar bed: the joints' own
    /// bond, cohesion and friction (the thesis does not say what the walls stood on).
    public static func wall(
        at front: SIMD3<Float>, elementSize h: Float = 0.0375, base: Anchorage? = mortarBed
    ) -> StructureModel {
        let length = (1 / h).rounded() * h
        let height = (2 / h).rounded() * h
        let thickness = (0.1025 / h).rounded() * h
        let box = Box(min: front, max: front + SIMD3(thickness, length, height))
        var material = StructureMaterial.masonry
        material.name = "Brickwork (Keys)"
        material.density = 1900 * (1 * 2 * 0.1025) / (length * height * thickness)
        var model = StructureModel(solids: [box], material: material, elementSize: h, fixedBase: true)
        model.baseAnchorage = base
        return model
    }

    /// A mortar bed with the brickwork's own joints' bond, cohesion and friction.
    public static let mortarBed: Anchorage = {
        let units = MasonryUnits.brick
        return Anchorage(
            tensileStrength: units.bondStrength,
            tensionOpening: 2 * units.bondFractureEnergy / units.bondStrength,
            cohesion: units.cohesion, cohesionSlip: 2 * units.shearFractureEnergy / units.cohesion,
            friction: units.friction)
    }()

    /// Runs `trial`: the wall `trial.standoff` metres from 41 kg of TNT on the ground, the air on
    /// cells of `cellSize`, until the debris has come to rest (its fastest node under
    /// `restSpeed`, after at least `minimum` seconds) or `duration` seconds. The debris is binned
    /// as the trial's was, by where each node of the mesh ends up along the radial, from the
    /// wall's upstream face; its whole mass is counted, broken off or not.
    public static func run(
        device: MTLDevice, trial: Trial, cellSize: Float = 0.1, elementSize: Float = 0.0375,
        duration: Double = 3, minimum: Double = 0.6, restSpeed: Float = 0.05, airSleepThreshold: Float = 5e-4,
        clearance: Float = 8, height: Float = 10, groundFriction: Float = 0.6, base: Anchorage? = mortarBed,
        afterburning: Bool = false, groundStiffness: Float = 0, progress: ((String) -> Void)? = nil
    ) throws -> Result {
        let started = ContinuousClock.now
        // The air's open faces must be well clear: with 1.5 m behind the charge, 3.5 m either
        // side and 5 m up, the air drained out through them and stayed 15 to 20 kPa below
        // ambient for as long as it was run, a little lower before the wall than behind it, which
        // threw the wall towards the charge (as the anchorage study's walls were; see
        // docs/structural-model.md).
        let margin = clearance
        let behind = clearance
        let width = 1 + 2 * clearance
        let front = margin + trial.standoff
        let model = wall(at: SIMD3(front, width / 2 - 0.5, 0), elementSize: elementSize, base: base)
        let bounds = model.bounds
        let middle = width / 2
        let charge = SIMD3<Float>(margin, middle, 0)
        // A gauge on the ground at the wall's radius, 3 m to one side, clear of its reflection.
        let side = SIMD3<Float>(trial.standoff, 3, 0)
        let gauge = charge + simd_normalize(side) * trial.standoff + SIMD3(0, 0, 0.5 * cellSize)
        let scenario = Scenario(
            name: "Keys \(trial.id)", domainSize: SIMD3(front + behind, width, height), boxes: [],
            charge: Charge(mass: 41, position: charge),
            gauges: [
                Gauge("Free field", at: gauge),
                Gauge("Face", at: SIMD3(bounds.min.x - 0.5 * cellSize, middle, 1)),
                Gauge("Back", at: SIMD3(bounds.max.x + 0.5 * cellSize, middle, 1)),
            ],
            structure: model)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        solver.configuration.mappedCharge = !afterburning
        solver.configuration.afterburning = afterburning
        // A free-standing brick wall resists only about 0.1 kPa of overturning pressure, so the
        // air is kept going until it is within 50 Pa of ambient everywhere (not the default
        // 2 kPa, or five crossings of the domain): frozen any sooner, what is left of the blast
        // against the wall pushes it over towards the charge.
        solver.configuration.airSleepThreshold = airSleepThreshold
        solver.configuration.airSleepCrossings = 0
        try solver.load(scenario)
        guard let structure = solver.structure else { throw BlastError.allocationFailed("structure") }
        // Coulomb friction on the ground: with the default decay the toppled walls crept on at
        // 0.3 to 0.7 m/s for seconds (docs/structural-model.md#on-the-ground).
        structure.groundFrictionCoefficient = groundFriction
        structure.groundStiffness = groundStiffness

        func fastest() -> Float {
            var speed: Float = 0
            structure.mutateNodes { nodes in
                for node in nodes where node.mass > 0 { speed = max(speed, simd_length(node.velocity)) }
            }
            return speed
        }
        var result = Result(trial: trial, firstBin: -4, masses: [])
        result.elementSize = structure.model.elementSize
        var nextReport = 0.05
        var nextCheck = minimum
        var crackTimes: [Double] = [0.005, 0.01, 0.02, 0.05, 0.1, 0.2]
        while solver.time < duration {
            let batch = solver.advance(steps: 32, timeLimit: duration)
            if batch.steps == 0 && !solver.airIsAsleep { break }
            // Times are from the charge's detonation; the wave reaches the wall some ms later.
            if let next = crackTimes.first, solver.time >= next + Double(result.arrival) {
                crackTimes.removeFirst()
                result.crackHistory.append((next, openBedJoints(structure, width: 0.1e-3)))
            }
            if result.arrival == 0, let face = solver.gaugeHistories.dropFirst().first,
                let last = face.last, last.pressure > scenario.atmosphere.pressure + 5e3
            {
                result.arrival = Float(last.time)
            }
            if solver.time >= nextCheck {
                nextCheck += 0.05
                if fastest() < restSpeed { break }
            }
            if let progress, solver.time >= nextReport {
                nextReport += 0.05
                var mass: Float = 0
                var moment = SIMD3<Float>.zero
                var kinetic: Float = 0
                structure.mutateNodes { nodes in
                    for k in 0...structure.ez {
                        for j in 0...structure.ey {
                            for i in 0...structure.ex {
                                guard let n = structure.storedNode(i, j, k), nodes[n].mass > 0 else {
                                    continue
                                }
                                let node = nodes[n]
                                mass += node.mass
                                moment +=
                                    node.mass * (structure.referencePosition(i, j, k) + node.displacement)
                                kinetic += 0.5 * node.mass * simd_length_squared(node.velocity)
                            }
                        }
                    }
                }
                let centre = moment / max(mass, 1e-9) - SIMD3(bounds.min.x, bounds.min.y, 0)
                let ambient = scenario.atmosphere.pressure
                let faces = solver.gaugeHistories.dropFirst().map { ($0.last?.pressure ?? ambient) - ambient }
                progress(
                    String(
                        format:
                            "%5.0f ms: fastest node %6.2f m/s, centre x %6.2f z %5.2f m, %7.1f J, %d eroded; face %6.0f Pa, back %6.0f Pa%@",
                        solver.time * 1000, fastest(), centre.x, centre.z, kinetic,
                        structure.summary().erodedElements, faces.first ?? 0, faces.last ?? 0,
                        solver.airIsAsleep ? " (air asleep)" : ""))
            }
        }
        result.settled = solver.time

        // Bin every node's mass by where it is along the radial (the x axis here), from the
        // upstream face; 0.5 m bins from 4 m in front of the wall to 8 m behind it, the first
        // and last holding anything beyond.
        var masses = [Float](repeating: 0, count: 24)
        let face = bounds.min.x
        structure.mutateNodes { nodes in
            for k in 0...structure.ez {
                for j in 0...structure.ey {
                    for i in 0...structure.ex {
                        guard let n = structure.storedNode(i, j, k), nodes[n].mass > 0 else { continue }
                        let x = structure.referencePosition(i, j, k).x + nodes[n].ux - face
                        let bin = Int(((x - result.firstBin) / binWidth).rounded(.down))
                        masses[min(max(bin, 0), masses.count - 1)] += nodes[n].mass
                    }
                }
            }
        }
        result.masses = masses
        result.pieces = pieces(structure)

        let ambient = scenario.atmosphere.pressure
        let samples = solver.gaugeHistories.first ?? []
        result.gaugePeak = (samples.map(\.pressure).max() ?? ambient) - ambient
        result.gaugeImpulse = zip(samples, samples.dropFirst()).reduce(0) {
            $0 + Float($1.1.time - $1.0.time) * max(0.5 * ($1.0.pressure + $1.1.pressure) - ambient, 0)
        }
        result.summary = structure.summary()
        let elapsed = ContinuousClock.now - started
        result.wallSeconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        return result
    }
}

extension MasonryDebrisTests {
    /// The pieces the body has broken into: its intact elements, joined to each neighbour beyond
    /// them along an axis unless they have opened by more than `opening` (m) on the plane across
    /// that axis. An element holding an open joint so goes with the piece on its near side,
    /// rather than counting as a piece of its own. The mass of each piece (kg), largest first.
    public static func pieces(_ structure: StructureSolver, opening: Float = 1e-3) -> [Float] {
        let (ex, ey, ez) = (structure.ex, structure.ey, structure.ez)
        let h = structure.model.elementSize
        let elementMass = structure.model.material.density * h * h * h
        var parent = [Int](repeating: -1, count: ex * ey * ez)
        var opened = [[Bool]](repeating: [false, false, false], count: ex * ey * ez)
        for k in 0..<ez {
            for j in 0..<ey {
                for i in 0..<ex where structure.flag(i, j, k) == .active {
                    let index = structure.elementIndex(i, j, k)
                    parent[index] = index
                    let planes = structure.crackPlanes(i, j, k)
                    var open = [false, false, false]
                    for p in planes.normals.indices where planes.history[p] * h > opening {
                        for axis in 0..<3 where abs(planes.normals[p][axis]) > 0.7 { open[axis] = true }
                    }
                    opened[index] = open
                }
            }
        }
        func root(_ a: Int) -> Int {
            var a = a
            while parent[a] != a {
                parent[a] = parent[parent[a]]
                a = parent[a]
            }
            return a
        }
        for k in 0..<ez {
            for j in 0..<ey {
                for i in 0..<ex {
                    let a = structure.elementIndex(i, j, k)
                    guard parent[a] >= 0 else { continue }
                    for (axis, b) in [
                        (0, i + 1 < ex ? a + 1 : -1), (1, j + 1 < ey ? a + ex : -1),
                        (2, k + 1 < ez ? a + ex * ey : -1),
                    ]
                    where b >= 0 && parent[b] >= 0 && !opened[a][axis] {
                        parent[root(a)] = root(b)
                    }
                }
            }
        }
        var masses: [Int: Float] = [:]
        for a in parent.indices where parent[a] >= 0 { masses[root(a), default: 0] += elementMass }
        return masses.values.sorted(by: >)
    }

    /// Heights (m above the base, the middle of the element row) of the rows of elements cracked
    /// open on a horizontal plane by more than `width`, or removed, across at least half the
    /// wall: the bed joints that have opened.
    public static func openBedJoints(_ structure: StructureSolver, width: Float) -> [Float] {
        let h = structure.model.elementSize
        var heights: [Float] = []
        for k in 0..<structure.ez {
            var open = 0
            var count = 0
            for j in 0..<structure.ey {
                for i in 0..<structure.ex where structure.flag(i, j, k) != .empty {
                    count += 1
                    let planes = structure.crackPlanes(i, j, k)
                    let opened = planes.normals.indices.contains { p in
                        abs(planes.normals[p].z) > 0.7 && planes.history[p] * h > width
                    }
                    if opened || structure.flag(i, j, k) == .eroded { open += 1 }
                }
            }
            if count > 0, open * 2 >= count { heights.append((Float(k) + 0.5) * h) }
        }
        return heights
    }
}

extension MasonryDebrisTests {
    /// The wall alone, without air: its top half set swinging downstream at `push` m/s about
    /// the base (a rigid rotation), then left to gravity for `duration` seconds. Reports, every
    /// 50 ms, the centre of mass from the upstream face and the kinetic energy, to check that
    /// the wall and its base neither drift nor gain energy by themselves.
    public static func runAlone(
        device: MTLDevice, push: Float, duration: Double = 1, elementSize: Float = 0.0375,
        anchored: Bool = true, free: Bool = false, contact: Bool = true, joints: Bool = true,
        hourglass: Float? = nil, groundFriction: Float = 0.6, progress: (String) -> Void
    ) throws {
        var model = wall(at: SIMD3(1, 1, 0), elementSize: elementSize)
        model.unitJoints = joints
        if !anchored { model.baseAnchorage = .resting(friction: MasonryUnits.brick.friction) }
        if free {
            model.fixedBase = false
            model.baseAnchorage = nil
        }
        let structure = try StructureSolver(device: device, model: model)
        if !contact { structure.contactMode = .off }
        if let hourglass { structure.hourglassCoefficient = hourglass }
        structure.groundFrictionCoefficient = groundFriction
        let face = model.bounds.min.x
        let height = model.bounds.max.z
        structure.mutateNodes { nodes in
            for k in 0...structure.ez {
                for j in 0...structure.ey {
                    for i in 0...structure.ex {
                        guard let n = structure.storedNode(i, j, k) else { continue }
                        let z = structure.referencePosition(i, j, k).z
                        nodes[n].vx = push * z / height
                    }
                }
            }
        }
        let steps = max(1, Int((0.05 / Double(structure.criticalTimeStep)).rounded()))
        var time = 0.0
        while time < duration {
            structure.advance(steps: steps)
            time += Double(steps) * Double(structure.criticalTimeStep)
            var mass: Float = 0
            var moment = SIMD3<Float>.zero
            var kinetic: Float = 0
            structure.mutateNodes { nodes in
                for k in 0...structure.ez {
                    for j in 0...structure.ey {
                        for i in 0...structure.ex {
                            guard let n = structure.storedNode(i, j, k), nodes[n].mass > 0 else { continue }
                            mass += nodes[n].mass
                            moment +=
                                nodes[n].mass * (structure.referencePosition(i, j, k) + nodes[n].displacement)
                            kinetic += 0.5 * nodes[n].mass * simd_length_squared(nodes[n].velocity)
                        }
                    }
                }
            }
            let centre = moment / max(mass, 1e-9)
            // Where the motion is: nodes faster than 1 m/s, their mass and mean height; the mean
            // x speed of nodes on the ground and of the rest; and the share of the mass that is
            // loose (no element of its eight intact).
            var fastMass: Float = 0
            var fastHeight: Float = 0
            var ground = SIMD2<Float>.zero
            var above = SIMD2<Float>.zero
            var looseMass: Float = 0
            structure.mutateNodes { nodes in
                for k in 0...structure.ez {
                    for j in 0...structure.ey {
                        for i in 0...structure.ex {
                            guard let n = structure.storedNode(i, j, k), nodes[n].mass > 0 else { continue }
                            let node = nodes[n]
                            let z = structure.referencePosition(i, j, k).z + node.displacement.z
                            if simd_length(node.velocity) > 1 {
                                fastMass += node.mass
                                fastHeight += node.mass * z
                            }
                            if z < 0.005 {
                                ground += SIMD2(node.mass * node.vx, node.mass)
                            } else {
                                above += SIMD2(node.mass * node.vx, node.mass)
                            }
                            var intact = false
                            for c in 0..<8 {
                                let (a, b, d) = (i - (c & 1), j - ((c >> 1) & 1), k - ((c >> 2) & 1))
                                guard a >= 0, b >= 0, d >= 0, a < structure.ex, b < structure.ey,
                                    d < structure.ez
                                else { continue }
                                if structure.flag(a, b, d) == .active { intact = true }
                            }
                            if !intact { looseMass += node.mass }
                        }
                    }
                }
            }
            progress(
                String(
                    format:
                        "         fast %5.1f kg at z %5.2f m; vx on ground %5.2f (%5.1f kg), above %5.2f m/s; loose %5.1f kg; px %7.2f N s, friction %7.1f N",
                    fastMass, fastMass > 0 ? fastHeight / fastMass : 0, ground.x / max(ground.y, 1e-9),
                    ground.y,
                    above.x / max(above.y, 1e-9), looseMass, Float(structure.momentum().x), 8 * ground.x))
            progress(
                String(
                    format: "%5.0f ms: centre x %6.3f z %6.3f m, %8.2f J, %d eroded", time * 1000,
                    centre.x - face,
                    centre.z, kinetic, structure.summary().erodedElements))
        }
    }
}

extension MasonryDebrisTests {
    /// A slab of the brickwork, 1 m square and three elements thick, lying free on the ground and
    /// set sliding at `speed` m/s: reports its mean speed every 50 ms, to check that the ground
    /// stops what slides on it.
    public static func runSlide(
        device: MTLDevice, speed: Float, duration: Double = 1, elementSize h: Float = 0.0375,
        groundFriction: Float = 0.6, progress: (String) -> Void
    ) throws {
        let box = Box(min: SIMD3(1, 1, 0), max: SIMD3(1 + 27 * h, 1 + 27 * h, 3 * h))
        var material = StructureMaterial.masonry
        material.units = nil
        let model = StructureModel(solids: [box], material: material, elementSize: h, fixedBase: false)
        let structure = try StructureSolver(device: device, model: model)
        structure.groundFrictionCoefficient = groundFriction
        structure.mutateNodes { nodes in
            for n in nodes.indices { nodes[n].vx = speed }
        }
        let steps = max(1, Int((0.05 / Double(structure.criticalTimeStep)).rounded()))
        var time = 0.0
        while time < duration {
            structure.advance(steps: steps)
            time += Double(steps) * Double(structure.criticalTimeStep)
            let momentum = structure.momentum()
            var mass: Float = 0
            structure.mutateNodes { nodes in for node in nodes { mass += node.mass } }
            progress(String(format: "%5.0f ms: mean vx %6.3f m/s", time * 1000, Float(momentum.x) / mass))
        }
    }
}

// MARK: - The Air Blast Tunnel

extension MasonryDebrisTests {
    /// A wall in the Air Blast Tunnel at MoD Shoeburyness, a shock tube giving about 110 kPa for
    /// 210 ms in its 4.9 m section and 55–60 kPa for 150–180 ms in its 10.2 m section. Keys and
    /// Clubley's table 1 gives the measured incident overpressure, positive phase and impulse
    /// (`Fixtures/Keys2016/panels.json`); the debris, in `bin` m bins from the wall's upstream
    /// face, is read off the thesis's figures 4.39, 4.58c and 4.73c (`debris.json`).
    public struct TunnelTrial: Sendable {
        public var id: String
        /// Across the tunnel (m): one A panel, or two side by side.
        public var width: Float
        public var overpressure: Float
        public var duration: Float
        public var impulse: Float
        /// Bed joints the paper saw open at 50 ms (m above the base).
        public var crackHeights: [Float]
        public var bin: Float
        public var masses: [Float]
    }

    public static let tunnelTrials: [TunnelTrial] = [
        TunnelTrial(
            id: "BWL1A", width: 1, overpressure: 100e3, duration: 0.214, impulse: 7260,
            crackHeights: [0.3, 0.5, 1.6],
            bin: 1,
            masses: [
                1, 1, 1, 1, 1, 3, 1, 7, 1, 5, 2, 1, 5, 13, 8, 11, 3, 5, 6, 20, 2, 2, 14, 4, 10, 8, 13, 26, 27,
                13, 43, 48, 31, 9, 3, 7, 4, 7, 3, 3, 2, 3, 4, 6, 1, 3, 3, 1, 3, 1,
            ]),
        TunnelTrial(
            id: "BWL2C", width: 1, overpressure: 60e3, duration: 0.179, impulse: 3952,
            crackHeights: [0.5, 1.5], bin: 0.5,
            masses: [
                0, 0, 0, 0, 9.9, 3.9, 19.5, 13.8, 16.7, 49.3, 14.6, 5.7, 9.9, 67, 64.1, 54.2, 11.7, 5.7, 5, 0,
                5, 5, 0, 0, 1.8, 2.9, 0, 0,
            ]),
        TunnelTrial(
            id: "BWL3B", width: 2, overpressure: 57e3, duration: 0.152, impulse: 3362, crackHeights: [],
            bin: 0.5,
            masses: [
                3, 2, 95, 30.9, 7.2, 29.9, 26, 27.9, 59.8, 20.1, 37.2, 16.1, 38.1, 56.9, 93, 48, 44.1, 20.1,
                23, 15.1, 7.2, 10.2, 2, 6.2, 10.2, 6.2, 1, 7.2, 3, 19.1,
            ]),
    ]

    /// The Friedlander decay constant b for which a wave of `peak` and `duration` carries
    /// `impulse`: I = p t+ (1/b − (1 − e^−b)/b²).
    public static func decay(peak: Float, duration: Float, impulse: Float) -> Float {
        let target = impulse / (peak * duration)
        var low: Float = 0.01
        var high: Float = 20
        for _ in 0..<60 {
            let b = 0.5 * (low + high)
            let share = 1 / b - (1 - exp(-b)) / (b * b)
            if share > target { low = b } else { high = b }
        }
        return 0.5 * (low + high)
    }

    /// The air entering the tunnel `t` seconds after the shock: the measured incident
    /// overpressure's Friedlander curve, the shock's jump by the Rankine–Hugoniot relations, and
    /// behind it a simple wave (isentropic, the Riemann invariant along the backward
    /// characteristics kept). Past the negative phase's depth, or 30% of the peak, the curve is
    /// held at its least.
    public static func inflow(
        _ trial: TunnelTrial, at t: Float, ambient: Float = 101_325, density: Float = 1.225
    )
        -> Primitive
    {
        let gamma: Float = 1.4
        let c0 = (gamma * ambient / density).squareRoot()
        let ps = ambient + trial.overpressure
        let mach = (1 + (gamma + 1) / (2 * gamma) * (ps / ambient - 1)).squareRoot()
        let rhos = density * (gamma + 1) * mach * mach / ((gamma - 1) * mach * mach + 2)
        let us = 2 * c0 / (gamma + 1) * (mach - 1 / mach)
        let cs = (gamma * ps / rhos).squareRoot()
        let b = decay(peak: trial.overpressure, duration: trial.duration, impulse: trial.impulse)
        let s = max(t, 0) / trial.duration
        let f = max((1 - s) * exp(-b * s), -0.3)
        let p = max(ambient + trial.overpressure * f, 0.2 * ambient)
        let rho = rhos * pow(p / ps, 1 / gamma)
        let c = (gamma * p / rho).squareRoot()
        let u = us + 2 / (gamma - 1) * (c - cs)
        return Primitive(density: rho, velocity: SIMD3(u, 0, 0), pressure: p)
    }

    public struct TunnelResult: Sendable {
        public var trial: TunnelTrial
        /// Mass (kg) by where it lay at the end, in `trial.bin` bins from the upstream face, the
        /// first holding anything upstream of it and the last anything beyond.
        public var masses: [Float]
        public var incidentPeak: Float = 0
        public var incidentImpulse: Float = 0
        public var facePeak: Float = 0
        /// Bed joints open across half the wall's width at 50 ms (m above the base).
        public var crackHeights: [Float] = []
        /// The pieces it ended in (`pieces`), heaviest first, kg.
        public var pieces: [Float] = []
        public var settled: Double = 0
        public var summary = StructureSummary()
        public var wallSeconds: Double = 0

        public var spread: Spread { Spread(firstBin: 0, masses: masses, width: trial.bin) }
        public var measuredSpread: Spread { Spread(firstBin: 0, masses: trial.masses, width: trial.bin) }
    }

    /// Runs `trial`: the tunnel as a box `tunnelWidth` by `tunnelHeight` with reflecting walls,
    /// floor and roof, the wall `upstream` metres in from the inlet and `downstream` metres of
    /// tunnel behind it, open at its far end; the measured wave written into the two cell layers
    /// at the inlet every eight air steps (after the draft by the close-in breach session). The
    /// air loads the debris all the way down the tunnel, and the ground holds it back by Coulomb
    /// friction; the wall stands on a mortar bed, as the paper's were mortared to the floor.
    public static func runTunnel(
        device: MTLDevice, trial: TunnelTrial, cellSize: Float = 0.1, elementSize: Float = 0.0375,
        duration: Double = 2, upstream: Float = 2, downstream: Float = 14, tunnelWidth: Float = 8,
        tunnelHeight: Float = 6, groundFriction: Float = 0.6, minimum: Double = 0.8, restSpeed: Float = 0.05,
        groundStiffness: Float = 0, progress: ((String) -> Void)? = nil
    ) throws -> TunnelResult {
        let started = ContinuousClock.now
        let front = upstream
        var model = wall(at: SIMD3(front, (tunnelWidth - trial.width) / 2, 0), elementSize: elementSize)
        if trial.width != 1 {
            let h = model.elementSize
            let length = (trial.width / h).rounded() * h
            let box = model.solids[0]
            model.solids[0] = Box(min: box.min, max: SIMD3(box.max.x, box.min.y + length, box.max.z))
            model.material.density *= 1 / (length / ((1 / h).rounded() * h)) * trial.width
        }
        let bounds = model.bounds
        let middle = tunnelWidth / 2
        var scenario = Scenario(
            name: "Keys \(trial.id)", domainSize: SIMD3(upstream + downstream, tunnelWidth, tunnelHeight),
            boxes: [],
            charge: Charge(mass: 0, position: SIMD3(0.5, 0.5, 0.5)),
            gauges: [
                Gauge("Incident, by the inlet", at: SIMD3(0.3, middle, 1)),
                Gauge("Face", at: SIMD3(bounds.min.x - 0.5 * cellSize, middle, 1)),
            ],
            structure: model)
        scenario.reflectiveFaces = [.yMin, .yMax, .zMin, .zMax]
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        solver.configuration.skipStillAir = false
        solver.configuration.mappedCharge = false
        solver.configuration.airSleepThreshold = 0
        solver.configuration.airSleepCrossings = 0
        solver.configuration.debrisReach = SIMD3(downstream, tunnelWidth, tunnelHeight)
        try solver.load(scenario)
        guard let structure = solver.structure else { throw BlastError.allocationFailed("structure") }
        structure.groundFrictionCoefficient = groundFriction
        structure.groundStiffness = groundStiffness
        let grid = solver.grid
        func drive() {
            let cell = solver.cellState(inflow(trial, at: Float(solver.time)))
            solver.editState { cells in
                for k in 0..<grid.nz {
                    for j in 0..<grid.ny {
                        for i in 0..<2 { cells[grid.index(i, j, k)] = cell }
                    }
                }
            }
        }
        func fastest() -> Float {
            var speed: Float = 0
            structure.mutateNodes { nodes in
                for node in nodes where node.mass > 0 { speed = max(speed, simd_length(node.velocity)) }
            }
            return speed
        }
        var result = TunnelResult(trial: trial, masses: [])
        var nextReport = 0.05
        var nextCheck = minimum
        var checkedCracks = false
        drive()
        while solver.time < duration {
            let batch = solver.advance(steps: 8, timeLimit: duration)
            if batch.steps == 0 && !solver.airIsAsleep { break }
            drive()
            if !checkedCracks, solver.time >= 0.05 {
                checkedCracks = true
                result.crackHeights = openBedJoints(structure, width: 1e-3)
            }
            if solver.time >= nextCheck {
                nextCheck += 0.05
                if fastest() < restSpeed { break }
            }
            if let progress, solver.time >= nextReport {
                nextReport += 0.05
                var mass: Float = 0
                var moment = SIMD3<Float>.zero
                structure.mutateNodes { nodes in
                    for k in 0...structure.ez {
                        for j in 0...structure.ey {
                            for i in 0...structure.ex {
                                guard let n = structure.storedNode(i, j, k), nodes[n].mass > 0 else {
                                    continue
                                }
                                mass += nodes[n].mass
                                moment +=
                                    nodes[n].mass
                                    * (structure.referencePosition(i, j, k) + nodes[n].displacement)
                            }
                        }
                    }
                }
                let centre = moment / max(mass, 1e-9)
                progress(
                    String(
                        format:
                            "%5.0f ms: inlet %5.1f kPa, fastest node %5.2f m/s, centre x %6.2f z %5.2f m, %d eroded",
                        solver.time * 1000, (inflow(trial, at: Float(solver.time)).pressure - 101_325) / 1000,
                        fastest(), centre.x - front, centre.z, structure.summary().erodedElements))
            }
        }
        result.settled = solver.time
        let count = max(trial.masses.count, Int((downstream / trial.bin).rounded()))
        var masses = [Float](repeating: 0, count: count)
        structure.mutateNodes { nodes in
            for k in 0...structure.ez {
                for j in 0...structure.ey {
                    for i in 0...structure.ex {
                        guard let n = structure.storedNode(i, j, k), nodes[n].mass > 0 else { continue }
                        let x = structure.referencePosition(i, j, k).x + nodes[n].ux - front
                        let bin = Int((x / trial.bin).rounded(.down))
                        masses[min(max(bin, 0), count - 1)] += nodes[n].mass
                    }
                }
            }
        }
        result.masses = masses
        result.pieces = pieces(structure)
        let ambient = scenario.atmosphere.pressure
        let incident = solver.gaugeHistories.first ?? []
        result.incidentPeak = (incident.map(\.pressure).max() ?? ambient) - ambient
        result.incidentImpulse = zip(incident, incident.dropFirst()).reduce(0) {
            $0 + Float($1.1.time - $1.0.time) * max(0.5 * ($1.0.pressure + $1.1.pressure) - ambient, 0)
        }
        result.facePeak =
            ((solver.gaugeHistories.dropFirst().first ?? []).map(\.pressure).max() ?? ambient) - ambient
        result.summary = structure.summary()
        let elapsed = ContinuousClock.now - started
        result.wallSeconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        return result
    }
}
