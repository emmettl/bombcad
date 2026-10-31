import BlastCore
import Foundation
import simd

/// `blastbench wholeevent --outcome <checkpoint or run folder>`: what a user would read from a
/// whole-event run at a saved state (emmettl/bombcad-work#36, a range, docs/whole-event.md): how
/// much of each floor has come down, the storeys lost, what has failed by part, and the debris:
/// the rubble's mass and how far the mass outside the block's plan lies from it.
///
/// A floor element is down when its concrete has gone (rubble, or bare bars) or its centre has
/// dropped more than half a storey; "sagged" counts a drop of 0.3 m as well. A storey is lost when
/// more than 15% of its floor is down (the share UK Approved Document A allows a storey to lose
/// after a member is removed). Debris is every node with mass and every rubble particle, its
/// distance the horizontal distance from the block's plan; mass within 0.5 m of the plan (walls
/// bowing, a bay leaning) is not counted as thrown.
struct WholeEventOutcome {
    static let header =
        "t,mass_t,floor_area_m2,storeys_lost,floor_area_down_m2,floor_area_sagged_m2,floor_down_percent_by_level,"
        + "failed_floor,failed_wall,failed_face,rubble_particles,rubble_t,outside_t,beyond_2m_t,beyond_5m_t,"
        + "beyond_10m_t,reach_50_m,reach_90_m,reach_99_m,reach_max_m,outside_moving_t,outside_speed_m_s"

    var mass: Double = 0
    var floorArea: Float = 0
    var storeysLost = 0
    var areaDown: Float = 0
    var areaSagged: Float = 0
    var levels: [Int] = []
    var failed: (floor: Int, wall: Int, face: Int) = (0, 0, 0)
    var particles = 0
    var rubbleMass: Double = 0
    var outside: Double = 0
    var beyond: [Double] = [0, 0, 0]
    var reach: [Float] = [0, 0, 0, 0]
    /// The mass outside the plan still moving across the ground faster than 0.5 m/s, and the
    /// outside mass's mean horizontal speed: whether the debris has come to rest.
    var moving: Double = 0
    var speed: Double = 0

    init(_ s: StructureSolver, storeys: Int) {
        let h = s.model.elementSize
        let count = s.elementCount
        let instances = s.instanceBuffer.contents().bindMemory(to: UInt32.self, capacity: max(count, 1))
        let flags = s.flagBuffer.contents().bindMemory(to: UInt8.self, capacity: s.ex * s.ey * s.ez)
        let materialIndex = s.materialIndexBuffer.contents().bindMemory(
            to: UInt8.self, capacity: max(count, 1))
        // The block's plan and base, from its elements' undeformed centres.
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = -low
        for n in 0..<count {
            let (i, j, k) = s.elementCoordinates(Int(instances[n]))
            low = simd_min(low, s.referencePosition(i, j, k))
            high = simd_max(high, s.referencePosition(i + 1, j + 1, k + 1))
        }
        let storeyHeight = (high.z - low.z) / Float(storeys)
        var floorElements = [Int](repeating: 0, count: storeys)
        var floorLayers = [Set<Int>](repeating: [], count: storeys)
        var down = [Int](repeating: 0, count: storeys)
        var sagged = [Int](repeating: 0, count: storeys)
        for n in 0..<count {
            let index = Int(instances[n])
            let (i, j, k) = s.elementCoordinates(index)
            let name = s.materials[Int(materialIndex[n] & 15)].name.lowercased()
            let flag = flags[index]
            let gone = flag == 2 || flag == 3 || flag >= 4
            if gone {
                if name.contains("floor") {
                    failed.floor += 1
                } else if name.contains("face") {
                    failed.face += 1
                } else {
                    failed.wall += 1
                }
            }
            guard name.contains("floor") else { continue }
            let reference = s.referencePosition(i, j, k) + 0.5 * h
            let storey = min(storeys - 1, max(0, Int((reference.z - low.z) / storeyHeight)))
            floorElements[storey] += 1
            floorLayers[storey].insert(k)
            var centre = SIMD3<Float>.zero
            for a in 0..<8 { centre += s.position(i + (a & 1), j + ((a >> 1) & 1), k + ((a >> 2) & 1)) }
            let drop = reference.z - centre.z / 8
            if gone || drop > 0.5 * storeyHeight { down[storey] += 1 }
            if gone || drop > 0.3 { sagged[storey] += 1 }
        }
        for storey in 0..<storeys where floorElements[storey] > 0 {
            let share = Float(down[storey]) / Float(floorElements[storey])
            let layers = Float(max(floorLayers[storey].count, 1))
            floorArea += Float(floorElements[storey]) * h * h / layers
            areaDown += Float(down[storey]) * h * h / layers
            areaSagged += Float(sagged[storey]) * h * h / layers
            levels.append(Int((100 * share).rounded()))
            if share > 0.15 { storeysLost += 1 }
        }

        // Debris: the nodes with mass and the rubble, by horizontal distance from the plan.
        var masses: [(distance: Float, mass: Double)] = []
        var total = 0.0
        var movingMass = 0.0
        var momentum = 0.0
        func add(_ p: SIMD3<Float>, _ v: SIMD3<Float>, _ mass: Float) {
            total += Double(mass)
            let below = simd_max(SIMD2(low.x, low.y) - SIMD2(p.x, p.y), .zero)
            let above = simd_max(SIMD2(p.x, p.y) - SIMD2(high.x, high.y), .zero)
            let distance = simd_length(below + above)
            guard distance > 0.5 else { return }
            masses.append((distance, Double(mass)))
            let across = simd_length(SIMD2(v.x, v.y))
            momentum += Double(mass * across)
            if across > 0.5 { movingMass += Double(mass) }
        }
        for k in 0...s.ez {
            for j in 0...s.ey {
                for i in 0...s.ex where s.storedNode(i, j, k) != nil {
                    let node = s.node(i, j, k)
                    guard node.mass > 0 else { continue }
                    add(s.referencePosition(i, j, k) + node.displacement, node.velocity, node.mass)
                }
            }
        }
        for (_, p) in s.rubbleParticles() {
            particles += 1
            rubbleMass += Double(p.mass)
            add(p.position, p.velocity, p.mass)
        }
        mass = total
        moving = movingMass
        masses.sort { $0.distance < $1.distance }
        outside = masses.reduce(0) { $0 + $1.mass }
        for (n, limit) in [Float(2), 5, 10].enumerated() {
            beyond[n] = masses.filter { $0.distance > limit }.reduce(0) { $0 + $1.mass }
        }
        var running = 0.0
        var shares = [0.5, 0.9, 0.99]
        for entry in masses {
            running += entry.mass
            while let share = shares.first, running >= share * outside {
                reach[3 - shares.count] = entry.distance
                shares.removeFirst()
            }
        }
        reach[3] = masses.last?.distance ?? 0
        speed = outside > 0 ? momentum / outside : 0
    }

