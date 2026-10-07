import simd

/// CPU reference for extensive mass, momentum and total energy in prescribed gas volumes.
/// Face transfers are supplied by the caller; this does not construct a displacement field,
/// solve a Riemann problem, choose a timestep or change the app's air solver.
enum FractionalGasTransport {
    enum Failure: Error { case invalidState, invalidTransfer, excessiveOutflow, occupiedDryCell }
    struct Cell {
        let volume: Double
        let amount: SIMD8<Double>  // mass, momentum xyz, total energy; remaining lanes zero
        init(
            volume: Double, density: Double, velocity: SIMD3<Double> = .zero, pressure: Double,
            gamma: Double = 1.4
        ) {
            self.volume = volume
            let mass = volume * density
            amount = SIMD8(
                mass, mass * velocity.x, mass * velocity.y, mass * velocity.z,
                volume * pressure / (gamma - 1) + 0.5 * mass * simd_length_squared(velocity), 0, 0, 0)
        }
        init(volume: Double, amount: SIMD8<Double>) {
            self.volume = volume
            self.amount = amount
        }
        var velocity: SIMD3<Double> {
            amount[0] > 0 ? SIMD3(amount[1], amount[2], amount[3]) / amount[0] : .zero
        }
        func pressure(gamma: Double = 1.4) -> Double {
            volume > 0
                ? (gamma - 1) * (amount[4] - 0.5 * amount[0] * simd_length_squared(velocity)) / volume : 0
        }
    }
    struct Transfer {
        let from: Int
        let to: Int
        let volume: Double
    }
    struct WallExchange {
        let cell: Int
        let impulse: SIMD3<Double>
        let gasWork: Double
    }

    /// Frozen donor states prevent inflow from being reused in the same update. Total
    /// outflow is bounded by each donor's old volume; wall work may still make a state invalid.
    static func advance(
        _ old: [Cell], newVolumes: [Double], transfers: [Transfer], walls: [WallExchange] = []
    ) throws -> [Cell] {
        guard old.count == newVolumes.count else { throw Failure.invalidState }
        for n in old.indices {
            guard valid(old[n]), newVolumes[n].isFinite && newVolumes[n] >= 0 else {
                throw Failure.invalidState
            }
        }
        var outgoing = Array(repeating: 0.0, count: old.count)
        for transfer in transfers {
            guard old.indices.contains(transfer.from), old.indices.contains(transfer.to),
                transfer.from != transfer.to,
                transfer.volume.isFinite && transfer.volume >= 0,
                transfer.volume == 0 || old[transfer.from].volume > 0
            else { throw Failure.invalidTransfer }
            outgoing[transfer.from] += transfer.volume
        }
        for n in old.indices {
            guard outgoing[n] <= old[n].volume else { throw Failure.excessiveOutflow }
        }
        var amounts = old.map(\.amount)
        for transfer in transfers where transfer.volume > 0 {
            let carried = old[transfer.from].amount * (transfer.volume / old[transfer.from].volume)
            amounts[transfer.from] -= carried
            amounts[transfer.to] += carried
        }
        for wall in walls {
            guard old.indices.contains(wall.cell), wall.gasWork.isFinite,
                (0..<3).allSatisfy({ wall.impulse[$0].isFinite })
            else { throw Failure.invalidState }
            amounts[wall.cell] += SIMD8(
                0, wall.impulse.x, wall.impulse.y, wall.impulse.z, wall.gasWork, 0, 0, 0)
        }
        var result: [Cell] = []
        for n in old.indices {
            if newVolumes[n] == 0 {
                for axis in 0..<5 {
                    let scale = max(abs(old[n].amount[axis]), 1e-300)
                    guard abs(amounts[n][axis]) <= 64 * Double.ulpOfOne * scale else {
                        throw Failure.occupiedDryCell
                    }
                }
                amounts[n] = .zero
            }
            let cell = Cell(volume: newVolumes[n], amount: amounts[n])
            guard valid(cell) else { throw Failure.invalidState }
            result.append(cell)
        }
        return result
    }
    private static func valid(_ cell: Cell) -> Bool {
        guard cell.volume.isFinite && cell.volume >= 0, (0..<8).allSatisfy({ cell.amount[$0].isFinite }),
            (5..<8).allSatisfy({ cell.amount[$0] == 0 })
        else { return false }
        if cell.volume == 0 { return cell.amount == .zero }
        return cell.amount[0] > 0 && cell.pressure().isFinite && cell.pressure() > 0
    }
}
