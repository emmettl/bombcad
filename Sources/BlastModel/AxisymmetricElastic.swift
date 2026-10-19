import Foundation

/// A layered elastic half-space about a vertical axis, for the ground's motion where waves travel
/// sideways: P, S and Rayleigh waves under a load pressing on the surface, symmetric about the
/// axis. Shaped after ContinuumKit's wave contracts so that it can be extracted later: a checked,
/// immutable grid (this), the surface's pressures as the forcing, prepared receivers
/// (`ElasticReceiver`) and a single-owner stepper (`AxisymmetricElasticStepper`).
///
/// The grid is Virieux's staggered velocity–stress scheme in cylindrical (r, z), z downwards from
/// the surface. With h the spacing, the radial velocity v_r and the shear stress σ_rz sit on the
/// radial nodes r = ih, where symmetry holds both at zero on the axis; the vertical velocity v_z
/// and the normal stresses σ_rr, σ_θθ, σ_zz sit between them at r = (i + ½)h. In depth, v_r and
/// the normal stresses sit at z = jh, the surface at j = 0, and v_z and σ_rz at z = (j + ½)h.
/// Beyond `pmlCells` of the far side and the bottom, an unsplit convolutional perfectly matched
/// layer (Komatitsch and Martin, 2007) takes the waves away.
public struct AxisymmetricElasticGrid: Sendable {
    /// One horizontal layer from the surface down; the last goes on to the grid's bottom.
    public struct Layer: Sendable, Equatable {
        public var thickness: Double
        public var density: Double
        /// Compression (P) and shear (S) wave speeds, m/s.
        public var pWaveSpeed: Double
        public var sWaveSpeed: Double

        /// Soil that yields (stage 3): the speed of a compression wave unloading or reloading it,
        /// m/s, at least `pWaveSpeed` (the column's bilinear law, as compaction along each
        /// direction the soil is squeezed in); its Mohr–Coulomb friction angle, degrees, and
        /// cohesion, Pa, for a Drucker–Prager cap on its shear stress; and its earth pressure at
        /// rest, the horizontal resting stress over the vertical. Nil speed and angle: elastic.
        public var unloadingPWaveSpeed: Double?
        public var frictionAngle: Double?
        public var cohesion: Double
        public var restingRatio: Double

        public init(
            thickness: Double, density: Double, pWaveSpeed: Double, sWaveSpeed: Double,
            unloadingPWaveSpeed: Double? = nil, frictionAngle: Double? = nil, cohesion: Double = 0,
            restingRatio: Double = 0.5
        ) {
            self.thickness = thickness
            self.density = density
            self.pWaveSpeed = pWaveSpeed
            self.sWaveSpeed = sWaveSpeed
            self.unloadingPWaveSpeed = unloadingPWaveSpeed
            self.frictionAngle = frictionAngle
            self.cohesion = cohesion
            self.restingRatio = restingRatio
        }

        /// Whether the layer yields: bilinear in volume or capped in shear.
        public var yields: Bool { unloadingPWaveSpeed != nil || frictionAngle != nil }
        /// The fastest wave it carries, m/s.
        public var fastest: Double { max(pWaveSpeed, unloadingPWaveSpeed ?? pWaveSpeed) }

        public var lambda: Double { density * (pWaveSpeed * pWaveSpeed - 2 * sWaveSpeed * sWaveSpeed) }
        public var mu: Double { density * sWaveSpeed * sWaveSpeed }
    }

    /// Cells along r and z, and their spacing, m.
    public let radialCells: Int
    public let depthCells: Int
    public let spacing: Double
    public let timeStep: Double
    public let layers: [Layer]
    public let pmlCells: Int
    /// The frequency, Hz, about which the perfectly matched layer's frequency shift is set.
    public let dominantFrequency: Double

