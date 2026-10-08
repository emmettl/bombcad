import Foundation

/// Which sweep case runs where, when this Mac shares a sweep with a slower one. Cases wait
/// largest first: this Mac takes them from the front, the other Mac from the back, and only when
/// it should finish before this Mac has finished everything else, so that it never holds the
/// sweep up. A case the other Mac fails goes back to this one.
struct SweepSchedule: Equatable {
    struct Item: Equatable {
        var index: Int
        var cost: Double
        var remoteAllowed = true
    }

    /// Waiting cases, largest first.
    private(set) var pending: [Item]
    /// How many times longer the other Mac takes over a case: about 3.5 for the CI mini against an
    /// M4 Max, and measured once both have finished one.
    var ratio = 3.5
    private var localSeconds = 0.0
    private var localCost = 0.0
    private var remoteSeconds = 0.0
    private var remoteCost = 0.0

    init(costs: [Double]) {
        pending = costs.enumerated().map { Item(index: $0.offset, cost: $0.element) }
        pending.sort { ($0.cost, -$0.index) > ($1.cost, -$1.index) }
    }

    var isEmpty: Bool { pending.isEmpty }

    /// The work of a case, in proportion: its cells times its steps, which go as its duration over
    /// its cell size. The structure's work is not counted.
    static func cost(_ inputs: SimulationInputs) -> Double {
        let h = Double(Resolution(rawValue: inputs.settings.resolution)?.cellSize ?? 0.25)
        let domain = inputs.scenario.domainSize
        let cells = [domain.x, domain.y, domain.z].reduce(1.0) { $0 * max(1, (Double($1) / h).rounded()) }
        return cells * inputs.settings.duration / h
    }

    /// This Mac's next case.
    mutating func nextLocal() -> Int? {
        pending.isEmpty ? nil : pending.removeFirst().index
    }

    /// The other Mac's next case, given the work this Mac has left on the case it is running: the
    /// smallest case it may take, if the other Mac should finish it before this Mac finishes all
    /// the rest; otherwise nil.
    mutating func nextRemote(localRemaining: Double) -> Int? {
        guard let position = pending.lastIndex(where: \.remoteAllowed) else { return nil }
        let item = pending[position]
        let rest = pending.reduce(0) { $0 + $1.cost } - item.cost + localRemaining
        guard ratio * item.cost <= rest else { return nil }
        pending.remove(at: position)
        return item.index
    }

    /// A case the other Mac did not finish, back in the queue for this one.
    mutating func requeue(_ index: Int, cost: Double) {
        pending.append(Item(index: index, cost: cost, remoteAllowed: false))
        pending.sort { ($0.cost, -$0.index) > ($1.cost, -$1.index) }
    }

    /// Records how long a case took, and once both Macs have finished one, measures the ratio.
    mutating func record(seconds: Double, cost: Double, remote: Bool) {
        guard seconds > 0, cost > 0 else { return }
        if remote {
            remoteSeconds += seconds
            remoteCost += cost
        } else {
            localSeconds += seconds
            localCost += cost
        }
        if localCost > 0, remoteCost > 0 {
            ratio = (remoteSeconds / remoteCost) / (localSeconds / localCost)
        }
    }
}
