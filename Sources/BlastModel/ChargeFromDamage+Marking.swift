import Foundation
import simd

extension ChargeFromDamage {
    /// Marks given one building at a time and the posterior they make, kept up to date mark by mark:
    /// the app's Charge from the Damage panel (emmettl/bombcad-work#116, stage 2;
    /// docs/charge-inference.md, "Marking the damage in the app"). The marks' log likelihoods over
    /// the cells and bins are kept summed (`Network.joint`), so that a mark added, changed or cleared
    /// costs its own likelihood alone, taken in or out of the sum, and the posterior is renormalised
    /// from it. Moving the place searched about works it all out again.
    public struct Marking: Sendable {
        public let network: Network
        /// The middle of the square searched, the scene's metres.
        public private(set) var reference: SIMD2<Double>
        /// Each marked building's mark (its place the scene's metres), by its id.
        public private(set) var marks: [UUID: Mark] = [:]
        /// The ids in the order they were first marked.
        public private(set) var order: [UUID] = []
        /// The marks' summed log likelihood over the cells and bins, −∞ outside the disc (a
        /// summed network's); empty for a pooled one, worked out again from the marks.
        private var joint: [Float]
        /// The sum with no marks: zero in the disc, −∞ outside it.
        private let empty: [Float]
        /// The posterior of the marks; nil without any.
        public private(set) var posterior: Posterior?
        /// How long the last change took to weigh, from the mark to the posterior, s.
        public private(set) var lastSeconds = 0.0

        public init(network: Network, reference: SIMD2<Double>) {
            self.network = network
            self.reference = reference
            let h = network.header
            let bins = h.yieldBins ?? 1
            empty =
                h.kind == "distance"
                ? (0..<(h.grid * h.grid * bins)).map { network.inDisc[$0 / bins] ? 0 : -.infinity } : []
            joint = empty
        }

        /// Whether a mark is taken in on its own (the network "distance"), rather than the whole set
        /// weighed again.
        public var incremental: Bool { !joint.isEmpty }

        /// Gives building `id` the mark `mark`, or clears it (nil, or a mark with nothing seen).
        public mutating func set(_ mark: Mark?, for id: UUID) {
            let clock = ContinuousClock.now
            let kept = mark.flatMap { $0.glass == nil && $0.walls == nil ? nil : $0 }
            let old = marks[id]
            guard old != kept else { return }
            if incremental {
                if let old { network.addDistance(old, reference: reference, to: &joint, weight: -1) }
                if let kept { network.addDistance(kept, reference: reference, to: &joint) }
            }
            if let kept {
                if old == nil { order.append(id) }
                marks[id] = kept
            } else {
                marks[id] = nil
                order.removeAll { $0 == id }
            }
            // Cleared to none, the sum is zero again, exactly.
            if marks.isEmpty { joint = empty }
            reweigh()
            lastSeconds = StudyClock.seconds(clock)
        }

        /// Every mark at once, in place of those given (in their order), the sum worked out again.
        public mutating func replaceAll(_ list: [(id: UUID, mark: Mark)]) {
            let clock = ContinuousClock.now
            marks = [:]
            order = []
            for (id, mark) in list where mark.glass != nil || mark.walls != nil {
                if marks[id] == nil { order.append(id) }
                marks[id] = mark
            }
            rebuild()
            lastSeconds = StudyClock.seconds(clock)
        }

        /// Searches about `place` (the scene's metres): the sum worked out again about it.
        public mutating func recentre(on place: SIMD2<Double>) {
            guard place != reference else { return }
            let clock = ContinuousClock.now
            reference = place
            rebuild()
            lastSeconds = StudyClock.seconds(clock)
        }

        /// The marks in the order given.
        public var orderedMarks: [Mark] { order.compactMap { marks[$0] } }

        /// The summed log likelihood from nothing, the marks spread over the cores.
        private mutating func rebuild() {
            if incremental {
                let list = orderedMarks
                let parts = min(max(list.count / 16, 1), 8)
                var sums = [[Float]](repeating: [], count: parts)
                let size = joint.count
                let network = network
                let reference = reference
                sums.withUnsafeMutableBufferPointer { out in
                    concurrently(iterations: parts) { p in
                        var part = [Float](repeating: 0, count: size)
                        for k in stride(from: p, to: list.count, by: parts) {
                            network.addDistance(list[k], reference: reference, to: &part)
                        }
                        out[p] = part
                    }
                }
                var total = empty
                for part in sums { for i in 0..<size where part[i] != 0 { total[i] += part[i] } }
                joint = total
            }
            reweigh()
        }

        private mutating func reweigh() {
            guard !marks.isEmpty else {
                posterior = nil
                return
            }
            posterior =
                incremental
                ? network.posterior(joint: joint, reference: reference)
                : network.posterior(marks: orderedMarks, reference: reference)
        }
    }