    // Per integer depth row (normal stresses, v_r) and per half row (v_z, σ_rz).
    package let density: [Double]
    let halfDensity: [Double]
    package let lambda: [Double]
    package let mu: [Double]
    let halfMu: [Double]
    // Yielding, per integer row: whether it yields, its Lamé λ unloading (λ + ρ(c_u² − c_P²)) and
    // the share of a compacting strain that stays (1 − c_P²/c_u²), its cone (α, k) and its
    // resting compressive stresses, Pa, vertical and horizontal.
    package let plastic: [Bool]
    let unloadingLambda: [Double]
    package let compaction: [Double]
    package let alpha: [Double]
    package let strength: [Double]
    let restingVertical: [Double]
    let restingHorizontal: [Double]
    // The surface's soil, if it yields in shear: Rankine's active and passive ratios and the
    // cohesion's share, 2c√K, of each. At the surface the soil carries no resting stress and the
    // vertical stress σ_v is the load's: Mohr–Coulomb holds the horizontal stresses between
    // K_a σ_v − 2c√K_a and K_p σ_v + 2c√K_p in compression; else the elastic surface slides over
    // the yielding soil beneath as a skin, metres a second sideways.
    let surfaceLimits: (active: Double, passive: Double, activeCohesion: Double, passiveCohesion: Double)?
    // The layer's damping profile and coefficients along r and z, at integer and half positions.
    let radialPML: (whole: PML, half: PML)
    let depthPML: (whole: PML, half: PML)

    package struct PML: Sendable {
        package var b: [Double]
        package var a: [Double]
        package var active: [Bool]
    }

    public enum GridError: Error, Equatable {
        case invalid(String)
    }

    /// A vertical pressure on the whole surface, Pa, held before any load (a slab or fill the
    /// ground carries): it adds to the yielding soil's resting stresses, vertical and horizontal.
    public let surcharge: Double

