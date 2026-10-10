import Foundation

/// One horizontal layer of soil in a column under a ground point.
public struct SoilLayer: Codable, Sendable, Equatable {
    /// Metres.
    public var thickness: Float
    /// Bulk density, kg/m³.
    public var density: Float
    /// The speed of a compression wave loading the soil beyond anything it has carried before
    /// (its loading wave speed), m/s: the constrained modulus on first loading is ρc².
    public var waveSpeed: Float
    /// The speed of a compression wave unloading or reloading it, m/s, at least `waveSpeed`; nil
    /// for the same, an elastic layer. Stiffer unloading leaves the soil compacted and wears
    /// the peak down as the wave goes deeper.
    public var unloadingWaveSpeed: Float?
    /// The Rayleigh damping ratio at the profile's two damping frequencies; 0 for none.
    public var damping: Float

    public init(
        thickness: Float, density: Float, waveSpeed: Float, unloadingWaveSpeed: Float? = nil,
        damping: Float = 0
    ) {
        self.thickness = thickness
        self.density = density
        self.waveSpeed = waveSpeed
        self.unloadingWaveSpeed = unloadingWaveSpeed
        self.damping = damping
    }

    private enum CodingKeys: String, CodingKey {
        case thickness, density, waveSpeed, unloadingWaveSpeed, damping
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GroundSoil()
        thickness = try c.decode(Float.self, forKey: .thickness)
        density = try c.decodeIfPresent(Float.self, forKey: .density) ?? d.density
        waveSpeed = try c.decodeIfPresent(Float.self, forKey: .waveSpeed) ?? d.waveSpeed
        unloadingWaveSpeed = try c.decodeIfPresent(Float.self, forKey: .unloadingWaveSpeed)
        damping = try c.decodeIfPresent(Float.self, forKey: .damping) ?? 0
    }

    /// The unloading wave speed, the loading one if none is given.
    public var unloadingSpeed: Float { max(unloadingWaveSpeed ?? waveSpeed, waveSpeed) }
}

/// What lies under the last layer.
public enum SoilBase: Codable, Sendable, Equatable {
    /// Rock too stiff to move: the bottom of the last layer is held still, and waves come back
    /// up from it whole.
    case rigid
    /// An elastic half-space without end: waves going into it are carried away, through a
    /// dashpot of its impedance ρc at the column's foot (Lysmer and Kuhlemeyer's boundary).
    case halfSpace(density: Float, waveSpeed: Float)

    private enum CodingKeys: String, CodingKey { case density, waveSpeed }

    /// `"rigid"`, or `{"density": …, "waveSpeed": …}` for a half-space.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            guard name == "rigid" else {
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "A soil base is \"rigid\" or a half-space's density and wave speed.")
            }
            self = .rigid
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GroundSoil()
        self = .halfSpace(
            density: try c.decodeIfPresent(Float.self, forKey: .density) ?? d.density,
            waveSpeed: try c.decodeIfPresent(Float.self, forKey: .waveSpeed) ?? d.waveSpeed)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .rigid:
            var single = encoder.singleValueContainer()
            try single.encode("rigid")
        case .halfSpace(let density, let waveSpeed):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(density, forKey: .density)
            try c.encode(waveSpeed, forKey: .waveSpeed)
        }
    }
}

/// The soil under every ground point: layers from the surface down, and what lies beneath them.
public struct SoilProfile: Codable, Sendable, Equatable {
    public var layers: [SoilLayer]
    /// Nil for the last layer going on for ever: an elastic half-space of its density and loading
    /// wave speed, the column itself carried down far enough below the deepest depth asked for
    /// that its own unloading is kept.
    public var base: SoilBase?
    /// The two frequencies, Hz, at which each layer's Rayleigh damping has its ratio; between them
    /// it is a little less, outside them more.
    public var dampingFrequencies: SIMD2<Float>
    /// The time step the column aims for, s; less where a thin or damped layer needs it.
    public var timeStep: Float

