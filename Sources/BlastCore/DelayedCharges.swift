import Foundation
import RadialBlast
import simd

/// A charge that fires during the run, or a mapped charge waiting to be laid down: due at `time` on
/// the run's clock.
struct PendingFiring {
    enum Stage {
        /// Laid down as the balloon at its firing time.
        case balloon
        /// Fired: if the air about it is still and stays so until its one-dimensional solution has
        /// reached its radius, laid from that solution then; else the balloon now.
        case check(BlastSolver.ChargeMapping, SphericalBlast)
        /// Laid from its one-dimensional solution, its firing time and the solution's own later.
        case lay(BlastSolver.ChargeMapping, SphericalBlast)
    }

    var time: Double
    var charge: Charge
    var stage: Stage
}

/// How a charge fired after the main one was laid down.
public struct Firing: Sendable {
    public enum How: String, Sendable {
        /// Its energy spread over a sphere of hot gas when it fired.
        case balloon
        /// Its blast laid from a one-dimensional solution, at the time on the run's clock that
        /// solution had reached (its firing time and the time it took).
        case mapped
        /// To be mapped, but the air about it was not still, or another charge's blast would have
        /// reached it before its solution was laid: the balloon instead (`note` says why).
        case balloonInsteadOfMapped
    }

    public var charge: Charge
    /// When it was laid down on the run's clock, s.
    public var laidAt: Double
    public var how: How
    public var note: String?
}

extension BlastSolver {
    /// The largest overpressure, as a share of the ambient pressure, and the largest air speed in
    /// which a mapped charge may still be laid over the air: still air, as it was laid at the start.
    static let stillAirOverpressure: Float = 0.02
    static let stillAirSpeed: Float = 5

    /// Lays down the charges due by now (between batches): the balloon, or a mapped charge's
    /// solution, or, for a mapped one just fired, whether it may be laid later. Then the air about
    /// them is woken and the time step measured again, growing from a small share of the CFL limit
    /// as at the start.
    func fireDueCharges() {
        var fired: [(centre: SIMD3<Float>, radius: Float)] = []
        // Within a microsecond of its time: the batch before stopped at it, give or take the float
        // the limit was carried in.
        while let next = pendingFirings.first, next.time <= time + 1e-6 {
            pendingFirings.removeFirst()
            switch next.stage {
            case .balloon:
                depositDuringRun(next.charge)
                firings.append(Firing(charge: next.charge, laidAt: time, how: .balloon))
                fired.append((next.charge.position, balloonRadius(for: next.charge)))
            case .check(let mapping, let blast):
                switch mappable(mapping, blast) {
                case .failure(let reason):
                    depositDuringRun(next.charge)
                    firings.append(
                        Firing(
                            charge: next.charge, laidAt: time, how: .balloonInsteadOfMapped, note: reason.text
                        ))
                    fired.append((next.charge.position, balloonRadius(for: next.charge)))
                case .success(let (mapping, blast)):
                    let layTime = next.time + blast.time
                    let later = PendingFiring(time: layTime, charge: next.charge, stage: .lay(mapping, blast))
                    let at = pendingFirings.firstIndex { $0.time > layTime } ?? pendingFirings.endIndex
                    pendingFirings.insert(later, at: at)
                }
            case .lay(let mapping, let blast):
                if let disturbed = disturbance(around: mapping) {
                    // Something reached it after all: laying the solution would erase it. The
                    // balloon, late by the time the solution took.
                    depositDuringRun(next.charge)
                    firings.append(
                        Firing(
                            charge: next.charge, laidAt: time, how: .balloonInsteadOfMapped,
                            note:
                                "The air about it was disturbed (\(disturbed)) by the time its solution was due; "
                                + String(format: "the balloon, %.2f ms after it fired.", blast.time * 1000)))
                    fired.append((next.charge.position, balloonRadius(for: next.charge)))
                } else {
                    layDuringRun(blast, mapping: mapping)
                    firings.append(Firing(charge: next.charge, laidAt: time, how: .mapped))
                    fired.append((next.charge.position, mapping.radius))
                }
            }
        }
        guard !fired.isEmpty else { return }
        airIsAsleep = false
        rampStart = stepCount
        lastFiring = time
        for (centre, radius) in fired { wakeTiles(around: centre, radius: radius + 2 * grid.cellSize) }
        measureWaveSpeedAgain()
    }