    /// `courant` is the share of the stable step taken: c_P Δt/h ≤ courant/√2.
    public init(
        radialCells: Int, depthCells: Int, spacing: Double, layers: [Layer], pmlCells: Int = 20,
        dominantFrequency: Double = 50, courant: Double = 0.9, timeStep: Double? = nil, surcharge: Double = 0
    ) throws {
        guard radialCells > 2 * pmlCells, depthCells > 2 * pmlCells, spacing > 0, spacing.isFinite,
            surcharge >= 0, surcharge.isFinite,
            !layers.isEmpty, pmlCells >= 0, dominantFrequency > 0, courant > 0, courant <= 1
        else { throw GridError.invalid("The grid's size, spacing or layers are out of range.") }
        for layer in layers {
            guard layer.thickness > 0, layer.density > 0, layer.sWaveSpeed > 0,
                layer.pWaveSpeed > layer.sWaveSpeed * 2.0.squareRoot(), layer.thickness.isFinite,
                (layer.unloadingPWaveSpeed ?? layer.pWaveSpeed) >= layer.pWaveSpeed,
                (layer.frictionAngle ?? 0) >= 0, (layer.frictionAngle ?? 0) < 60, layer.cohesion >= 0,
                layer.restingRatio > 0, layer.restingRatio <= 1
            else {
                throw GridError.invalid("Each layer needs a positive density and c_P > √2 c_S > 0.")
            }
        }
        self.radialCells = radialCells
        self.depthCells = depthCells
        self.spacing = spacing
        self.layers = layers
        self.pmlCells = pmlCells
        self.dominantFrequency = dominantFrequency
        self.surcharge = surcharge
        let fastest = layers.map(\.fastest).max()!
        let stable = courant * spacing / (fastest * 2.0.squareRoot())
        guard (timeStep ?? stable) <= spacing / (fastest * 2.0.squareRoot()) else {
            throw GridError.invalid("The time step is beyond the stable limit.")
        }
        let dt = timeStep ?? stable
        self.timeStep = dt
        func layer(at depth: Double) -> Layer {
            var top = 0.0
            for layer in layers {
                if depth < top + layer.thickness - 1e-9 * spacing { return layer }
                top += layer.thickness
            }
            return layers.last!
        }
        let rows = depthCells + 1
        density = (0..<rows).map { layer(at: Double($0) * spacing).density }
        lambda = (0..<rows).map { layer(at: Double($0) * spacing).lambda }
        mu = (0..<rows).map { layer(at: Double($0) * spacing).mu }
        // Between rows: densities averaged, shear moduli harmonically.
        halfDensity = (0..<rows).map { j in
            let a = layer(at: Double(j) * spacing).density
            let b = layer(at: Double(min(j + 1, depthCells)) * spacing).density
            return (a + b) / 2
        }
        halfMu = (0..<rows).map { j in
            let a = layer(at: Double(j) * spacing).mu
            let b = layer(at: Double(min(j + 1, depthCells)) * spacing).mu
            return 2 * a * b / (a + b)
        }
        // Yielding: the Lamé λ unloading and the share of compacting strain that stays (see
        // `compact`); the Drucker–Prager cone matched to Mohr–Coulomb in triaxial compression, √J₂ ≤ αI₁ + k with I₁ = 3p, so
        // α = 6 sin φ/(√3(3 − sin φ)) on the mean pressure, and k = 6c cos φ/(√3(3 − sin φ)); and
        // the resting stresses under gravity, the vertical the weight above and the horizontal
        // K₀ times it.
        var plastic: [Bool] = []
        var unloadingLambda: [Double] = []
        var compaction: [Double] = []
        var alpha: [Double] = []
        var strength: [Double] = []
        var restingVertical: [Double] = []
        var restingHorizontal: [Double] = []
        var weight = surcharge
        for j in 0..<rows {
            let z = Double(j) * spacing
            let l = layer(at: z)
            if j > 0 { weight += layer(at: z - spacing / 2).density * 9.81 * spacing }
            plastic.append(l.yields)
            let unloading = l.unloadingPWaveSpeed ?? l.pWaveSpeed
            unloadingLambda.append(
                l.lambda + l.density * (unloading * unloading - l.pWaveSpeed * l.pWaveSpeed))
            compaction.append(1 - pow(l.pWaveSpeed / unloading, 2))
            if let angle = l.frictionAngle {
                let sine = sin(angle * .pi / 180)
                alpha.append(6 * sine / (3.0.squareRoot() * (3 - sine)))
                strength.append(6 * l.cohesion * cos(angle * .pi / 180) / (3.0.squareRoot() * (3 - sine)))
            } else {
                alpha.append(0)
                strength.append(.infinity)
            }
            restingVertical.append(weight)
            restingHorizontal.append(l.restingRatio * weight)
        }
        self.plastic = plastic
        self.unloadingLambda = unloadingLambda
        self.compaction = compaction
        self.alpha = alpha
        self.strength = strength
        self.restingVertical = restingVertical
        self.restingHorizontal = restingHorizontal
        if let top = layers.first, let angle = top.frictionAngle {
            let sine = sin(angle * .pi / 180)
            let active = (1 - sine) / (1 + sine)
            surfaceLimits = (
                active, 1 / active, 2 * top.cohesion * active.squareRoot(),
                2 * top.cohesion / active.squareRoot()
            )
        } else {
            surfaceLimits = nil
        }
        // The perfectly matched layer: d = d₀(x/L)², d₀ = 3c ln(1/R)/(2L) for a reflection R of
        // 10⁻⁴, and a frequency shift falling from πf to zero across it.
        func profile(count: Int, offset: Double) -> PML {
            let thickness = Double(pmlCells) * spacing
            let start = Double(count - pmlCells) * spacing
            let d0 = pmlCells == 0 ? 0 : 3 * fastest * log(1e4) / (2 * thickness)
            var pml = PML(b: [], a: [], active: [])
            for n in 0...count {
                let x = (Double(n) + offset) * spacing - start
                guard pmlCells > 0, x > 0 else {
                    pml.b.append(0)
                    pml.a.append(0)
                    pml.active.append(false)
                    continue
                }
                let f = min(x / thickness, 1)
                let d = d0 * f * f
                let alpha = Double.pi * dominantFrequency * (1 - f)
                let b = exp(-(d + alpha) * dt)
                pml.b.append(b)
                pml.a.append(d + alpha > 0 ? d * (b - 1) / (d + alpha) : 0)
                pml.active.append(true)
            }
            return pml
        }
        radialPML = (profile(count: radialCells, offset: 0), profile(count: radialCells, offset: 0.5))
        depthPML = (profile(count: depthCells, offset: 0), profile(count: depthCells, offset: 0.5))
    }