    public static let defaultDampingFrequencies = SIMD2<Float>(10, 500)
    public static let defaultTimeStep: Float = 5e-5

    public init(
        layers: [SoilLayer], base: SoilBase? = nil,
        dampingFrequencies: SIMD2<Float> = Self.defaultDampingFrequencies,
        timeStep: Float = Self.defaultTimeStep
    ) {
        self.layers = layers
        self.base = base
        self.dampingFrequencies = dampingFrequencies
        self.timeStep = timeStep
    }

    /// One layer of `soil`, elastic and going on for ever: the uniform soil of the manuals' estimate.
    public init(uniform soil: GroundSoil) {
        self.init(layers: [SoilLayer(thickness: 1, density: soil.density, waveSpeed: soil.waveSpeed)])
    }

    private enum CodingKeys: String, CodingKey { case layers, base, dampingFrequencies, timeStep }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layers = try c.decode([SoilLayer].self, forKey: .layers)
        base = try c.decodeIfPresent(SoilBase.self, forKey: .base)
        dampingFrequencies =
            try c.decodeIfPresent(SIMD2<Float>.self, forKey: .dampingFrequencies)
            ?? Self.defaultDampingFrequencies
        timeStep = try c.decodeIfPresent(Float.self, forKey: .timeStep) ?? Self.defaultTimeStep
    }

    /// The layers' total thickness, m.
    public var thickness: Float { layers.reduce(0) { $0 + $1.thickness } }

    /// The soil at the surface, as the manuals' estimate and the dots' colours take it.
    public var surface: GroundSoil {
        GroundSoil(density: layers.first?.density ?? 1600, waveSpeed: layers.first?.waveSpeed ?? 300)
    }

    /// The loading wave speed at `depth`, m/s, for the angle the soil's wave trails the air's
    /// front at there; nil below a rigid base.
    public func waveSpeed(at depth: Float) -> Float? {
        var top: Float = 0
        for layer in layers {
            if depth < top + layer.thickness { return layer.waveSpeed }
            top += layer.thickness
        }
        switch base {
        case .rigid: return depth <= top ? layers.last?.waveSpeed : nil
        case .halfSpace(_, let waveSpeed): return waveSpeed
        case nil: return layers.last?.waveSpeed
        }
    }

    public var isValid: Bool {
        func positive(_ value: Float) -> Bool { value.isFinite && value > 0 }
        let base: Bool
        switch self.base {
        case .halfSpace(let density, let waveSpeed): base = positive(density) && positive(waveSpeed)
        case .rigid, nil: base = true
        }
        return (1...32).contains(layers.count) && base
            && layers.allSatisfy { layer in
                positive(layer.thickness) && layer.thickness <= 1000 && positive(layer.density)
                    && positive(layer.waveSpeed)
                    && (layer.unloadingWaveSpeed.map { positive($0) && $0 >= layer.waveSpeed } ?? true)
                    && layer.damping.isFinite && (0...0.5).contains(layer.damping)
            }
            && positive(dampingFrequencies.x) && dampingFrequencies.y.isFinite
            && dampingFrequencies.y > dampingFrequencies.x && positive(timeStep) && timeStep <= 0.01
    }
}

/// The overpressure on the ground between frames, rebuilt from what each frame gives: the
/// overpressure then, and the solver's peak and positive impulse so far, kept every time step.
/// Frames a millisecond apart are coarser than a shock's rise, so the load is drawn as straight
/// lines between frames that keep both. Where the peak rose above the frame values, the shock
/// arrives and rises to that peak, then falls in a line to the next frame's value, its arrival
/// placed so the interval's impulse is the solver's. It rises over the time its front takes to
/// cross one of the solver's cells, as wide as the solver's own shock is, rather than at once,
/// which the soil's grid could not carry without ringing. Elsewhere the load runs in a line
/// through a midpoint chosen to keep the impulse, within zero and the peak.
public struct GroundLoad: Sendable, Equatable {
    /// (time s, overpressure Pa).
    public private(set) var knots: [(time: Double, pressure: Double)] = []
    private var last: (time: Double, pressure: Double, peak: Double, impulse: Double)?