    /// What a building's damage, as a run or the quick estimate judged it, would be marked: its glass
    /// broken where some pane broke (for a façade's glazing mix, where some pane more likely broke
    /// than not), whole otherwise, unseen without glass; its walls by their worst level with simply
    /// supported edges (as `structureProbabilities` counts them, which the network learned from),
    /// undamaged below moderate, heavily damaged from heavy, unseen without walls judged.
    public static func seen(_ damage: EnvelopeBuildingDamage) -> (glass: GlassSeen?, walls: WallsSeen?) {
        var glass: GlassSeen?
        if let mix = damage.glass, mix.panes > 0 {
            glass = damage.panesBroken > 0 || 1 - exp(mix.logNoneBroken) > 0.5 ? .broken : .whole
        } else if damage.panes > 0 {
            glass = damage.panesBroken > 0 ? .broken : .whole
        }
        let walls = damage.components.filter {
            ($0.kind == .wall || $0.kind == .facade) && !$0.material.isGlass
        }
        var seen: WallsSeen?
        if let worst = walls.map(\.levels.upperBound).max() {
            seen = worst < .moderate ? .undamaged : worst < .heavy ? .damaged : .heavy
        }
        return (glass, seen)
    }
}

extension ChargeFromDamage.Posterior {
    /// Each cell's shade on the view's colour scale, from 0 to 1: its probability against the
    /// likeliest cell's, over `decades` decades (1 at the likeliest, 0 at 10^−decades of it and
    /// below, and where it holds none).
    public func shades(decades: Double = 2) -> [Float] {
        let most = cellProbabilities.max() ?? 0
        guard most > 0 else { return cellProbabilities.map { _ in 0 } }
        return cellProbabilities.map { p in
            p > 0 ? Float(min(max(1 + log10(p / most) / decades, 0), 1)) : 0
        }
    }

    /// The edges round the region holding `mass` (`region`), each between a cell in it and one out
    /// of it (or the square's edge), as pairs of ends in the scene's metres.
    public func outline(_ mass: Double) -> [(SIMD2<Double>, SIMD2<Double>)] {
        let inside = Set(region(mass))
        let size = cellSizeM
        let corner = reference - halfWidthM
        func held(_ i: Int, _ j: Int) -> Bool {
            (0..<grid).contains(i) && (0..<grid).contains(j) && inside.contains(j * grid + i)
        }
        func at(_ i: Int, _ j: Int) -> SIMD2<Double> { corner + size * SIMD2(Double(i), Double(j)) }
        var edges: [(SIMD2<Double>, SIMD2<Double>)] = []
        for c in inside.sorted() {
            let i = c % grid
            let j = c / grid
            if !held(i - 1, j) { edges.append((at(i, j), at(i, j + 1))) }
            if !held(i + 1, j) { edges.append((at(i + 1, j), at(i + 1, j + 1))) }
            if !held(i, j - 1) { edges.append((at(i, j), at(i + 1, j))) }
            if !held(i, j + 1) { edges.append((at(i, j + 1), at(i + 1, j + 1))) }
        }
        return edges
    }

    /// The radius about `place` (the scene's metres) of the disc whose cells hold `mass`, by the
    /// cells' middles, m.
    public func radius(holding mass: Double, about place: SIMD2<Double>) -> Double {
        let byDistance = cellProbabilities.indices.map { (simd_distance(middle($0), place), $0) }
            .sorted { $0.0 < $1.0 }
        var sum = 0.0
        for (d, c) in byDistance {
            sum += cellProbabilities[c]
            if sum >= mass { return d + 0.5 * cellSizeM }
        }
        return byDistance.last.map { $0.0 + 0.5 * cellSizeM } ?? 0
    }

    /// One of the eight points of the compass for a way east and north.
    static func compass(_ way: SIMD2<Double>) -> String {
        let names = [
            "east", "north-east", "north", "north-west", "west", "south-west", "south", "south-east",
        ]
        let angle = atan2(way.y, way.x)
        let k = Int(((angle / (.pi / 4)).rounded() + 8).truncatingRemainder(dividingBy: 8))
        return names[k]
    }

    /// A distance in words: to 10 m below a kilometre, else to 0.1 km.
    static func distance(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.1f km", m / 1000) : String(format: "%.0f m", (m / 10).rounded() * 10)
    }

    /// The place and the yield in words, for the panel and VoiceOver: the likeliest place from
    /// `about` (named `aboutName`), how far round it holds half the chance and nine tenths, and the
    /// yield's median and 90% interval. "Most likely 120 m north-east of the scene's charge; half the
    /// chance within 150 m of there, nine in ten within 310 m. Yield about 0.52 kt; nine in ten
    /// between 0.21 and 1.4 kt."
    public func spoken(about: SIMD2<Double>, aboutName: String) -> String {
        let likeliest = mostProbablePlace
        let way = likeliest - about
        let off = simd_length(way)
        let place =
            off < 0.5 * cellSizeM
            ? "Most likely at \(aboutName)"
            : "Most likely \(Self.distance(off)) \(Self.compass(way)) of \(aboutName)"
        return
            "\(place); half the chance within \(Self.distance(radius(holding: 0.5, about: likeliest))) of there, nine in ten within \(Self.distance(radius(holding: 0.9, about: likeliest))). Yield about \(Self.mass(yieldQuantile(0.5))); nine in ten between \(Self.mass(yieldQuantile(0.05))) and \(Self.mass(yieldQuantile(0.95)))."
    }
}