    func row(time: Double) -> String {
        let fields: [String] = [
            String(format: "%.3f", time), String(format: "%.1f", mass / 1000),
            String(format: "%.1f", floorArea),
            "\(storeysLost)", String(format: "%.1f", areaDown),
            String(format: "%.1f", areaSagged), levels.map(String.init).joined(separator: " "),
            "\(failed.floor)", "\(failed.wall)", "\(failed.face)", "\(particles)",
            String(format: "%.1f", rubbleMass / 1000), String(format: "%.1f", outside / 1000),
        ]
        return
            (fields + beyond.map { String(format: "%.1f", $0 / 1000) }
            + reach.map { String(format: "%.1f", $0) }
            + [String(format: "%.1f", moving / 1000), String(format: "%.2f", speed)])
            .joined(separator: ",")
    }
}

/// When a whole-event run's results are read (the user's decision, 31 October 2026,
/// emmettl/bombcad-work#36): once the block is at rest, at 5 s, or later only if it comes to rest
/// later. Past that the block at rest goes on failing walls in its pile (docs/whole-event.md, the
/// 10 s run), so no later failure count or rubble mass is quoted.
enum WholeEventReading {
    static let time = 5.0

    /// When the block comes to rest by the run's phases.csv: its kinetic energy under 5% of its peak
    /// from then on; nil without the file, or if it has not.
    static func restTime(phases: URL) -> Double? {
        guard let text = try? String(contentsOf: phases, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n")
        guard let header = lines.first?.split(separator: ",").map(String.init),
            let t = header.firstIndex(of: "t"), let nodes = header.firstIndex(of: "ke_nodes_J"),
            let particles = header.firstIndex(of: "ke_particles_J")
        else { return nil }
        let rows: [(t: Double, ke: Double)] = lines.dropFirst().compactMap { line in
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count > max(t, nodes, particles), let time = Double(f[t]), let a = Double(f[nodes]),
                let b = Double(f[particles])
            else { return nil }
            return (time, a + b)
        }
        guard let peak = rows.map(\.ke).max(), peak > 0,
            let last = rows.lastIndex(where: { $0.ke >= 0.05 * peak }), last + 1 < rows.count
        else { return nil }
        return rows[last + 1].t
    }

    /// The line `--outcome` ends a run folder's rows with: which row to quote.
    static func note(times: [Double], phases: URL) -> String {
        let rest = restTime(phases: phases)
        let reading = max(time, rest ?? time)
        let restText = rest.map { String(format: "at rest from %.2f s by phases.csv", $0) } ?? "no phases.csv"
        guard let row = times.first(where: { $0 >= reading - 0.02 }) else {
            return String(
                format: "Read at rest: no saved state at %.1f s or after yet (%@); quote none of these rows",
                reading, restText)
        }
        return String(
            format:
                "Read at rest: quote the row at %.3f s (%@; results are read at 5 s, or at rest if later, and no later failure count or rubble mass is quoted)",
            row, restText)
    }
}
