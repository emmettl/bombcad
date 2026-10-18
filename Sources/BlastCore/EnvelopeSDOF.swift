import Foundation

/// A building component as an equivalent single degree of freedom, after Biggs (1964) as UFC
/// 3-340-02 (2008, change 2 of 2014; "UFC" below) reproduces it in chapter 3. The deflection at
/// the component's middle, `x`, obeys
///
///     K_LM m ẍ + c ẋ + R(x) = p(t)
///
/// per unit area: `m` its mass per area, `R` its resistance per area (a backbone of pressure
/// against deflection, unloading at the elastic stiffness), `p` the net pressure pushing it in,
/// and `K_LM` the load–mass factor. One way: the air never sees it move.
public struct SDOFSystem: Codable, Hashable, Sendable {
    /// Mass per unit area, kg/m².
    public var massPerArea: Double
    /// Load–mass factors (UFC Tables 3-12 and 3-13). UFC §3-17.4: the elastic factor until the
    /// component first yields, then the mean of the elastic and plastic ones up to 2° of support
    /// rotation, and the plastic one beyond (or at once past yield when no span is given).
    public var loadMassElastic: Double
    public var loadMassPlastic: Double
    /// Resistance against inward deflection: (deflection m, resistance Pa) points beyond (0, 0),
    /// deflection increasing. The first segment is elastic; beyond the last point the resistance
    /// stays at the last value. A last value of 0 is a component that has lost all resistance.
    public var backbone: [SIMD2<Double>]
    /// Resistance against outward deflection (rebound) as a fraction of the inward resistance
    /// (UFC §3-19): the backbone at the furthest inward deflection reached, or at its elastic limit
    /// before that; a component that has lost its inward resistance has none outward either.
    public var reboundFactor: Double
    /// Viscous damping as a fraction of critical, on the elastic period; UFC takes none.
    public var dampingRatio: Double
    /// The span whose support rotation sets the load–mass factor (UFC §3-17.4), m, if known.
    public var span: Double?
    /// A brittle component that stiffens as it deflects (glass, `largeDeflectionGlass`): its
    /// resistance follows the backbone both ways, with no permanent set, until it breaks.
    public var brittle: Brittle?
    /// A laminated pane's interlayer: once the glass has cracked, the plies' fragments held on it
    /// carry the load as a membrane instead of the pane losing its resistance (`LaminatedGlass`).
    public var membrane: Membrane?

    /// A cracked laminated pane as a membrane under uniform tension T (N/m): pressure against
    /// deflection p = shape T x / span², both ways, until it tears (deflection over span reaching
    /// `tearRatio`) or pulls out of its frame (the tension, reached as the deflection grows to
    /// `plateauDeflection`, exceeding the edge's `edgeCapacity`, N/m).
    public struct Membrane: Codable, Hashable, Sendable {
        public var tension: Double
        public var shape: Double
        public var span: Double
        public var tearRatio: Double
        public var plateauDeflection: Double
        public var edgeCapacity: Double?

        public init(
            tension: Double, shape: Double, span: Double, tearRatio: Double, plateauDeflection: Double,
            edgeCapacity: Double?
        ) {
            self.tension = tension
            self.shape = shape
            self.span = span
            self.tearRatio = tearRatio
            self.plateauDeflection = plateauDeflection
            self.edgeCapacity = edgeCapacity
        }

        /// The resistance at deflection `x`, Pa, either way.
        public func resistance(at x: Double) -> Double { shape * tension * x / (span * span) }

        /// Whether it has torn or pulled out at deflection `x`.
        public func isLost(at x: Double) -> Bool {
            if abs(x) / span >= tearRatio { return true }
            if let edgeCapacity, tension * min(abs(x) / plateauDeflection, 1) > edgeCapacity { return true }
            return false
        }
    }

    /// When a brittle component breaks: its largest principal stress against its deflection, and
    /// glass's static fatigue (Brown's integral), a stress σ(t) breaking it when ∫ (σ/S)ⁿ dt
    /// reaches the reference duration, S its strength held for that long.
    public struct Brittle: Codable, Hashable, Sendable {
        /// (deflection m, largest principal stress Pa) points, deflection increasing.
        public var stress: [SIMD2<Double>]
        /// Pa, held for `referenceDuration`.
        public var strength: Double
        /// s.
        public var referenceDuration: Double
        /// n; nil breaks it as soon as the stress reaches the strength.
        public var fatigueExponent: Double?