    public init() {}

    public static func == (a: Self, b: Self) -> Bool {
        a.knots.elementsEqual(b.knots) { $0.time == $1.time && $0.pressure == $1.pressure }
    }

    /// The time the load is known to.
    public var end: Double { knots.last?.time ?? 0 }

    /// Adds a frame: the overpressure at `time`, the peak and positive impulse so far, and how
    /// long a shock takes to rise, s.
    public mutating func append(
        time: Double, overpressure: Float, peak: Float, impulse: Float, rise: Double = 0
    ) {
        let now = (time: time, pressure: Double(overpressure), peak: Double(peak), impulse: Double(impulse))
        defer { last = now }
        guard let a = last else {
            // A blast already over the ground at the first frame, laid down then: it rises from
            // nothing as a shock would.
            knots =
                now.pressure > 0 && rise > 0
                ? [(time, 0), (time + rise, now.pressure)] : [(time, now.pressure)]
            return
        }
        let span = now.time - a.time
        guard span > 0, now.time > end else { return }
        let rose = now.peak > a.peak * (1 + 1e-6) && now.peak > max(a.pressure, now.pressure)
        let gained = max(now.impulse - a.impulse, 0)
        let start = max(end, a.time)
        if rose {
            // A rise to the peak over τ ± h, then a line to the frame's value, carries the
            // positive impulse a⁺τ + hK + (span − τ − h)(K + b⁺)/2: τ so that it is the solver's.
            let before = max(a.pressure, 0)
            let after = (now.peak + max(now.pressure, 0)) / 2
            func arrival(_ h: Double) -> Double {
                guard after > before else { return 0 }
                return min(max(((span - h) * after + h * now.peak - gained) / (after - before), 0), span)
            }
            var half = rise / 2
            var jump = a.time + arrival(half)
            let room = min(half, jump - start, now.time - jump)
            if room < half {
                half = max(room, 0)
                jump = a.time + arrival(half)
                half = max(min(half, jump - start, now.time - jump), 0)
            }
            if half > 0 {
                knots.append((jump - half, a.pressure))
                knots.append((jump + half, now.peak))
            } else {
                knots.append((jump, a.pressure))
                knots.append((jump, now.peak))
            }
        } else if a.pressure >= 0, now.pressure >= 0, start == a.time {
            // Through a midpoint whose line keeps the impulse: (a + 2m + b)/4 = impulse / span.
            let middle = 2 * gained / span - (a.pressure + now.pressure) / 2
            knots.append((a.time + span / 2, min(max(middle, 0), max(now.peak, a.pressure, now.pressure))))
        }
        if now.time > end { knots.append((now.time, now.pressure)) }
    }

    /// The load's integral over [from, to], Pa·s, zero before its first knot and held at its
    /// last after the last.
    public func integral(from start: Double, to end: Double) -> Double {
        guard let first = knots.first, end > start else { return 0 }
        var sum = 0.0
        var previous = first
        for knot in knots.dropFirst() {
            defer { previous = knot }
            let low = max(previous.time, start)
            let high = min(knot.time, end)
            guard high > low, knot.time > previous.time else { continue }
            let slope = (knot.pressure - previous.pressure) / (knot.time - previous.time)
            let pLow = previous.pressure + slope * (low - previous.time)
            let pHigh = previous.pressure + slope * (high - previous.time)
            sum += (pLow + pHigh) / 2 * (high - low)
        }
        if let last = knots.last, end > last.time { sum += last.pressure * (end - max(last.time, start)) }
        return sum
    }

