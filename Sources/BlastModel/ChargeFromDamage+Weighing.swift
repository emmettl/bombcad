import Foundation
import simd

extension ChargeFromDamage {
    /// How the marks are weighed together (emmettl/bombcad-work#116, stage 3; docs/charge-inference.md,
    /// "Marks that err together"). The network gives each mark's likelihood as if it were the only
    /// one, and stage 2 summed them as independent given the charge. They are not: buildings judged
    /// by the same estimate, or seen by the same surveyor, err together, the more so the nearer, so
    /// that summed they make the posterior far too sure once they are many. A weighing takes that in
    /// three ways, each off at zero:
    /// - **Neighbours** (`neighbourLengthM`, `neighbourPower`): each mark's log likelihood is scaled by
    ///   one over its neighbours' count to a power, the count the marks' kernel
    ///   e^(−½ (d / L)²) summed (itself 1), so that a cluster of marks counts as about one.
    /// - **A correlation shared by all** (`sharedCorrelation`, ρ): the summed log likelihood scaled by
    ///   1 / (1 + (n − 1) ρ), n the marks' weights summed: equicorrelated marks' effective number.
    /// - **A shared error** of the yield (`sharedLogYieldSD`, in ln kg) and of the place
    ///   (`sharedPlaceSDM`): the marks' likelihood taken over a normal offset of the charge that
    ///   every mark shares, so the posterior is the independent one blurred by it. It changes little
    ///   while the marks are few and their posterior wide, and sets a floor to its width once they
    ///   are many.
    ///
    /// Stage 2's is `independent`. Each is known by its name (`named`), as the quick estimate's term
    /// sets are.
    public struct Weighing: Codable, Sendable, Equatable, Hashable {
        public var name: String
        public var neighbourLengthM: Double
        public var neighbourPower: Double
        public var sharedCorrelation: Double
        public var sharedLogYieldSD: Double
        public var sharedPlaceSDM: Double

        public init(
            name: String, neighbourLengthM: Double = 0, neighbourPower: Double = 1,
            sharedCorrelation: Double = 0,
            sharedLogYieldSD: Double = 0, sharedPlaceSDM: Double = 0
        ) {
            self.name = name
            self.neighbourLengthM = neighbourLengthM
            self.neighbourPower = neighbourPower
            self.sharedCorrelation = sharedCorrelation
            self.sharedLogYieldSD = sharedLogYieldSD
            self.sharedPlaceSDM = sharedPlaceSDM
        }

        /// Stage 2's (2 November 2026): every mark independent given the charge.
        public static let independent = Weighing(name: "independent")

        /// Stage 3's (2 November 2026), the panel's and the commands' unless another is chosen: an
        /// error shared by every mark, 0.5 in ln yield (a factor 1.65) and 12 m in place, calibrated
        /// on the quick estimate's own damage on the four made-up districts the network trained on
        /// (docs/charge-inference.md, "Marks that err together"). Neither the neighbours' weights nor
        /// a shared correlation was needed: the place's regions already hold the truth more often
        /// than they say until the marks are very many.
        public static let shared = Weighing(name: "shared", sharedLogYieldSD: 0.5, sharedPlaceSDM: 12)

        /// The panel's and the commands' weighing unless another is chosen.
        public static let adopted = shared

        /// Whether the marks are weighed as independent, as stage 2 weighed them.
        public var isIndependent: Bool {
            neighbourLengthM <= 0 && sharedCorrelation <= 0 && sharedLogYieldSD <= 0 && sharedPlaceSDM <= 0
        }

        /// Whether a mark's weight depends on the others near it.
        public var weighsNeighbours: Bool { neighbourLengthM > 0 && neighbourPower > 0 }

        /// The weighings known by name.
        public static var all: [Weighing] { [independent, shared] }

        /// The weighing named `name`, or one written as its parameters,
        /// `neighbours=L,power=a,rho=r,yield=s,place=m` (any left out zero, the power 1).
        public static func named(_ name: String) -> Weighing? {
            if let known = all.first(where: { $0.name == name }) { return known }
            var w = Weighing(name: name)
            var any = false
            for part in name.split(separator: ",") {
                let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2, let v = Double(kv[1]) else { return nil }
                switch kv[0] {
                case "neighbours": w.neighbourLengthM = v
                case "power": w.neighbourPower = v
                case "rho": w.sharedCorrelation = v
                case "yield": w.sharedLogYieldSD = v
                case "place": w.sharedPlaceSDM = v
                default: return nil
                }
                any = true
            }
            return any ? w : nil
        }

        /// Each mark's weight by its neighbours (1 without them): one over the kernel summed over
        /// every mark, itself included, to `neighbourPower`.
        public func weights(_ places: [SIMD2<Double>]) -> [Double] {
            guard weighsNeighbours else { return places.map { _ in 1 } }
            let reach = 4 * neighbourLengthM
            let scale = -0.5 / (neighbourLengthM * neighbourLengthM)
            // Bucketed by squares of the reach, so that each mark looks at its neighbours alone.
            var buckets: [SIMD2<Int>: [Int]] = [:]
            func key(_ p: SIMD2<Double>) -> SIMD2<Int> {
                SIMD2(Int((p.x / reach).rounded(.down)), Int((p.y / reach).rounded(.down)))
            }
            for (i, p) in places.enumerated() { buckets[key(p), default: []].append(i) }
            return places.map { p in
                let k = key(p)
                var sum = 0.0
                for dx in -1...1 {
                    for dy in -1...1 {
                        for j in buckets[k &+ SIMD2(dx, dy)] ?? [] {
                            let d2 = simd_distance_squared(p, places[j])
                            if d2 < reach * reach { sum += exp(scale * d2) }
                        }
                    }
                }
                return pow(max(sum, 1), -neighbourPower)
            }
        }