        public init(
            stress: [SIMD2<Double>], strength: Double, referenceDuration: Double, fatigueExponent: Double?
        ) {
            self.stress = stress
            self.strength = strength
            self.referenceDuration = referenceDuration
            self.fatigueExponent = fatigueExponent
        }

        /// The largest principal stress at deflection `x` either way, Pa.
        public func stress(at x: Double) -> Double {
            let x = abs(x)
            guard x > stress[0].x else { return stress[0].y * x / stress[0].x }
            for (a, b) in zip(stress, stress.dropFirst()) where x <= b.x {
                return a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)
            }
            return stress.last!.y
        }
    }

    public init(
        massPerArea: Double, loadMassElastic: Double, loadMassPlastic: Double, backbone: [SIMD2<Double>],
        reboundFactor: Double = 1, dampingRatio: Double = 0, span: Double? = nil, brittle: Brittle? = nil,
        membrane: Membrane? = nil
    ) {
        precondition(massPerArea > 0 && loadMassElastic > 0 && loadMassPlastic > 0)
        precondition(!backbone.isEmpty && backbone[0].x > 0 && backbone[0].y > 0)
        precondition(zip(backbone, backbone.dropFirst()).allSatisfy { $0.x < $1.x })
        self.massPerArea = massPerArea
        self.loadMassElastic = loadMassElastic
        self.loadMassPlastic = loadMassPlastic
        self.backbone = backbone
        self.reboundFactor = reboundFactor
        self.dampingRatio = dampingRatio
        self.span = span
        self.brittle = brittle
        self.membrane = membrane
    }

    /// An elastic–perfectly plastic system: stiffness `stiffness` (Pa/m) up to `ultimate` (Pa).
    public static func elasticPlastic(
        massPerArea: Double, stiffness: Double, ultimate: Double, loadMassElastic: Double = 1,
        loadMassPlastic: Double = 1, reboundFactor: Double = 1, span: Double? = nil
    ) -> SDOFSystem {
        SDOFSystem(
            massPerArea: massPerArea, loadMassElastic: loadMassElastic, loadMassPlastic: loadMassPlastic,
            backbone: [SIMD2(ultimate / stiffness, ultimate)], reboundFactor: reboundFactor, span: span)
    }

    /// Elastic stiffness, Pa/m.
    public var stiffness: Double { backbone[0].y / backbone[0].x }
    /// Largest resistance on the backbone, Pa.
    public var ultimateResistance: Double { backbone.map(\.y).max()! }
    /// The equivalent elastic deflection X_E of UFC eqs 3-34 to 3-36: the deflection at the
    /// ultimate resistance on a single line of the same area under the curve up to it.
    public var equivalentElasticDeflection: Double {
        let ultimate = ultimateResistance
        var area = 0.0
        var previous = SIMD2<Double>.zero
        for point in backbone {
            area += 0.5 * (previous.y + point.y) * (point.x - previous.x)
            previous = point
            if point.y == ultimate { break }
        }
        // The deflection where it reaches the ultimate resistance, less the area's excess over a
        // rectangle, is X_E (eq 3-34 for two segments, 3-35 for three).
        return 2 * (previous.x * ultimate - area) / ultimate
    }
    /// Natural period while elastic, s (UFC eq 3-60 on the equivalent elastic stiffness).
    public var period: Double {
        2 * .pi
            * (loadMassElastic * massPerArea * equivalentElasticDeflection / ultimateResistance).squareRoot()
    }

    /// The backbone's resistance at deflection `x` ≥ 0.
    func envelope(_ x: Double) -> Double {
        if x <= backbone[0].x { return stiffness * x }
        for (a, b) in zip(backbone, backbone.dropFirst()) where x <= b.x {
            return a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)
        }
        return backbone.last!.y
    }

    /// The response to a net pressure held at `pressures[i]` over [i·step, (i+1)·step) and then
    /// released, followed until `tail` elastic periods after the load ends. A recorded history's
    /// bins are impulses, so their mean pressures carry the impulse exactly. With `watch` (m), when
    /// the deflection first passes it either way and the velocity then (`passedAt`,
    /// `velocityPassing`): where a construction is taken to fail, for what it throws.
    public func response(pressures: [Double], step: Double, tail: Double = 3, watch: Double? = nil)
        -> SDOFResponse
    {
        precondition(step > 0 && tail >= 0)
        let period = period
        // Velocity Verlet is stable below T/π; T/200 keeps the closed-form cases in the tests
        // within 0.1%.
        // A stiffening backbone's steepest segment sets the shortest period it reaches.
        var steepest = stiffness
        if brittle != nil {
            for (a, b) in zip(backbone, backbone.dropFirst()) where b.y > a.y {
                steepest = max(steepest, (b.y - a.y) / (b.x - a.x))
            }
        }
        let shortest = min(period, 2 * .pi * (loadMassElastic * massPerArea / steepest).squareRoot())
        let substeps = max(1, Int((step / (shortest / 200)).rounded(.up)))
        let h = step / Double(substeps)
        let k = stiffness
        let damping = 2 * dampingRatio * (loadMassElastic * massPerArea * k).squareRoot()
        var x = 0.0
        var v = 0.0
        var permanent = 0.0  // R = k (x − permanent) while elastic
        var yielded = false
        var response = SDOFResponse(
            yieldDeflection: backbone[0].x, equivalentElasticDeflection: equivalentElasticDeflection,
            period: period)
        func loadMass() -> Double {
            guard yielded else { return loadMassElastic }
            if let span, atan(max(abs(x), response.peakDeflection) / (span / 2)) <= 2 * .pi / 180 {
                return 0.5 * (loadMassElastic + loadMassPlastic)
            }
            return loadMassPlastic
        }
        var broken = false
        var cracked = false  // a laminated pane's glass, still held on its interlayer
        var fatigue = 0.0  // ∫ (σ/S)ⁿ dt so far, s
        func resistance(at x: Double) -> Double {
            if brittle != nil {
                // Elastic on the backbone both ways until it breaks; a cracked laminated pane on
                // its interlayer's membrane until that tears or pulls out.
                guard !broken else { return 0 }
                if cracked, let membrane { return membrane.resistance(at: x) }
                return x < 0 ? -reboundFactor * envelope(-x) : envelope(x)
            }
            var r = k * (x - permanent)
            // Inward, the backbone at the furthest inward deflection yet (so unloading and
            // reloading follow the elastic line back to it); outward, the rebound resistance.
            let reached = max(x, response.peakDeflection, backbone[0].x)
            let upper = envelope(reached)
            let outward = max(-x, -response.reboundDeflection, backbone[0].x)
            let lower = -reboundFactor * min(envelope(outward), envelope(reached))
            if r > upper {
                r = upper
                permanent = x - r / k
                yielded = yielded || x > backbone[0].x
            } else if r < lower {
                r = lower
                permanent = x - r / k
                yielded = yielded || -x > backbone[0].x
            }
            return r
        }
        func acceleration(_ p: Double, _ r: Double, _ v: Double) -> Double {
            (p - r - damping * v) / (loadMass() * massPerArea)
        }
        let loaded = pressures.count * substeps
        let total = loaded + Int((tail * period / h).rounded(.up))
        var r = 0.0
        for n in 0..<total {
            // Both half-kicks of a substep take its own load, so each bin's impulse goes in whole.
            let p = n < loaded ? pressures[n / substeps] : 0
            v += 0.5 * h * acceleration(p, r, v)
            x += h * v
            r = resistance(at: x)
            v += 0.5 * h * acceleration(p, r, v)
            let time = Double(n + 1) * h
            if x > response.peakDeflection {
                response.peakDeflection = x
                response.peakTime = time
            }
            if x < response.reboundDeflection {
                response.reboundDeflection = x
                response.reboundTime = time
            }
            if let watch, response.passedAt == nil, abs(x) >= watch {
                response.passedAt = time
                response.velocityPassing = v
            }
            if cracked, !broken, let membrane, membrane.isLost(at: x) {
                broken = true
                response.lostResistanceAt = time
                response.velocityAtLoss = v
                response.deflectionAtLoss = abs(x)
            }
            if let brittle, !broken, !cracked {
                let sigma = brittle.stress(at: x)
                response.peakStress = max(response.peakStress ?? 0, sigma)
                if let n = brittle.fatigueExponent {
                    fatigue += h * pow(sigma / brittle.strength, n)
                    broken = fatigue >= brittle.referenceDuration
                } else {
                    broken = sigma >= brittle.strength
                }
                if broken, membrane != nil {
                    // Laminated: the glass cracks; the pane holds on its interlayer.
                    broken = false
                    cracked = true
                    response.crackedAt = time
                    response.stressAtBreak = sigma
                    response.deflectionAtBreak = abs(x)
                } else if broken {
                    response.lostResistanceAt = time
                    response.velocityAtLoss = v
                    response.stressAtBreak = sigma
                    response.deflectionAtBreak = abs(x)
                }
            }
            if !cracked, response.lostResistanceAt == nil, backbone.last!.y == 0, abs(x) >= backbone.last!.x {
                response.lostResistanceAt = time
                response.velocityAtLoss = v
                if brittle != nil {
                    broken = true
                    response.deflectionAtBreak = abs(x)
                }
            }
        }
        response.residualDeflection = permanent
        if let brittle, let n = brittle.fatigueExponent {
            response.equivalentStress = brittle.strength * pow(fatigue / brittle.referenceDuration, 1 / n)
        }
        return response
    }
}

