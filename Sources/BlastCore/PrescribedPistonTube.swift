import simd

/// One-dimensional planar piston with conservative end-cell merging/splitting.
/// A small end cell is joined to its neighbour at a configurable volume fraction.
/// This changes spatial diffusion; it is not a general moving cut-cell solver.
enum PrescribedPistonTube {
    enum Reconstruction: String, Codable, Sendable { case constant, minmod }
    enum Failure: Error { case invalidGeometry, stepLimit }
    struct Snapshot {
        let time: Double
        let cells: [FractionalGasTransport.Cell]
        let wallWork: Double
        let wallImpulse: SIMD3<Double>
        let steps: Int
        let rejectedSteps: Int
    }
    struct Result {
        let cells: [FractionalGasTransport.Cell]
        let steps: Int
        let rejectedSteps: Int
        let remeshes: Int
        let gridCrossings: Int
        let wallWork: Double
        let wallImpulse: SIMD3<Double>
        let initialAmount: SIMD8<Double>
        let snapshots: [Snapshot]
    }

    static func run(
        cellLength h: Double, area: Double, length: Double, pistonVelocity: Double, duration: Double,
        density: Double = 1.225, pressure: Double = 101325, maximumSteps: Int = 100000,
        mergeFraction: Double = 0.25, cfl: Double = 0.4, outputTimes: [Double] = [],
        reconstruction: Reconstruction = .constant
    ) throws -> Result {
        let finalLength = length + pistonVelocity * duration
        guard h.isFinite && h > 0, area.isFinite && area > 0, length.isFinite && length > 0,
            pistonVelocity.isFinite, duration.isFinite && duration > 0,
            finalLength.isFinite && finalLength > 0, maximumSteps > 0,
            mergeFraction.isFinite && mergeFraction > 0 && mergeFraction <= 0.5,
            cfl.isFinite && cfl > 0 && cfl <= 0.5,
            outputTimes.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= duration }),
            Set(outputTimes).count == outputTimes.count,
            max(length, finalLength) / h < 10000
        else { throw Failure.invalidGeometry }
        func volumes(_ length: Double) -> [Double] {
            let full = Int(floor(length / h))
            var lengths = [Double](repeating: h, count: full)
            let remainder = length - Double(full) * h
            if remainder > 0 { lengths.append(remainder) }
            if lengths.count > 1,
                lengths.last! <= mergeFraction * h * (pistonVelocity < 0 ? 1 + 1e-12 : 1 - 1e-12)
            {
                let small = lengths.removeLast()
                lengths[lengths.count - 1] += small
            }
            return lengths.map { $0 * area }
        }
        var cells = volumes(length).map {
            FractionalGasTransport.Cell(volume: $0, density: density, pressure: pressure)
        }
        _ = try FractionalGasTransport.advance(cells, newVolumes: cells.map(\.volume), transfers: [])
        let initialAmount = cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        var events: [(time: Double, length: Double, snapshot: Bool)] = [
            (duration, finalLength, outputTimes.contains(duration))
        ]
        for time in outputTimes where time < duration {
            events.append((time, length + pistonVelocity * time, true))
        }
        var crossings = 0
        if pistonVelocity != 0 {
            for n in 1...Int(ceil(max(length, finalLength) / h)) {
                for offset in [0.0, mergeFraction] {
                    let boundary = (Double(n) + offset) * h
                    let time = (boundary - length) / pistonVelocity
                    if time > 0 && time < duration {
                        events.append((time, boundary, false))
                        if offset == 0 { crossings += 1 }
                    }
                }
            }
        }
        events.sort { $0.time < $1.time }
        var elapsed = 0.0
        var steps = 0
        var rejectedSteps = 0
        var remeshes = 0
        var wallWork = 0.0
        var wallImpulse = SIMD3<Double>.zero
        var snapshots: [Snapshot] = []
        for event in events {
            while elapsed < event.time {
                let faces =
                    reconstruction == .minmod
                    ? LimitedTubeFlux.faces(cells, area: area)
                    : (0..<max(0, cells.count - 1)).map {
                        FractionalEulerFlux.Face(a: $0, b: $0 + 1, normal: SIMD3(1, 0, 0), area: area)
                    }
                let walls = [
                    FractionalEulerFlux.Wall(cell: 0, normal: SIMD3(-1, 0, 0), area: area),
                    .init(
                        cell: cells.count - 1, normal: SIMD3(1, 0, 0), area: area,
                        velocity: SIMD3(pistonVelocity, 0, 0)),
                ]
                let limit = try FractionalEulerFlux.maximumStep(cells, faces: faces, walls: walls, cfl: cfl)
                var step = min(limit, event.time - elapsed)
                guard steps < maximumSteps && step > 0 && elapsed + step > elapsed else {
                    throw Failure.stepLimit
                }
                let result: FractionalEulerFlux.Result
                if reconstruction == .minmod {
                    var accepted: FractionalEulerFlux.Result?
                    for _ in 0..<24 {
                        do {
                            accepted = try LimitedTubeFlux.advance(
                                cells, area: area, walls: walls,
                                duration: step, cfl: cfl)
                            break
                        } catch FractionalEulerFlux.Failure.unstableStep {
                            rejectedSteps += 1
                            step /= 2
                        } catch FractionalGasTransport.Failure.invalidState {
                            rejectedSteps += 1
                            step /= 2
                        }
                        guard step > 0 && elapsed + step > elapsed else { throw Failure.stepLimit }
                    }
                    guard let accepted else { throw Failure.stepLimit }
                    result = accepted
                } else {
                    result = try FractionalEulerFlux.advanceWithWalls(
                        cells, faces: faces, walls: walls, duration: step, cfl: cfl)
                }
                cells = result.cells
                wallWork += result.wallWork.reduce(0, +)
                wallImpulse += result.wallImpulses.reduce(.zero, +)
                elapsed += step
                steps += 1
            }
            let next = volumes(event.length)
            if next.count != cells.count { remeshes += 1 }
            cells = try repartition(cells, volumes: next)
            if event.snapshot {
                snapshots.append(
                    Snapshot(
                        time: event.time, cells: cells, wallWork: wallWork,
                        wallImpulse: wallImpulse, steps: steps, rejectedSteps: rejectedSteps))
            }
        }
        return Result(
            cells: cells, steps: steps, rejectedSteps: rejectedSteps, remeshes: remeshes,
            gridCrossings: crossings,
            wallWork: wallWork, wallImpulse: wallImpulse, initialAmount: initialAmount,
            snapshots: snapshots)
    }

    /// Piecewise-constant extensive rebinning on ordered, contiguous one-dimensional volumes.
    /// Each donor's last overlap receives its packet remainder to preserve its whole inventory.
    static func repartition(
        _ old: [FractionalGasTransport.Cell], volumes: [Double]
    ) throws -> [FractionalGasTransport.Cell] {
        guard !old.isEmpty, !volumes.isEmpty, old.allSatisfy({ $0.volume > 0 }),
            volumes.allSatisfy({ $0.isFinite && $0 > 0 })
        else { throw Failure.invalidGeometry }
        _ = try FractionalGasTransport.advance(old, newVolumes: old.map(\.volume), transfers: [])
        let oldTotal = old.reduce(0) { $0 + $1.volume }
        let newTotal = volumes.reduce(0, +)
        guard abs(oldTotal - newTotal) <= 1e-10 * max(oldTotal, newTotal) else {
            throw Failure.invalidGeometry
        }
        // Normalised boundaries absorb only accumulated geometric roundoff at the endpoint.
        var boundaries = [0.0]
        for volume in volumes { boundaries.append(boundaries.last! + volume / newTotal) }
        boundaries[boundaries.count - 1] = 1
        var amounts = [SIMD8<Double>](repeating: .zero, count: volumes.count)
        var low = 0.0
        for n in old.indices {
            let high = n == old.count - 1 ? 1 : low + old[n].volume / oldTotal
            let overlaps = volumes.indices.filter { min(high, boundaries[$0 + 1]) > max(low, boundaries[$0]) }
            guard !overlaps.isEmpty else { throw Failure.invalidGeometry }
            var remaining = old[n].amount
            for target in overlaps {
                let overlap = min(high, boundaries[target + 1]) - max(low, boundaries[target])
                let packet = target == overlaps.last! ? remaining : old[n].amount * (overlap / (high - low))
                amounts[target] += packet
                remaining -= packet
            }
            low = high
        }
        let updated = volumes.indices.map {
            FractionalGasTransport.Cell(volume: volumes[$0], amount: amounts[$0])
        }
        return try FractionalGasTransport.advance(updated, newVolumes: volumes, transfers: [])
    }
}
