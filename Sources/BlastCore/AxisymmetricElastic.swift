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

        public init(thickness: Double, density: Double, pWaveSpeed: Double, sWaveSpeed: Double) {
            self.thickness = thickness
            self.density = density
            self.pWaveSpeed = pWaveSpeed
            self.sWaveSpeed = sWaveSpeed
        }

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
    let density: [Double]
    let halfDensity: [Double]
    let lambda: [Double]
    let mu: [Double]
    let halfMu: [Double]
    // The layer's damping profile and coefficients along r and z, at integer and half positions.
    let radialPML: (whole: PML, half: PML)
    let depthPML: (whole: PML, half: PML)

    struct PML: Sendable {
        var b: [Double]
        var a: [Double]
        var active: [Bool]
    }

    public enum GridError: Error, Equatable {
        case invalid(String)
    }

    /// `courant` is the share of the stable step taken: c_P Δt/h ≤ courant/√2.
    public init(
        radialCells: Int, depthCells: Int, spacing: Double, layers: [Layer], pmlCells: Int = 20,
        dominantFrequency: Double = 50, courant: Double = 0.9, timeStep: Double? = nil
    ) throws {
        guard radialCells > 2 * pmlCells, depthCells > 2 * pmlCells, spacing > 0, spacing.isFinite,
            !layers.isEmpty, pmlCells >= 0, dominantFrequency > 0, courant > 0, courant <= 1
        else { throw GridError.invalid("The grid's size, spacing or layers are out of range.") }
        for layer in layers {
            guard layer.thickness > 0, layer.density > 0, layer.sWaveSpeed > 0,
                layer.pWaveSpeed > layer.sWaveSpeed * 2.0.squareRoot(), layer.thickness.isFinite
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
        let fastest = layers.map(\.pWaveSpeed).max()!
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
                                        srr[k] += dt * ((lam + 2 * m) * dVR + lam * (hoop + dVZ))
                                        stt[k] += dt * ((lam + 2 * m) * hoop + lam * (dVR + dVZ))
                                        if j == 0 {
                                            szz[k] = -surfacePressure[i]
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