    /// Row `j`'s resting mean pressure, Pa, and the radius √J₂ of its resting deviator.
    func restingMean(_ j: Int) -> (pressure: Double, radius: Double) {
        let (v0, h0) = (restingVertical[j], restingHorizontal[j])
        // σ_rr = σ_θθ = −h₀, σ_zz = −v₀: J₂ = (v₀ − h₀)²/3.
        return ((v0 + 2 * h0) / 3, abs(v0 - h0) / 3.0.squareRoot())
    }

    /// The same grid with other layers.
    public func withLayers(_ layers: [Layer]) throws -> AxisymmetricElasticGrid {
        try AxisymmetricElasticGrid(
            radialCells: radialCells, depthCells: depthCells, spacing: spacing, layers: layers,
            pmlCells: pmlCells,
            dominantFrequency: dominantFrequency, timeStep: timeStep, surcharge: surcharge)
    }

    /// The grid's reach, m: radially to the outer edge, and in depth to the bottom, each including
    /// the perfectly matched layer.
    public var radius: Double { Double(radialCells) * spacing }
    public var depth: Double { Double(depthCells) * spacing }
    /// Where the perfectly matched layer begins, m.
    public var interiorRadius: Double { Double(radialCells - pmlCells) * spacing }
    public var interiorDepth: Double { Double(depthCells - pmlCells) * spacing }

    /// The radii, m, of the surface's loaded cells, where `AxisymmetricElasticStepper.step`
    /// takes its pressures: (i + ½)h.
    public var surfaceRadii: [Double] { (0..<radialCells).map { (Double($0) + 0.5) * spacing } }
}

/// Where to read the ground's motion: a point at radius r and depth z, m.
public struct ElasticReceiver: Sendable, Equatable {
    public var radius: Double
    public var depth: Double

    public init(radius: Double, depth: Double) {
        self.radius = radius
        self.depth = depth
    }
}

/// The motion at a receiver: velocities, m/s, radial (outwards) and vertical (downwards), and
/// the vertical stress, Pa, compression positive.
public struct ElasticReading: Sendable, Equatable {
    public var radial: Double
    public var vertical: Double
    public var verticalStress: Double
}

/// Steps the axisymmetric half-space: velocities at half steps, stresses at whole ones, the
/// surface pressed by a pressure at each loaded cell. Single owner; not concurrently callable.
public final class AxisymmetricElasticStepper: @unchecked Sendable {
    public let grid: AxisymmetricElasticGrid
    /// Steps taken; stresses are at `time`, velocities half a step behind.
    public private(set) var stepIndex = 0
    public var time: Double { Double(stepIndex) * grid.timeStep }
    /// The work the surface's pressure has done on the ground, J.
    public private(set) var work = 0.0

    private let columns: Int
    private var vr: [Double]
    private var vz: [Double]
    private var srr: [Double]
    private var stt: [Double]
    private var szz: [Double]
    private var srz: [Double]
    // Convolutional memory, one per derivative the layer stretches.
    private var memory: [[Double]]
    private var pressure: [Double]
    // Yielding: each normal-stress point's volumetric strain (compression positive) and the most
    // it has reached.
    private var volumetric: [Double]
    private var volumetricMost: [Double]
    // Each normal-stress point's return to its cone this step, the share of its deviator kept.
    private var kept: [Double]
    private let yielding: Bool
    /// The energy yielding has taken from the waves, J: the load's stress (without the resting
    /// stresses, which gravity holds) times the strain that stays, compaction and the cone's,
    /// summed over the soil.
    public private(set) var yieldingLoss = 0.0

    public init(grid: AxisymmetricElasticGrid) {
        self.grid = grid
        columns = grid.radialCells + 1
        let count = columns * (grid.depthCells + 1)
        vr = Array(repeating: 0, count: count)
        vz = vr
        srr = vr
        stt = vr
        szz = vr
        srz = vr
        memory = Array(repeating: vr, count: 8)
        volumetric = vr
        volumetricMost = vr
        kept = Array(repeating: 1, count: count)
        yielding = zip(grid.plastic, grid.strength).contains { $0 && $1.isFinite }
        pressure = Array(repeating: 0, count: grid.radialCells)
    }