    /// Drops the knots wholly before `time`, keeping the one the load starts from.
    public mutating func forget(before time: Double) {
        guard let keep = knots.lastIndex(where: { $0.time <= time }), keep > 0 else { return }
        knots.removeFirst(keep)
    }
}

/// A one-dimensional column of layered soil under a ground point, pressed at its top by the
/// air's overpressure: a vertical compression wave runs down it, through each layer's density,
/// wave speeds and damping, is partly sent back at each change of layer, and is taken away into
/// a half-space beneath or sent back whole from rock.
///
/// Explicit central differences in time on a lumped-mass grid of nodes and elements, a column of
/// one-dimensional finite elements (equivalently a staggered velocity–stress grid). Each layer is
/// cut into elements that a wave at its unloading speed crosses in a step, so an elastic
/// undamped layer runs at a Courant number of one, where the scheme carries a wave, even a
/// shock's jump, without error; just below one, a jump would ring up to a fifth higher. A
/// layer's thickness is rounded to a whole number of elements. Soil loads along ρc² and unloads
/// and reloads along ρc_u², a bilinear hysteresis (the protective design literature's simplest
/// model of soil under air blast, as in Newmark and Haltiwanger): what it has carried before it
/// carries stiffly again, and only beyond that does it give at its loading modulus. Damping is Rayleigh's, mass- and stiffness-proportional, the mass part
/// centred in time and the stiffness part from the last half-step's strain rate, the step
/// shortened to keep it stable. Compression and downward motion are positive.
public struct SoilColumn: Sendable {
    public let profile: SoilProfile
    /// The time step, s.
    public let timeStep: Double
    /// Each node's depth, m, the surface first.
    public let depths: [Double]
    /// The stress, Pa, whose first passing in an element marks the wave's arrival there.
    public let arrivalThreshold: Double
    /// The time reached, s: the nodes' displacements are at it, their velocities half a step behind.
    public private(set) var time = 0.0
    /// The highest load the top has carried, Pa (each step's mean).
    public private(set) var peakLoad = 0.0

    /// The energy, J/m²: the work the load has done on the column's top, that lost to damping and
    /// carried away into the half-space, and the work done straining the soil, stored and lost
    /// to its hysteresis together.
    public private(set) var work = 0.0
    public private(set) var damped = 0.0
    public private(set) var radiated = 0.0
    public private(set) var strainWork = 0.0

    private let elements: Int
    private let baseImpedance: Double
    private let rigidBase: Bool
    /// Everything per element and per node in one buffer, `Field` by `Field`, and where each starts.
    private var storage: [Double]
    private let offsets: [Int]

    private enum Field: Int, CaseIterable {
        // Per element.
        case thickness, loadingModulus, unloadingModulus, stiffnessDamping
        case stress, viscous, envelopeStrain, envelopeStress, peakStress, arrival
        // Per node.
        case mass, massDamping, displacement, velocity, previous, peakVelocity, peakDisplacement

        var perNode: Bool { rawValue >= Field.mass.rawValue }
    }

    private func offset(_ field: Field) -> Int { Self.offset(field, elements: elements) }

    private static func offset(_ field: Field, elements: Int) -> Int {
        field.perNode
            ? Field.mass.rawValue * elements + (field.rawValue - Field.mass.rawValue) * (elements + 1)
            : field.rawValue * elements
    }

    private func values(_ field: Field) -> ArraySlice<Double> {
        let start = offset(field)
        return storage[start..<(start + (field.perNode ? elements + 1 : elements))]
    }