        /// The scale on the summed log likelihood for marks whose weights sum to `count`.
        public func sharedScale(count: Double) -> Double {
            guard sharedCorrelation > 0, count > 1 else { return 1 }
            return 1 / (1 + (count - 1) * sharedCorrelation)
        }
    }
}

extension ChargeFromDamage.Network {
    /// The posterior from the marks' summed (weighted) log likelihood `joint` as `weighing` takes it:
    /// scaled by `scale` (`Weighing.sharedScale`), then blurred by its shared error of the yield and
    /// the place.
    public func posterior(
        joint: [Float], reference: SIMD2<Double>, only held: Set<Int>? = nil, scale: Double,
        weighing: ChargeFromDamage.Weighing
    ) -> ChargeFromDamage.Posterior {
        let cells = header.grid * header.grid
        let bins = header.yieldBins ?? 1
        let g = header.grid
        let s = Float(scale)
        var allowed = inDisc
        if let held { for c in 0..<cells where !held.contains(c) { allowed[c] = false } }
        var most = -Float.infinity
        for c in 0..<cells where allowed[c] {
            for k in 0..<bins where joint[c * bins + k].isFinite { most = max(most, s * joint[c * bins + k]) }
        }
        var w = [Double](repeating: 0, count: cells * bins)
        if most.isFinite {
            for c in 0..<cells where allowed[c] {
                for k in 0..<bins where joint[c * bins + k].isFinite {
                    w[c * bins + k] = Double(exp(s * joint[c * bins + k] - most))
                }
            }
        }
        let range = header.yieldRangeKg
        let width = (log(range[1]) - log(range[0])) / Double(bins)
        func kernel(_ sd: Double) -> [Double] {
            let reach = Int((3 * sd).rounded(.up))
            let k = (-reach...reach).map { exp(-0.5 * Double($0 * $0) / (sd * sd)) }
            let total = k.reduce(0, +)
            return k.map { $0 / total }
        }
        // Along the log yield, within each cell; off the ladder's ends lost.
        if weighing.sharedLogYieldSD > 0 {
            let k = kernel(weighing.sharedLogYieldSD / width)
            let reach = k.count / 2
            var row = [Double](repeating: 0, count: bins)
            for c in 0..<cells where allowed[c] {
                for b in 0..<bins {
                    var v = 0.0
                    for (n, f) in k.enumerated() {
                        let q = b + n - reach
                        if q >= 0 && q < bins { v += f * w[c * bins + q] }
                    }
                    row[b] = v
                }
                for b in 0..<bins { w[c * bins + b] = row[b] }
            }
        }
        // Over the place, east then north, bin by bin; outside the disc (or the cells held) lost.
        if weighing.sharedPlaceSDM > 0 {
            let k = kernel(weighing.sharedPlaceSDM / (2 * header.halfWidthM / Double(g)))
            let reach = k.count / 2
            var out = [Double](repeating: 0, count: cells * bins)
            for axis in 0..<2 {
                for j in 0..<g {
                    for i in 0..<g {
                        let c = j * g + i
                        for b in 0..<bins {
                            var v = 0.0
                            for (n, f) in k.enumerated() {
                                let q = (axis == 0 ? i : j) + n - reach
                                guard q >= 0 && q < g else { continue }
                                let d = axis == 0 ? j * g + q : q * g + i
                                v += f * w[d * bins + b]
                            }
                            out[c * bins + b] = v
                        }
                    }
                }
                swap(&w, &out)
            }
            for c in 0..<cells where !allowed[c] { for b in 0..<bins { w[c * bins + b] = 0 } }
        }
        var cellProbabilities = [Double](repeating: 0, count: cells)
        var marginal = [Double](repeating: 0, count: bins)
        for c in 0..<cells {
            for b in 0..<bins {
                cellProbabilities[c] += w[c * bins + b]
                marginal[b] += w[c * bins + b]
            }
        }
        let total = max(cellProbabilities.reduce(0, +), .leastNormalMagnitude)
        return ChargeFromDamage.Posterior(
            grid: g, halfWidthM: header.halfWidthM, reference: reference,
            cellProbabilities: cellProbabilities.map { $0 / total },
            logYields: (0..<bins).map { log(range[0]) + (Double($0) + 0.5) * width },
            yieldProbabilities: marginal.map { $0 / total })
    }

    /// The log likelihood of `mark` alone over the cells and bins (0 outside the disc).
    public func markJoint(_ mark: ChargeFromDamage.Mark, reference: SIMD2<Double>) -> [Float] {
        var joint = [Float](repeating: 0, count: header.grid * header.grid * (header.yieldBins ?? 1))
        addDistance(mark, reference: reference, to: &joint)
        return joint
    }

    /// The posterior of `marks` as `weighing` weighs them.
    public func posterior(
        marks: [ChargeFromDamage.Mark], reference: SIMD2<Double>, weighing: ChargeFromDamage.Weighing,
        only held: Set<Int>? = nil
    ) -> ChargeFromDamage.Posterior {
        let weights = weighing.weights(marks.map { SIMD2($0.building.east, $0.building.north) })
        var joint = [Float](repeating: 0, count: header.grid * header.grid * (header.yieldBins ?? 1))
        for (m, w) in zip(marks, weights) {
            addDistance(m, reference: reference, to: &joint, weight: Float(w))
        }
        for c in 0..<(header.grid * header.grid) where !inDisc[c] {
            for k in 0..<(header.yieldBins ?? 1) { joint[c * (header.yieldBins ?? 1) + k] = -.infinity }
        }
        return posterior(
            joint: joint, reference: reference, only: held,
            scale: weighing.sharedScale(count: weights.reduce(0, +)), weighing: weighing)
    }
}