    /// Advances one step, the surface's loaded cells pressed by `surfacePressure` (Pa, one per
    /// cell of `grid.surfaceRadii`) at the step's end.
    public func step(surfacePressure: [Double]) {
        precondition(surfacePressure.count == grid.radialCells)
        let g = grid
        let (nr, nz, h, dt) = (g.radialCells, g.depthCells, g.spacing, g.timeStep)
        let c = columns
        let old = pressure
        var work = 0.0
        vr.withUnsafeMutableBufferPointer { vr in
            vz.withUnsafeMutableBufferPointer { vz in
                srr.withUnsafeMutableBufferPointer { srr in
                    stt.withUnsafeMutableBufferPointer { stt in
                        szz.withUnsafeMutableBufferPointer { szz in
                            srz.withUnsafeMutableBufferPointer { srz in
                                // Memory: 0 ∂σrr/∂r and 1 ∂σrz/∂z for v_r; 2 ∂σrz/∂r and 3 ∂σzz/∂z
                                // for v_z; 4 ∂vr/∂r and 5 ∂vz/∂z for the normal stresses; 6 ∂vr/∂z
                                // and 7 ∂vz/∂r for σrz.
                                func stretch(
                                    _ value: Double, _ m: Int, _ index: Int,
                                    _ pml: AxisymmetricElasticGrid.PML, _ n: Int
                                ) -> Double {
                                    guard pml.active[n] else { return value }
                                    memory[m][index] = pml.b[n] * memory[m][index] + pml.a[n] * value
                                    return value + memory[m][index]
                                }
                                // Velocities at t + Δt/2.
                                for j in 0..<nz {
                                    let rho = g.density[j]
                                    for i in 1..<nr {
                                        let k = i + c * j
                                        let r = Double(i) * h
                                        let dRR = stretch(
                                            (srr[k] - srr[k - 1]) / h, 0, k, g.radialPML.whole, i)
                                        // Above the surface σrz mirrors itself, so it vanishes there.
                                        let below = srz[k]
                                        let above = j == 0 ? -srz[k] : srz[k - c]
                                        let dRZ = stretch((below - above) / h, 1, k, g.depthPML.whole, j)
                                        let hoop = ((srr[k] + srr[k - 1]) - (stt[k] + stt[k - 1])) / (2 * r)
                                        vr[k] += dt / rho * (dRR + dRZ + hoop)
                                    }
                                }
                                for j in 0..<nz {
                                    let rho = g.halfDensity[j]
                                    for i in 0..<nr {
                                        let k = i + c * j
                                        let r = (Double(i) + 0.5) * h
                                        let dRZ = stretch(
                                            (srz[k + 1] - srz[k]) / h, 2, k, g.radialPML.half, i)
                                        let dZZ = stretch((szz[k + c] - szz[k]) / h, 3, k, g.depthPML.half, j)
                                        let spread = (srz[k + 1] + srz[k]) / (2 * r)
                                        vz[k] += dt / rho * (dRZ + dZZ + spread)
                                    }
                                }
                                // Stresses at t + Δt; the surface's σzz is the load.
                                for j in 0..<nz {
                                    let (lam, m) = (g.lambda[j], g.mu[j])
                                    for i in 0..<nr {
                                        let k = i + c * j
                                        let r = (Double(i) + 0.5) * h
                                        let dVR = stretch((vr[k + 1] - vr[k]) / h, 4, k, g.radialPML.half, i)
                                        let hoop = (vr[k + 1] + vr[k]) / (2 * r)
                                        var dVZ: Double
                                        if j == 0 {
                                            // σzz follows the load: (λ + 2μ)∂vz/∂z + λ(∂vr/∂r + vr/r)
                                            // = dσzz/dt.
                                            let rate = (old[i] - surfacePressure[i]) / dt
                                            dVZ = (rate - lam * (dVR + hoop)) / (lam + 2 * m)
                                        } else {
                                            dVZ = stretch((vz[k] - vz[k - c]) / h, 5, k, g.depthPML.whole, j)
                                        }
                                        if j > 0, g.plastic[j] {
                                            compact(
                                                k, j, rates: (dVR, hoop, dVZ), mu: m, dt: dt,
                                                srr: srr, stt: stt, szz: szz)
                                            continue
                                        }
                                        srr[k] += dt * ((lam + 2 * m) * dVR + lam * (hoop + dVZ))
                                        stt[k] += dt * ((lam + 2 * m) * hoop + lam * (dVR + dVZ))
                                        if j == 0 {
                                            szz[k] = -surfacePressure[i]
                                            if let limits = g.surfaceLimits {
                                                let v = max(surfacePressure[i], 0)
                                                let low = -(limits.passive * v + limits.passiveCohesion)
                                                let high = limits.activeCohesion - limits.active * v
                                                srr[k] = min(max(srr[k], low), high)
                                                stt[k] = min(max(stt[k], low), high)
                                            }
                                            // The work over the step: the pressure on the ring
                                            // times the surface's downward speed, taken half a
                                            // cell down.
                                            let area = 2 * Double.pi * r * h
                                            work += (old[i] + surfacePressure[i]) / 2 * vz[k] * area * dt
                                        } else {
                                            szz[k] += dt * ((lam + 2 * m) * dVZ + lam * (dVR + hoop))
                                        }
                                    }
                                }
                                for j in 0..<nz {
                                    let m = g.halfMu[j]
                                    for i in 1..<nr {
                                        let k = i + c * j
                                        let dVRZ = stretch((vr[k + c] - vr[k]) / h, 6, k, g.depthPML.half, j)
                                        let dVZR = stretch(
                                            (vz[k] - vz[k - 1]) / h, 7, k, g.radialPML.whole, i)
                                        srz[k] += dt * m * (dVRZ + dVZR)
                                    }
                                }
                                if yielding { returnToCones(srr: srr, stt: stt, szz: szz, srz: srz) }
                            }
                        }
                    }
                }
            }
        }
        pressure = surfacePressure
        self.work += work
        stepIndex += 1
    }