    /// Builds the column down to at least `depth` m (the deepest depth asked for), with the
    /// profile's layers and base.
    public init(profile: SoilProfile, depth: Float, arrivalThreshold: Float = 1000) {
        self.profile = profile
        self.arrivalThreshold = Double(arrivalThreshold)
        typealias Layer = (
            thickness: Double, density: Double, loading: Double, unloading: Double, damping: Double
        )
        var layers: [Layer] = profile.layers.map { layer in
            (
                Double(layer.thickness), Double(layer.density), Double(layer.waveSpeed),
                Double(layer.unloadingSpeed), Double(layer.damping)
            )
        }
        let total = layers.reduce(0) { $0 + $1.thickness }
        switch profile.base {
        case .rigid:
            baseImpedance = 0
            rigidBase = true
        case .halfSpace(let density, let waveSpeed):
            // Asked below the layers, the column goes on in the half-space's soil.
            let below = Double(depth) - total
            if below > 0 {
                layers.append((below * 1.25 + 1, Double(density), Double(waveSpeed), Double(waveSpeed), 0))
            }
            baseImpedance = Double(density * waveSpeed)
            rigidBase = false
        case nil:
            // The last layer going on for ever. Its unloading is stiffer than the dashpot takes, so
            // carry it on below the deepest depth asked for by half that again and two metres:
            // what the foot sends back then follows the peak well behind.
            let bottom = max(total, Double(depth) * 1.5 + 2)
            if bottom > total, var last = layers.last {
                last.thickness = bottom - total
                layers.append(last)
            }
            baseImpedance = layers.last.map { $0.density * $0.loading } ?? 0
            rigidBase = false
        }
        let omega = 2 * Double.pi * SIMD2<Double>(profile.dampingFrequencies)
        // Rayleigh: ξ(ω) = α/(2ω) + βω/2, the ratio given at both frequencies.
        let rayleigh = layers.map { layer -> (alpha: Double, beta: Double) in
            (
                2 * layer.damping * omega.x * omega.y / (omega.x + omega.y),
                2 * layer.damping / (omega.x + omega.y)
            )
        }
        // An element h thick, at speed c and stiffness damping β, is stable for
        // c²(Δt² + 2βΔt) ≤ h². Shorten the step until each layer takes two elements.
        var dt = Double(profile.timeStep)
        for (layer, damping) in zip(layers, rayleigh) {
            let h = layer.thickness / 2 / layer.unloading
            dt = min(dt, -damping.beta + (damping.beta * damping.beta + h * h).squareRoot())
        }
        timeStep = dt
        // Each element as thin as is stable, so an elastic undamped layer runs at a Courant
        // number of one, where the scheme carries even a jump without error; a layer's
        // thickness rounds to a whole number of them, its interfaces within half an element.
        var elementData: [(h: Double, layer: Layer, alpha: Double, beta: Double)] = []
        for (layer, damping) in zip(layers, rayleigh) {
            let h = layer.unloading * (dt * dt + 2 * damping.beta * dt).squareRoot() * (1 + 1e-12)
            let count = max(Int((layer.thickness / h).rounded()), 1)
            for _ in 0..<count { elementData.append((h, layer, damping.alpha, damping.beta)) }
        }
        let count = elementData.count
        elements = count
        var storage = [Double](repeating: 0, count: Field.mass.rawValue * count + 7 * (count + 1))
        var depths = [0.0]
        for (e, element) in elementData.enumerated() {
            let (h, layer) = (element.h, element.layer)
            depths.append(depths[e] + h)
            storage[Self.offset(.thickness, elements: count) + e] = h
            storage[Self.offset(.loadingModulus, elements: count) + e] =
                layer.density * layer.loading * layer.loading
            storage[Self.offset(.unloadingModulus, elements: count) + e] =
                layer.density * layer.unloading * layer.unloading
            storage[Self.offset(.stiffnessDamping, elements: count) + e] = element.beta
            storage[Self.offset(.arrival, elements: count) + e] = -1
            for node in [e, e + 1] {
                storage[Self.offset(.mass, elements: count) + node] += layer.density * h / 2
                storage[Self.offset(.massDamping, elements: count) + node] +=
                    element.alpha * layer.density * h / 2
            }
        }
        self.storage = storage
        offsets = Field.allCases.map { Self.offset($0, elements: count) }
        self.depths = depths
    }

