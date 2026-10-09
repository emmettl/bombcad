import Foundation

/// Which sweep case runs where, when this Mac shares a sweep with other, usually slower, Macs.
/// Cases wait largest first: this Mac takes them from the front, and a worker, whenever it is
/// free, takes the smallest case it should finish before this Mac and the other workers have
/// finished everything else, so that no worker holds the sweep up. Each worker's speed is
/// measured against this Mac's as cases finish. A case a worker fails goes back to the queue,
/// and that worker takes no more.
///
/// Every choice depends only on the queue, the cases running and how far they have got, and the
/// ratios; nothing is random or timed here, so the same events give the same plan.
struct SweepSchedule: Equatable {
    struct Item: Equatable {
        var index: Int
        var cost: Double
    }

    /// A machine taking cases: this Mac, or one of the workers, numbered from zero.
    enum Machine: Hashable {
        case local
        case worker(Int)
    }

    /// A case running, its cost and how much of it is done.
    struct Running: Equatable {
        var index: Int
        var cost: Double
        var fraction = 0.0
        var remaining: Double { cost * (1 - min(max(fraction, 0), 1)) }
    }

    struct Worker: Equatable {
        /// Taking cases: connected, and not failed or finished.
        var active = false
        var running: Running?
        var seconds = 0.0
        var cost = 0.0
    }

    /// Waiting cases, largest first.
    private(set) var pending: [Item]
    private(set) var local: Running?
    private(set) var workers: [Worker]
    /// How many times longer a worker is taken to be over a case until it and this Mac have each
    /// finished one: about 3.5 for the CI mini against an M4 Max.
    var ratio = 3.5
    private var localSeconds = 0.0
    private var localCost = 0.0
    private var cancelled = false

    init(costs: [Double], workers: Int = 0) {
        pending = costs.enumerated().map { Item(index: $0.offset, cost: $0.element) }
        self.workers = Array(repeating: Worker(), count: workers)
        sortPending()
    }

    /// Nothing waiting, though cases may still be running.
    var isEmpty: Bool { pending.isEmpty }
    /// Nothing waiting or running.
    var isFinished: Bool { pending.isEmpty && local == nil && workers.allSatisfy { $0.running == nil } }
    /// Whether a worker is running a case, which it may yet fail back to the queue.
    var workersBusy: Bool { workers.contains { $0.running != nil } }

    /// The work of a case, in proportion: its cells times its steps, which go as its duration over
    /// its cell size. The structure's work is not counted.
    static func cost(_ inputs: SimulationInputs) -> Double {
        let h = Double(Resolution(rawValue: inputs.settings.resolution)?.cellSize ?? 0.25)
        let domain = inputs.scenario.domainSize
        let cells = [domain.x, domain.y, domain.z].reduce(1.0) { $0 * max(1, (Double($1) / h).rounded()) }
        return cells * inputs.settings.duration / h
    }

    /// How many times longer `worker` takes over a case than this Mac: measured once both have
    /// finished one, `ratio` until then.
    func ratio(of worker: Int) -> Double {
        let measured = workers[worker]
        guard localCost > 0, measured.cost > 0, localSeconds > 0 else { return ratio }
        return (measured.seconds / measured.cost) / (localSeconds / localCost)
    }

    /// A worker has connected and may take cases.
    mutating func join(_ worker: Int) {
        guard !cancelled else { return }
        workers[worker].active = true
    }

    /// A worker takes no more cases. One running goes back to the queue.
    mutating func leave(_ worker: Int) {
        workers[worker].active = false
        if let running = workers[worker].running {
            workers[worker].running = nil
            if !cancelled { enqueue(running.index, cost: running.cost) }
        }
    }

    /// A worker failed its case, or lost its connection: the case goes back to the queue, and the
    /// worker takes no more.
    mutating func fail(_ worker: Int) { leave(worker) }

    /// No more cases start anywhere; those running are not run again.
    mutating func cancel() {
        cancelled = true
        pending = []
        for worker in workers.indices {
            workers[worker].active = false
            workers[worker].running = nil
        }
        local = nil
    }

    /// The next case for `machine`, if it should take one; nil if it should not, which for a
    /// worker means it should stop. This Mac takes the largest waiting case. A worker takes the
    /// smallest, if its ratio times the case's cost is within the time the others need for the
    /// rest (see `deadline`).
    mutating func next(_ machine: Machine) -> Int? {
        switch machine {
        case .local:
            guard local == nil, !pending.isEmpty else { return nil }
            let item = pending.removeFirst()
            local = Running(index: item.index, cost: item.cost)
            return item.index
        case .worker(let worker):
            guard workers[worker].active, workers[worker].running == nil,
                let position = pending.indices.last
            else { return nil }
            let item = pending[position]
            let waiting = pending.reduce(0) { $0 + $1.cost } - item.cost
            guard ratio(of: worker) * item.cost <= deadline(excluding: worker, waiting: waiting) else {
                return nil
            }
            pending.remove(at: position)
            workers[worker].running = Running(index: item.index, cost: item.cost)
            return item.index
        }
    }

    /// The time, in this Mac's seconds per unit of cost, that the machines other than `worker`
    /// need for `waiting` and the cases they are running: each takes its share of the waiting
    /// work once its own case is done, at its speed, as if cases could be divided exactly; and
    /// never sooner than the last of their running cases ends, which no worker can hold up. With
    /// only this Mac besides, it is just this Mac's work left.
    func deadline(excluding worker: Int, waiting: Double) -> Double {
        var machines = [(free: local?.remaining ?? 0, speed: 1.0)]
        for other in workers.indices where other != worker {
            guard let running = workers[other].running else { continue }
            let ratio = max(ratio(of: other), 1e-6)
            machines.append((running.remaining * ratio, 1 / ratio))
        }
        machines.sort { $0.free < $1.free }
        let last = machines.last!.free
        var work = waiting
        var time = machines[0].free
        var speed = 0.0
        for machine in machines {
            // Until this machine is free, those already free share the work.
            if speed > 0 {
                let span = machine.free - time
                if work <= speed * span { return max(time + work / speed, last) }
                work -= speed * span
            }
            time = machine.free
            speed += machine.speed
        }
        return max(time + work / speed, last)
    }

    /// How far `machine` has got through its case, from 0 to 1.
    mutating func progress(_ machine: Machine, _ fraction: Double) {
        switch machine {
        case .local: local?.fraction = fraction
        case .worker(let worker): workers[worker].running?.fraction = fraction
        }
    }

    /// `machine` has finished its case in `seconds`; the time goes towards its measured speed.
    mutating func finish(_ machine: Machine, seconds: Double) {
        switch machine {
        case .local:
            guard let running = local else { return }
            local = nil
            guard seconds > 0, running.cost > 0 else { return }
            localSeconds += seconds
            localCost += running.cost
        case .worker(let worker):
            guard let running = workers[worker].running else { return }
            workers[worker].running = nil
            guard seconds > 0, running.cost > 0 else { return }
            workers[worker].seconds += seconds
            workers[worker].cost += running.cost
        }
    }

    private mutating func enqueue(_ index: Int, cost: Double) {
        pending.append(Item(index: index, cost: cost))
        sortPending()
    }

    private mutating func sortPending() {
        pending.sort { ($0.cost, -$0.index) > ($1.cost, -$1.index) }
    }
}