    /// A yielding point's trial normal stresses at t + Δt from the strain rates (ε̇_rr, ε̇_θθ,
    /// ε̇_zz, extension positive), by the column's bilinear law: elastic at the unloading
    /// stiffness (λ_u = λ + ρ(c_u² − c_P²), μ as given), and while the soil compacts beyond
    /// anything before (its volumetric strain at its most), a share 1 − c_P²/c_u² of each
    /// shortening along r, θ and z stays as compaction, where the load compresses the soil that
    /// way. In uniaxial strain this is the column exactly, loading at ρc_P² and unloading at
    /// ρc_u², and unloaded to nothing vertically it is left with nothing sideways; the
    /// compaction only ever takes energy. (The law on the mean pressure alone left compacted soil
    /// pulling sideways, its resting stress cut, and the cone then let the ground fall under its
    /// own weight.) The soil takes no tension: the mean stress, with the resting stresses, is held
    /// at nothing or more.
    private func compact(
        _ k: Int, _ j: Int, rates: (Double, Double, Double), mu: Double, dt: Double,
        srr: UnsafeMutableBufferPointer<Double>, stt: UnsafeMutableBufferPointer<Double>,
        szz: UnsafeMutableBufferPointer<Double>
    ) {
        let g = grid
        let lam = g.unloadingLambda[j]
        var (e0, e1, e2) = (rates.0 * dt, rates.1 * dt, rates.2 * dt)
        let before = volumetric[k]
        volumetric[k] -= e0 + e1 + e2
        if volumetric[k] > volumetricMost[k] {
            // The share of the step beyond the most it has been compacted: a step reloading
            // past it is stiff up to it.
            let share = (volumetric[k] - max(before, volumetricMost[k])) / (volumetric[k] - before)
            volumetricMost[k] = volumetric[k]
            // The elastic share of each shortening where the load compresses the soil that way:
            // the compaction then works against the load's stress, and only ever takes energy
            // from the waves. (Against the resting stresses too, it could feed them: the ground
            // settling under its own weight without end.)
            let stays = g.compaction[j] * share
            var taken = 0.0
            if e0 < 0, srr[k] < 0 {
                taken += srr[k] * e0 * stays
                e0 *= 1 - stays
            }
            if e1 < 0, stt[k] < 0 {
                taken += stt[k] * e1 * stays
                e1 *= 1 - stays
            }
            if e2 < 0, szz[k] < 0 {
                taken += szz[k] * e2 * stays
                e2 *= 1 - stays
            }
            let r = (Double(k % columns) + 0.5) * g.spacing
            yieldingLoss += taken * 2 * Double.pi * r * g.spacing * g.spacing
        }
        let trace = e0 + e1 + e2
        srr[k] += 2 * mu * e0 + lam * trace
        stt[k] += 2 * mu * e1 + lam * trace
        szz[k] += 2 * mu * e2 + lam * trace
        // Tension positive: the mean stress no more than the resting mean pressure.
        let p0 = (g.restingVertical[j] + 2 * g.restingHorizontal[j]) / 3
        let pull = (srr[k] + stt[k] + szz[k]) / 3 - p0
        if pull > 0 {
            srr[k] -= pull
            stt[k] -= pull
            szz[k] -= pull
        }
    }

