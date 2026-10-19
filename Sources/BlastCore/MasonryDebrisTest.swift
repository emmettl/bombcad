import BlastModel
import Foundation
import Metal
import simd

extension MasonryDebrisTests {
    /// Runs `trial`: the wall `trial.standoff` metres from 41 kg of TNT on the ground, the air on
    /// cells of `cellSize`, until the debris has come to rest (its fastest node under
    /// `restSpeed`, after at least `minimum` seconds) or `duration` seconds. The debris is binned
    /// as the trial's was, by where each node of the mesh ends up along the radial, from the
    /// wall's upstream face; its whole mass is counted, broken off or not.
    public static func run(
        device: MTLDevice, trial: Trial, cellSize: Float = 0.1, elementSize: Float = 0.0375,
        duration: Double = 3, minimum: Double = 0.6, restSpeed: Float = 0.05, airSleepThreshold: Float = 5e-4,
        clearance: Float = 8, height: Float = 10, groundFriction: Float = 0.6, base: Anchorage? = mortarBed,
        afterburning: Bool = SolverConfiguration.recommended.afterburning,
        airModel: AirModel? = nil, openFaces: OpenFaces = SolverConfiguration.recommended.openFaces,
        groundStiffness: Float = 0, balloonStart: Bool = false,
        progress: ((String) -> Void)? = nil
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
        // The mapped one-dimensional start since 18 October 2026; `balloonStart` keeps the hot-gas
        // balloon these comparisons were recorded on before then (with afterburning; the ideal gas
        // was mapped already).
        solver.configuration.mappedCharge =
            balloonStart ? !afterburning : SolverConfiguration.recommended.mappedCharge
        solver.configuration.afterburning = afterburning
        solver.configuration.openFaces = openFaces
        // As the app's "Afterburning and hot air": both or neither.
        solver.configuration.airModel = airModel ?? (afterburning ? .thermallyPerfect : .idealGas)
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
        var arrived = false
        for (a, b) in zip(samples, samples.dropFirst()) {
            let over = 0.5 * (a.pressure + b.pressure) - ambient
            if over > 0.01 * result.gaugePeak {
                arrived = true
            } else if arrived {
                break
            }
            result.gaugeImpulse += Float(b.time - a.time) * max(over, 0)
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

extension MasonryDebrisTests {
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