    public var elementCount: Int { elements }

    /// Each element's peak stress, Pa, and the time it first passed the arrival threshold, s
    /// (−1 if not yet): at the elements' mid-depths.
    public var peakStress: [Double] { Array(values(.peakStress)) }
    public var arrivals: [Double] { Array(values(.arrival)) }
    /// Each node's peak downward velocity, m/s, and displacement, m, and its velocity now and
    /// displacement now.
    public var peakVelocity: [Double] { Array(values(.peakVelocity)) }
    public var peakDisplacement: [Double] { Array(values(.peakDisplacement)) }
    public var velocities: [Double] { Array(values(.velocity)) }
    public var displacements: [Double] { Array(values(.displacement)) }
    /// Each element's stress now, Pa.
    public var stresses: [Double] { Array(values(.stress)) }

    /// The elements' mid-depths, m.
    public var elementDepths: [Double] { (0..<elements).map { (depths[$0] + depths[$0 + 1]) / 2 } }

    /// The kinetic energy at the last half-step, J/m².
    public var kineticEnergy: Double {
        zip(values(.mass), values(.velocity)).reduce(0) { $0 + $1.0 * $1.1 * $1.1 / 2 }
    }

    /// The elastic energy the soil would give back on unloading to zero stress, J/m²: σ²/(2ρc_u²)
    /// an element.
    public var recoverableEnergy: Double {
        zip(zip(values(.stress), values(.unloadingModulus)), values(.thickness)).reduce(0) {
            $0 + $1.0.0 * $1.0.0 / (2 * $1.0.1) * $1.1
        }
    }

    /// The energy the soil's hysteresis has lost so far, J/m²: strain work not given back.
    public var hystereticLoss: Double { strainWork - recoverableEnergy }

    /// Linear interpolation of node values at `depth`, the deepest node's below the column.
    public func atNodes(_ values: [Double], depth: Double) -> Double {
        Self.interpolate(values, at: depths, depth: depth)
    }

    /// Linear interpolation of element values at `depth`, between mid-depths; `surface` at the top.
    public func atElements(_ values: [Double], depth: Double, surface: Double) -> Double {
        Self.interpolate([surface] + values, at: [0] + elementDepths, depth: depth)
    }

    private static func interpolate(_ values: [Double], at positions: [Double], depth: Double) -> Double {
        guard let upper = positions.firstIndex(where: { $0 >= depth }) else { return values.last ?? 0 }
        guard upper > 0 else { return values[0] }
        let f = (depth - positions[upper - 1]) / (positions[upper] - positions[upper - 1])
        return values[upper - 1] + f * (values[upper] - values[upper - 1])
    }