    /// The load's trial stresses returned to the Drucker–Prager cone, after Andrews (2005) for
    /// the staggered grid. The cone, √J₂ ≤ αp + k on the total stresses, is met by capping the
    /// load's deviator at the margin the resting deviator leaves, αp + k − √J₂⁰ with p the total
    /// mean pressure: by the triangle inequality the total is then within the cone, exactly so
    /// where the load presses as gravity does, a little short of it otherwise. The resting
    /// deviator, which gravity holds, is never released: released, it fed the waves with
    /// gravity's energy wherever the load pulled the soil apart (the focus of a disc's edge
    /// wave under its centre). At each normal-stress point the load's deviator, with the four
    /// shear stresses round it (their mean square, so that shear changing sign between rows
    /// still counts), is scaled back to the margin; each shear stress is scaled by the least of
    /// its four neighbours' shares, so that no point sees more shear than its own share allows.
    private func returnToCones(
        srr: UnsafeMutableBufferPointer<Double>, stt: UnsafeMutableBufferPointer<Double>,
        szz: UnsafeMutableBufferPointer<Double>, srz: UnsafeMutableBufferPointer<Double>
    ) {
        let g = grid
        let c = columns
        let (nr, nz, h) = (g.radialCells, g.depthCells, g.spacing)
        var loss = 0.0
        kept.withUnsafeMutableBufferPointer { kept in
            for j in 1..<(nz - g.pmlCells) where g.plastic[j] && g.strength[j].isFinite {
                let (p0, resting) = g.restingMean(j)
                let (alpha, strength) = (g.alpha[j], g.strength[j])
                let twoMu = 2 * g.mu[j]
                for i in 0..<(nr - g.pmlCells) {
                    let k = i + c * j
                    kept[k] = 1
                    let mean = (srr[k] + stt[k] + szz[k]) / 3
                    let (dRR, dTT, dZZ) = (srr[k] - mean, stt[k] - mean, szz[k] - mean)
                    let (a, b, d, e) = (srz[k], srz[k + 1], srz[k - c], srz[k - c + 1])
                    let normal = dRR * dRR + dTT * dTT + dZZ * dZZ
                    let j2 = normal / 2 + (a * a + b * b + d * d + e * e) / 4
                    let margin = max(alpha * (p0 - mean) + strength - resting, 0)
                    guard j2 > margin * margin else { continue }
                    let f = margin / j2.squareRoot()
                    kept[k] = f
                    srr[k] = dRR * f + mean
                    stt[k] = dTT * f + mean
                    szz[k] = dZZ * f + mean
                    // The deviator after the return times the strain that stays, (1 − f)s/(2μ)
                    // (backward Euler, as the return is).
                    let r = (Double(i) + 0.5) * h
                    loss += f * (1 - f) * normal / twoMu * 2 * Double.pi * r * h * h
                }
            }
            for j in 0..<(nz - g.pmlCells) where g.strength[j].isFinite || g.strength[j + 1].isFinite {
                for i in 1...(nr - g.pmlCells) {
                    let k = i + c * j
                    let f = min(kept[k - 1], kept[k], kept[k - 1 + c], kept[k + c])
                    guard f < 1 else { continue }
                    // Both shear components, at the stress after the return: 2f(1 − f)σ²/(2μ).
                    let r = Double(i) * h
                    loss += f * (1 - f) * srz[k] * srz[k] / g.halfMu[j] * 2 * Double.pi * r * h * h
                    srz[k] *= f
                }
            }
        }
        yieldingLoss += loss
    }