    struct NotMapped: Error {
        var text: String
    }

    /// `mapping`'s charge, fired now, as it can be laid from its one-dimensional solution: as far
    /// out as no other charge's shock reaches before the solution does (Kingery and Bulmash's
    /// arrival, as on the ground, two cells early), re-solved to that radius if less; or why it
    /// cannot be, the air within its radius not still, or no radius of three cells clear.
    private func mappable(_ mapping: ChargeMapping, _ blast: SphericalBlast) -> Result<
        (ChargeMapping, SphericalBlast), NotMapped
    > {
        if let disturbed = disturbance(around: mapping) {
            return .failure(NotMapped(text: "The air about it was not still when it fired (\(disturbed))."))
        }
        let dx = grid.cellSize
        let firing = mapping.charge.firingTime
        // The first time any other charge's shock reaches within `radius` of this one.
        func reached(within radius: Float) -> (time: Double, charge: Int)? {
            var first: (time: Double, charge: Int)?
            for (j, other) in firingCharges.enumerated() where j != mapping.index && other.mass > 0 {
                let gap = Double(simd_distance(other.position, mapping.charge.position) - radius - 2 * dx)
                let mass = Double(other.mass)
                let z = gap / cbrt(mass)
                let arrival =
                    z <= 0.06
                    ? 0 : z >= 40 ? Double.infinity : (KingeryBulmash.scaledArrival(at: z) ?? 0) * cbrt(mass)
                let time = other.firingTime + arrival
                if time < (first?.time ?? .infinity) { first = (time, j) }
            }
            return first
        }
        guard let first = reached(within: mapping.radius), first.time < firing + blast.time else {
            return .success((mapping, blast))
        }
        // The largest radius, in whole cells, the solution reaches before any other shock does.
        var radius = mapping.radius - dx
        while radius >= 3 * dx {
            let due = blast.arrival(at: Double(radius)).map { firing + $0 } ?? .infinity
            if let other = reached(within: radius), other.time < due {
                radius -= dx
                continue
            }
            var smaller = mapping
            smaller.radius = radius
            var solution = Self.mappedSolution(
                smaller.charge, radius: radius, mirrors: smaller.mirrors, configuration: configuration,
                ambientDensity: ambientDensity, products: configuration.mappedChargeProducts ? .tnt : nil)
            solution.probes = firingProbes.map { Double(simd_distance($0, smaller.charge.position)) }
            return .success((smaller, solution.solved(toShockRadius: Double(radius), until: .infinity)))
        }
        return .failure(
            NotMapped(
                text: String(
                    format:
                        "Charge %d's shock would reach the air about it at %.2f ms, before even three cells "
                        + "of its own solution were due.", first.charge + 1, first.time * 1000)))
    }

    /// The largest overpressure and speed of the air within `mapping`'s radius (and nearer its
    /// charge than any other), if either is more than still air's; nil if it is still.
    private func disturbance(around mapping: ChargeMapping) -> String? {
        let grid = self.grid
        let dx = grid.cellSize
        let charge = mapping.charge
        let positions = firingCharges.map(\.position)
        let low = grid.cell(containing: charge.position - mapping.radius)
        let high = grid.cell(containing: charge.position + mapping.radius)
        let ambient = configuration.ambientPressure
        var worst = (overpressure: Float(0), speed: Float(0))
        withState { cells in
            for k in low.k...high.k {
                for j in low.j...high.j {
                    for i in low.i...high.i where !isSolid(i, j, k) {
                        let centre = (SIMD3(Float(i), Float(j), Float(k)) + 0.5) * dx
                        guard simd_distance(centre, charge.position) < mapping.radius,
                            nearest(centre, to: charge.position, among: positions)
                        else { continue }
                        let state = primitive(of: cells[grid.index(i, j, k)])
                        worst.overpressure = max(worst.overpressure, abs(state.pressure - ambient))
                        worst.speed = max(worst.speed, simd_length(state.velocity))
                    }
                }
            }
        }
        guard worst.overpressure > Self.stillAirOverpressure * ambient || worst.speed > Self.stillAirSpeed
        else {
            return nil
        }
        return String(format: "%.1f kPa, %.1f m/s", worst.overpressure / 1000, worst.speed)
    }