    /// Advances one step, the top pressed by `load` Pa on average over the step's span, t ± Δt/2.
    /// The work done on the column balances the kinetic energy at the new half-step, the strain
    /// work, damping and radiation exactly: the central difference's own energy identity.
    public mutating func step(load: Double) {
        let dt = timeStep
        let n = elements
        let (rigid, impedance, threshold, now) = (rigidBase, baseImpedance, arrivalThreshold, time)
        let o = offsets
        var (work, damped, radiated, strainWork) = (0.0, 0.0, 0.0, 0.0)
        storage.withUnsafeMutableBufferPointer { b in
            func f(_ field: Field) -> UnsafeMutablePointer<Double> { b.baseAddress! + o[field.rawValue] }
            let (h, loading, unloading, beta) = (
                f(.thickness), f(.loadingModulus), f(.unloadingModulus), f(.stiffnessDamping)
            )
            let (s, q, strainMax, stressMax) = (
                f(.stress), f(.viscous), f(.envelopeStrain), f(.envelopeStress)
            )
            let (peak, arrival, m, c) = (f(.peakStress), f(.arrival), f(.mass), f(.massDamping))
            let (u, v, old, vMax, uMax) = (
                f(.displacement), f(.velocity), f(.previous), f(.peakVelocity), f(.peakDisplacement)
            )
            // Stresses at t.
            for e in 0..<n {
                let strain = (u[e] - u[e + 1]) / h[e]
                let sigma: Double
                if strain >= strainMax[e] {
                    sigma = loading[e] * strain
                    strainMax[e] = strain
                    stressMax[e] = sigma
                } else {
                    sigma = stressMax[e] - unloading[e] * (strainMax[e] - strain)
                }
                s[e] = sigma
                q[e] = beta[e] * loading[e] * (v[e] - v[e + 1]) / h[e]
                if sigma > peak[e] {
                    peak[e] = sigma
                    if arrival[e] < 0, sigma >= threshold { arrival[e] = now }
                }
            }
            // Velocities at t + Δt/2, the damping centred between the half-steps.
            var above = load
            for j in 0...n {
                let below = j < n ? s[j] + q[j] : 0
                let resist = c[j] + (j == n ? impedance : 0)
                old[j] = v[j]
                v[j] = (v[j] * (m[j] / dt - resist / 2) + above - below) / (m[j] / dt + resist / 2)
                if j == n, rigid { v[j] = 0 }
                let mean = (old[j] + v[j]) / 2
                damped += c[j] * mean * mean * dt
                if j == n { radiated += impedance * mean * mean * dt }
                above = below
            }
            work += load * (old[0] + v[0]) / 2 * dt
            // Strain and viscous work over t ± Δt/2.
            for e in 0..<n {
                let stretch = ((old[e] + v[e]) - (old[e + 1] + v[e + 1])) / 2 * dt
                strainWork += s[e] * stretch
                damped += q[e] * stretch
            }
            for j in 0...n {
                u[j] += dt * v[j]
                vMax[j] = max(vMax[j], v[j])
                uMax[j] = max(uMax[j], u[j])
            }
        }
        self.work += work
        self.damped += damped
        self.radiated += radiated
        self.strainWork += strainWork
        peakLoad = max(peakLoad, load)
        time += dt
    }

    /// Advances to `time`, as far as whole steps go, pressed by `load`; the steps whose span
    /// reaches beyond what the load knows wait for the next frame.
    public mutating func advance(to end: Double, load: GroundLoad) {
        let dt = timeStep
        while time + dt / 2 <= min(end, load.end) + 1e-12 {
            step(load: load.integral(from: time - dt / 2, to: time + dt / 2) / dt)
        }
    }
}

/// The peak stress of a compression pulse going down a column of bilinear hysteretic soil, by
/// characteristics: the front runs at the loading speed c, the unloading behind it at c_u, and
/// each unloading wave sent down from the top catches the front and wears its peak down. For a
/// surface load σ₀(t) that only falls after its arrival at time zero, the front's stress at depth
/// z is S(z) = 2/(1 + r) Σₙ kⁿ σ₀(kⁿ z/a), with r = c_u/c, k = (r − 1)/(r + 1) and
/// a = c r/(r − 1): each term a characteristic sent down at time kⁿz/a, the series the echo of the
/// one before it off the front and the surface. Derived here (see the ground shock docs); for a
/// triangle of length t_d it falls in a straight line, P[1 − z(1 − 1/r²)/(2c t_d)], to
/// z = c t_d r/(r − 1), then as 1/z.
public enum HystereticAttenuation {
    public static func peakStress(
        depth: Double, loadingSpeed c: Double, unloadingSpeed cu: Double, surface: (Double) -> Double
    ) -> Double {
        guard cu > c * (1 + 1e-9), depth > 0 else { return surface(0) }
        let r = cu / c
        let k = (r - 1) / (r + 1)
        let a = c * r / (r - 1)
        var sum = 0.0
        var weight = 1.0
        while weight > 1e-14 {
            sum += weight * surface(weight * depth / a)
            weight *= k
        }
        return 2 / (1 + r) * sum
    }
}