    /// How far the yielding points' total stresses stand outside their cones, at most, as a
    /// share of the cone's radius there: (√J₂ − margin)/(αp + k) for the load's deviator, J₂ with
    /// the four shear stresses' mean square as the return takes it (0 or less inside).
    func coneExcess() -> Double {
        let g = grid
        let c = columns
        var worst = -Double.infinity
        for j in 1..<(g.depthCells - g.pmlCells) where g.plastic[j] && g.strength[j].isFinite {
            let (p0, resting) = g.restingMean(j)
            for i in 0..<(g.radialCells - g.pmlCells) {
                let k = i + c * j
                let mean = (srr[k] + stt[k] + szz[k]) / 3
                let limit = g.alpha[j] * (p0 - mean) + g.strength[j]
                guard limit > 1e-6 else { continue }
                let (dRR, dTT, dZZ) = (srr[k] - mean, stt[k] - mean, szz[k] - mean)
                let (a, b, d, e) = (srz[k], srz[k + 1], srz[k - c], srz[k - c + 1])
                let j2 = (dRR * dRR + dTT * dTT + dZZ * dZZ) / 2 + (a * a + b * b + d * d + e * e) / 4
                worst = max(worst, (j2.squareRoot() - max(limit - resting, 0)) / limit)
            }
        }
        return worst
    }

    /// Bilinear interpolation of a field on positions (i + ox)h, (j + oz)h.
    private func sample(_ field: [Double], _ ox: Double, _ oz: Double, radius: Double, depth: Double)
        -> Double
    {
        let h = grid.spacing
        let x = max(radius / h - ox, 0)
        let y = max(depth / h - oz, 0)
        let i = min(Int(x), grid.radialCells - 1)
        let j = min(Int(y), grid.depthCells - 1)
        let (fx, fy) = (min(x - Double(i), 1), min(y - Double(j), 1))
        let c = columns
        let k = i + c * j
        return (1 - fx) * (1 - fy) * field[k] + fx * (1 - fy) * field[k + 1] + (1 - fx) * fy * field[k + c]
            + fx * fy * field[k + c + 1]
    }

    /// The velocities at each receiver: v_r at the step's half time, v_z likewise, interpolated.
    public func read(_ receivers: [ElasticReceiver]) -> [ElasticReading] {
        receivers.map { receiver in
            ElasticReading(
                radial: sample(vr, 0, 0, radius: receiver.radius, depth: receiver.depth),
                vertical: sample(vz, 0.5, 0.5, radius: receiver.radius, depth: receiver.depth),
                verticalStress: -sample(szz, 0.5, 0, radius: receiver.radius, depth: receiver.depth))
        }
    }

    /// The kinetic and strain energy, J, of the ground inside the perfectly matched layer.
    public func interiorEnergy() -> Double {
        let g = grid
        let (h, c) = (g.spacing, columns)
        let rMax = g.radialCells - g.pmlCells
        let zMax = g.depthCells - g.pmlCells
        var energy = 0.0
        for j in 0..<zMax {
            let (lam, m) = (g.lambda[j], g.mu[j])
            for i in 0..<rMax {
                let k = i + c * j
                let r = (Double(i) + 0.5) * h
                let volume = 2 * Double.pi * r * h * h
                let vR = (vr[k] + vr[k + 1]) / 2
                let vZ = j == 0 ? vz[k] : (vz[k] + vz[k - c]) / 2
                energy += 0.5 * g.density[j] * (vR * vR + vZ * vZ) * volume
                let sRZ =
                    (srz[k] + srz[k + 1] + (j == 0 ? -srz[k] - srz[k + 1] : srz[k - c] + srz[k + 1 - c])) / 4
                let trace = srr[k] + stt[k] + szz[k]
                let squares = srr[k] * srr[k] + stt[k] * stt[k] + szz[k] * szz[k] + 2 * sRZ * sRZ
                energy += (squares - lam / (3 * lam + 2 * m) * trace * trace) / (4 * m) * volume
            }
        }
        return energy
    }
}