/// Peak, rebound and permanent deflection of an SDOF system, with what a damage level is judged by.
public struct SDOFResponse: Codable, Hashable, Sendable {
    /// Deflection at the end of the backbone's elastic segment, m.
    public var yieldDeflection: Double
    /// UFC's equivalent elastic deflection X_E, m, which ductility is measured against.
    public var equivalentElasticDeflection: Double
    /// Natural period while elastic, s.
    public var period: Double
    /// Largest inward deflection, m, and when, s.
    public var peakDeflection = 0.0
    public var peakTime = 0.0
    /// Largest outward deflection, as a negative number, m, and when, s (nil if it never went out).
    public var reboundDeflection = 0.0
    public var reboundTime: Double?
    /// When the deflection first passed the deflection watched for, either way, s, and the
    /// velocity then, m/s, inward positive (`SDOFSystem.response(watch:)`).
    public var passedAt: Double?
    public var velocityPassing: Double?
    /// Permanent set at the end, m.
    public var residualDeflection = 0.0
    /// When the deflection, either way, passed the backbone's last point with no resistance left,
    /// if it did.
    public var lostResistanceAt: Double?
    /// Its velocity then, m/s, inward positive.
    public var velocityAtLoss: Double?
    /// A brittle component's largest principal stress reached while whole, Pa, and the stress and
    /// the deflection (m, either way) at which it broke.
    public var peakStress: Double?
    public var stressAtBreak: Double?
    public var deflectionAtBreak: Double?
    /// A brittle component with static fatigue: the stress that, held for its reference duration
    /// (60 s for glass), does what its stress history did while it was whole, Pa
    /// (S (∫ (σ/S)ⁿ dt / t_ref)^(1/n)). For a component that never breaks (its strength set out of
    /// reach), the load's equivalent stress, from which a probability of breaking follows.
    public var equivalentStress: Double?
    /// A laminated pane's: when its glass cracked, s (its interlayer then carries it; it is lost
    /// only when that tears or pulls out, `lostResistanceAt`), and its deflection then, m.
    public var crackedAt: Double?
    public var deflectionAtLoss: Double?

    /// Peak deflection over X_E (UFC §3-14.2).
    public var ductility: Double { peakDeflection / equivalentElasticDeflection }
    /// The same, the larger of the inward and outward deflections: a section with bars in both faces
    /// judged either way alike (UFC 3-340-02 §4-26.2).
    public var ductilityEitherWay: Double {
        max(peakDeflection, -reboundDeflection) / equivalentElasticDeflection
    }

    /// Support rotation of a span loaded symmetrically, θ = atan(x / (L/2)) in degrees (UFC
    /// Table 3-5; PDC-TR 06-08 §3-2).
    public func supportRotationDegrees(span: Double) -> Double {
        atan(max(peakDeflection, 0) / (span / 2)) * 180 / .pi
    }
}