    /// The balloon laid down during the run: added to the air there. Where the air is refined, in
    /// the finest cells, the patches already there taking their cells' share and the coarse cells
    /// the mean; patches placed after take it from the coarse cells.
    private func depositDuringRun(_ charge: Charge) {
        guard !refinementLevels.isEmpty else {
            depositCoarse(charge)
            return
        }
        // Laid in `fineDeposit` and on the coarse cells, as at the start.
        deposit(charge)
        for level in refinementLevels.indices { addFineDeposit(level: level) }
        fineDeposit = [:]
    }

    /// The finest cells' deposit (`fineDeposit`) added to the cells of refinement `level` that a
    /// patch holds now, each the mean of the finest cells in it.
    private func addFineDeposit(level: Int) {
        let target = refinementLevels[level]
        let finest = refinementLevels.reduce(1) { $0 * $1.ratio }
        let r = target.parentScale * target.ratio
        let below = finest / r
        let read = target.fineCells()
        var cells: [SIMD3<Int>: (state: CellState, species: SIMD2<Float>)] = [:]
        for coarse in Set(fineDeposit.keys.map { $0 / finest }) {
            for n in 0..<(r * r * r) {
                let fine = coarse &* r &+ SIMD3(n % r, (n / r) % r, n / (r * r))
                guard var cell = read(fine) else { continue }
                var added = SIMD2<Double>.zero
                for m in 0..<(below * below * below) {
                    let finer = fine &* below &+ SIMD3(m % below, (m / below) % below, m / (below * below))
                    added += SIMD2<Double>(fineDeposit[finer] ?? .zero)
                }
                guard added != .zero else { continue }
                let mean = SIMD2<Float>(added / Double(below * below * below))
                cell.state.density += mean.x
                cell.state.energy += mean.y
                cell.species.x += mean.x
                cells[fine] = cell
            }
        }
        target.setFine(cells)
    }

    /// A mapped charge's solution laid down during the run, over still air: on the coarse cells and
    /// on the cells of the patches there now, with its peaks, impulses, gauge records and the
    /// exposure plane's, at their times from its firing.
    private func layDuringRun(_ blast: SphericalBlast, mapping: ChargeMapping) {
        let positions = firingCharges.map(\.position)
        let charge = mapping.charge
        lay(blast, charge: charge, radius: mapping.radius, among: positions)
        for level in refinementLevels {
            let r = level.parentScale * level.ratio
            let fine = grid.cellSize / Float(r)
            let read = level.fineCells()
            let low = SIMD3<Int>(
                simd_max((charge.position - mapping.radius - fine) / fine, .zero).rounded(.down))
            let high = SIMD3<Int>(((charge.position + mapping.radius + fine) / fine).rounded(.down))
            let samples = 4
            var cells: [SIMD3<Int>: (state: CellState, species: SIMD2<Float>)] = [:]
            for k in low.z...high.z {
                for j in low.y...high.y {
                    for i in low.x...high.x {
                        let at = SIMD3(i, j, k)
                        guard var cell = read(at),
                            nearest(
                                (SIMD3(Float(i), Float(j), Float(k)) + 0.5) * fine, to: charge.position,
                                among: positions)
                        else { continue }
                        let (sum, momentum, carried, counted) = blast.sample(
                            cell: i, j, k, cellSize: fine, centre: charge.position,
                            reach: Double(mapping.radius) * 1.5, samples: samples)
                        guard counted == samples * samples * samples else { continue }
                        let n = Double(counted)
                        cell.state.density = Float(sum.x / n)
                        cell.state.momentumX = Float(momentum.x / n)
                        cell.state.momentumY = Float(momentum.y / n)
                        cell.state.momentumZ = Float(momentum.z / n)
                        cell.state.energy = Float(sum.z / n)
                        if blast.afterburn != nil { cell.species = SIMD2<Float>(carried / n) }
                        cells[at] = cell
                    }
                }
            }
            level.setFine(cells)
        }
        var added: [Int: Float] = [:]
        setFields { peak, impulse in
            let before = Array(impulse)
            record(blast, mapping: mapping, among: positions, peak: peak, impulse: impulse, adding: true)
            for index in impulse.indices where impulse[index] != before[index] {
                added[index] = impulse[index] - before[index]
            }
        }
        refinement?.addImpulseBase(added, grid: grid)
        recordGauges(blast, mapping: mapping, among: positions, gauges: firingProbes)
        exposurePlane?.seed(
            blast, centre: charge.position, radius: mapping.radius, delay: charge.firingTime, adding: true)
    }
}
