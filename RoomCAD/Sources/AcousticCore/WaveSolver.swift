import Foundation
import simd

/// Low-frequency room response by finite differences in the time domain (FDTD).
///
/// Linear acoustics with pressure at cell centres and particle velocity on cell faces, advanced by
/// leapfrog (Yee's staggered scheme): `u -= dt/ρ ∇p`, then `p -= ρc² dt ∇·u`. Walls are locally
/// reacting, with a real normalized impedance ξ whose statistical absorption matches each wall's
/// low-frequency absorption, treated semi-implicitly so any ξ > 0 is stable.
///
/// A monopole injects volume velocity q(t), a Gaussian derivative with no net volume. The free-field
/// pressure 1 m away is ρ q̇(t - 1/c) / 4π, so dividing a receiver's spectrum by that reference gives
/// the response in the same units as the geometrical model: pressure relative to the free field at 1 m.
///
/// The time step is the audio sample period times a power of two, so the solver's spectrum lines up
/// bin for bin with the audio spectrum.
struct WaveSolver {
    let room: ShoeboxRoom
    let sampleRate: Int
    /// Highest frequency the solver must resolve accurately: the top of the crossover's transition.
    let topFrequency: Double
    let atmosphere: Atmosphere
    /// Open areas, given the impedance of air (ξ = 1).
    let openings: [Opening]
    /// Octave bands whose mean absorption sets each wall's impedance; nil means all the bands the solver
    /// covers. `responses` runs once per group of bands with the same impedances.
    var impedanceBands: [Int]?
    /// Where to run: the GPU when there is one, or the CPU.
    var engine = Engine.automatic
    /// Whether `responses` damps each band so the room's modes decay, averaged over the room, at the
    /// diffuse rate their absorption gives (see `responses`); off only to test the bare boundary model.
    var matchesDiffuseDecay = true

    enum Engine: Sendable { case automatic, cpu }

    /// For tests: extra seconds after each GPU command buffer, standing in for other work on the GPU.
    var gpuDelay: TimeInterval = 0

    /// Grid points per wavelength at `topFrequency`.
    static let pointsPerWavelength = 10.0
    /// Fraction of the stability limit used for the time step.
    static let courantSafety = 0.95

    /// Cells along each axis.
    let cells: SIMD3<Int>
    /// Cell size along each axis, in metres, so the cells exactly fill the room.
    let spacing: SIMD3<Double>
    /// Audio samples per solver step, a power of two.
    let decimation: Int
    var timeStep: Double { Double(decimation) / Double(sampleRate) }

    init(
        room: ShoeboxRoom, sampleRate: Int, topFrequency: Double, atmosphere: Atmosphere,
        openings: [Opening] = []
    ) {
        self.room = room
        self.openings = openings
        self.sampleRate = sampleRate
        self.topFrequency = topFrequency
        self.atmosphere = atmosphere
        let c = atmosphere.soundSpeed
        let target = c / (topFrequency * Self.pointsPerWavelength)
        let counts = SIMD3<Int>(
            max(2, Int((room.size.x / target).rounded(.up))),
            max(2, Int((room.size.y / target).rounded(.up))),
            max(2, Int((room.size.z / target).rounded(.up))))
        cells = counts
        spacing = room.size / SIMD3<Double>(counts)
        let inverse = (1 / (spacing * spacing)).sum().squareRoot()
        let limit = Self.courantSafety / (c * inverse)
        var m = 1
        while Double(2 * m) / Double(sampleRate) <= limit { m *= 2 }
        decimation = m
    }

    /// About how much memory a run takes, in bytes: per cell, pressure and three velocities in single
    /// precision, six face coefficients and a flag on the GPU, and the layout they are built from.
    var memoryEstimate: Int { cells.x * cells.y * cells.z * 72 }

    /// Work for `duration` seconds, in cell updates.
    func cost(duration: Double) -> Double {
        Double(cells.x * cells.y * cells.z) * duration / timeStep
    }

    /// Normalized specific impedance ξ of a wall from its mean absorption over the bands the solver
    /// covers; rigid walls give ∞. Published coefficients are random-incidence values, and a locally
    /// reacting wall absorbs more at oblique incidence than at normal incidence, so ξ comes from Paris's
    /// statistical absorption α = (8/ξ)[1 + 1/(1 + ξ) - (2/ξ) ln(1 + ξ)], which reaches at most about
    /// 0.951 (at ξ ≈ 1.567); higher coefficients are limited to that.
    func impedance(_ surface: Surface) -> Double {
        impedance(material: room[surface])
    }

    func impedance(material: SurfaceMaterial) -> Double {
        let bands =
            impedanceBands
            ?? OctaveBands.centres.indices.filter { OctaveBands.centres[$0] <= topFrequency * 1.2 }
        let absorption = material.absorption
        let alpha = bands.map { absorption[$0] }.reduce(0, +) / Double(max(bands.count, 1))
        guard alpha > 0 else { return .infinity }
        return Self.impedance(forStatisticalAbsorption: alpha)
    }

    /// Paris's statistical absorption of a locally reacting surface with real normalized impedance ξ.
    static func statisticalAbsorption(_ xi: Double) -> Double {
        8 / xi * (1 + 1 / (1 + xi) - 2 / xi * log(1 + xi))
    }

    static let mostAbsorbingImpedance = 1.5674

    /// The impedance above `mostAbsorbingImpedance` whose statistical absorption is `alpha`, by bisection.
    static func impedance(forStatisticalAbsorption alpha: Double) -> Double {
        let target = min(alpha, statisticalAbsorption(mostAbsorbingImpedance))
        var low = mostAbsorbingImpedance
        var high = 1e7
        for _ in 0..<100 {
            let mid = (low * high).squareRoot()
            if statisticalAbsorption(mid) > target { low = mid } else { high = mid }
        }
        return (low * high).squareRoot()
    }

    /// The pulse: q(t) = -(t - t₀)/σ · exp(-((t - t₀)/σ)²), with σ chosen so its spectrum is still well
    /// above zero at the top frequency.
    var pulseWidth: Double { 1.517 / (Double.pi * topFrequency * 1.5) }
    var pulseCentre: Double { 4 * pulseWidth }
    func pulse(_ t: Double) -> Double {
        let x = (t - pulseCentre) / pulseWidth
        return -x * exp(-x * x)
    }

    /// Simulates `steps` steps and returns, per receiver, the microphone output after each step:
    /// `a p - (1 - a) ρc (u · axis)`, with pressure at `(n + 1) dt` and velocity averaged to that time.
    /// Returns nil if `stop` asks it to.
    func simulate(
        source: SIMD3<Double>, receivers: [(position: SIMD3<Double>, microphone: Microphone)], steps: Int,
        stop: @Sendable () -> Bool
    ) -> [[Double]]? {
        if room.plan != nil || room.mesh != nil {
            return simulateMasked(source: source, receivers: receivers, steps: steps, stop: stop)
        }
        let nx = cells.x
        let ny = cells.y
        let nz = cells.z
        let count = nx * ny * nz
        let c = atmosphere.soundSpeed
        let dt = timeStep
        let (dx, dy, dz) = (spacing.x, spacing.y, spacing.z)
        let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let ux = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let uy = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let uz = UnsafeMutablePointer<Float>.allocate(capacity: count)
        for field in [p, ux, uy, uz] { field.initialize(repeating: 0, count: count) }
        defer { for field in [p, ux, uy, uz] { field.deallocate() } }
        // ux[i] is the face between cells i and i + 1 along x (the last is unused); likewise y and z.
        let index = { (i: Int, j: Int, k: Int) in i + nx * (j + ny * k) }

        // Semi-implicit wall terms β = c dt / (2 ξ d), for each boundary face: the wall's impedance, or air's
        // where the face's centre lies in an opening.
        func faces(_ surface: Surface, _ first: Int, _ second: Int) -> [Float] {
            let xi = impedance(surface)
            let (a, b) = surface.planeAxes
            let depth = spacing[surface.normalAxis]
            let open = openings.filter { $0.surface == surface }
            return (0..<(first * second)).map { index in
                let point = SIMD2(
                    (Double(index % first) + 0.5) * spacing[a], (Double(index / first) + 0.5) * spacing[b])
                let face = open.contains { $0.contains(point) } ? 1 : xi
                let beta = c * dt / (2 * face * depth)
                return beta.isFinite ? Float(beta) : 0
            }
        }
        let west = faces(.west, ny, nz)
        let east = faces(.east, ny, nz)
        let south = faces(.south, nx, nz)
        let north = faces(.north, nx, nz)
        let floor = faces(.floor, nx, ny)
        let ceiling = faces(.ceiling, nx, ny)

        // Trilinear weights of a point on the cell-centre lattice.
        func weights(_ point: SIMD3<Double>) -> [(Int, Float)] {
            let g = point / spacing - 0.5
            let base = SIMD3<Int>(
                min(max(Int(g.x.rounded(.down)), 0), nx - 2), min(max(Int(g.y.rounded(.down)), 0), ny - 2),
                min(max(Int(g.z.rounded(.down)), 0), nz - 2))
            let f = simd_clamp(g - SIMD3<Double>(base), SIMD3(repeating: 0), SIMD3(repeating: 1))
            var result: [(Int, Float)] = []
            for corner in 0..<8 {
                let o = SIMD3<Int>(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1)
                let w =
                    (o.x == 1 ? f.x : 1 - f.x) * (o.y == 1 ? f.y : 1 - f.y) * (o.z == 1 ? f.z : 1 - f.z)
                result.append((index(base.x + o.x, base.y + o.y, base.z + o.z), Float(w)))
            }
            return result
        }
        let cellVolume = dx * dy * dz
        let sourceWeights = weights(source)
        let receiverWeights = receivers.map { weights($0.position) }
        // Velocity components are interpolated from the faces around a receiver's nearest cell.
        let receiverCells = receivers.map { receiver -> SIMD3<Int> in
            let g = receiver.position / spacing
            return SIMD3(
                min(max(Int(g.x), 1), nx - 2), min(max(Int(g.y), 1), ny - 2), min(max(Int(g.z), 1), nz - 2))
        }

        var pressure = Array(repeating: [Double](repeating: 0, count: steps), count: receivers.count)
        var velocity = Array(repeating: [Double](repeating: 0, count: steps + 1), count: receivers.count)
        // Small grids run on one thread: handing work out twice a step would cost more than the step.
        let slabs = count < 4_096 ? 1 : min(nz, 16)
        func forEachSlab(_ body: (Int) -> Void) {
            if slabs == 1 {
                body(0)
            } else {
                DispatchQueue.concurrentPerform(iterations: slabs, execute: body)
            }
        }
        let kx = Float(dt / dx)
        let ky = Float(dt / dy)
        let kz = Float(dt / dz)
        // ρc² dt / d for each axis, so the update multiplies rather than divides.
        let bx = Float(c * c * dt / dx)
        let by = Float(c * c * dt / dy)
        let bz = Float(c * c * dt / dz)
        let plane = nx * ny

        for n in 0..<steps {
            if n % 64 == 0, stop() { return nil }
            // Velocity from the pressure gradient (ρ = 1).
            forEachSlab { slab in
                for k in (slab * nz / slabs)..<((slab + 1) * nz / slabs) {
                    for j in 0..<ny {
                        let row = nx * (j + ny * k)
                        for i in 0..<(nx - 1) { ux[row + i] -= kx * (p[row + i + 1] - p[row + i]) }
                        if j < ny - 1 {
                            for i in 0..<nx { uy[row + i] -= ky * (p[row + i + nx] - p[row + i]) }
                        }
                        if k < nz - 1 {
                            for i in 0..<nx { uz[row + i] -= kz * (p[row + i + nx * ny] - p[row + i]) }
                        }
                    }
                }
            }
            // Pressure from the velocity divergence, with the walls semi-implicit. Interior cells take
            // the short path.
            forEachSlab { slab in
                for k in (slab * nz / slabs)..<((slab + 1) * nz / slabs) {
                    for j in 0..<ny {
                        let row = nx * (j + ny * k)
                        func general(_ i: Int) {
                            let at = row + i
                            var divergence: Float = 0
                            var wall: Float = 0
                            if i > 0 { divergence -= bx * ux[at - 1] } else { wall += west[j + ny * k] }
                            if i < nx - 1 { divergence += bx * ux[at] } else { wall += east[j + ny * k] }
                            if j > 0 { divergence -= by * uy[at - nx] } else { wall += south[i + nx * k] }
                            if j < ny - 1 { divergence += by * uy[at] } else { wall += north[i + nx * k] }
                            if k > 0 { divergence -= bz * uz[at - plane] } else { wall += floor[i + nx * j] }
                            if k < nz - 1 { divergence += bz * uz[at] } else { wall += ceiling[i + nx * j] }
                            p[at] = ((1 - wall) * p[at] - divergence) / (1 + wall)
                        }
                        guard j > 0, j < ny - 1, k > 0, k < nz - 1 else {
                            for i in 0..<nx { general(i) }
                            continue
                        }
                        general(0)
                        for at in (row + 1)..<(row + nx - 1) {
                            p[at] -=
                                bx * (ux[at] - ux[at - 1]) + by * (uy[at] - uy[at - nx]) + bz
                                * (uz[at] - uz[at - plane])
                        }
                        general(nx - 1)
                    }
                }
            }
            // Volume velocity injected at the source, at the half step.
            let q = pulse((Double(n) + 0.5) * dt)
            for (cell, w) in sourceWeights { p[cell] += Float(c * c * dt * q / cellVolume) * w }

            for (r, receiver) in receivers.enumerated() {
                var value = 0.0
                for (cell, w) in receiverWeights[r] { value += Double(p[cell]) * Double(w) }
                pressure[r][n] = value
                if !receiver.microphone.isOmni {
                    // Velocity at the receiver's cell centre from its two faces on each axis.
                    let cell = receiverCells[r]
                    let at = index(cell.x, cell.y, cell.z)
                    let u = SIMD3<Double>(
                        Double(ux[at - 1] + ux[at]) / 2, Double(uy[at - nx] + uy[at]) / 2,
                        Double(uz[at - nx * ny] + uz[at]) / 2)
                    velocity[r][n + 1] = simd_dot(u, receiver.microphone.axis)
                }
            }
        }
        // Velocity is known at half steps; average neighbours to the pressure's times.
        return receivers.indices.map { r in
            let microphone = receivers[r].microphone
            guard !microphone.isOmni else { return pressure[r] }
            let a = microphone.pattern.omniShare
            return (0..<steps).map { n in
                let v =
                    n + 2 <= steps
                    ? (velocity[r][n + 1] + velocity[r][min(n + 2, steps)]) / 2 : velocity[r][n + 1]
                return a * pressure[r][n] - (1 - a) * c * v
            }
        }
    }
}

extension WaveSolver {
    /// Each receiver's low-frequency response, `frames` samples at the audio rate, in the geometrical
    /// model's units and weighted by `weight(f)`: the crossover's low-pass and the low-frequency cutoff.
    ///
    /// `fftLength` must be a power of two at least `frames` plus room for the decay to finish; the
    /// solver runs `fftLength / decimation` steps so its spectrum shares the audio spectrum's bins. Also
    /// says how many of the runs used the GPU and, for each octave band covered, the room's T30 in the
    /// bare simulation and the diffuse decay it was matched to.
    ///
    /// Published absorption coefficients are diffuse-field values, and the geometrical model uses them
    /// that way. In the solver a wall is a locally reacting impedance, and by Morse's first-order theory a
    /// mode loses only half as much energy to a wall it grazes as to one it strikes, so axial and
    /// tangential modes outlast a diffuse field. In the measured seminar room (docs/roomcad-validation.md)
    /// this made the solver's decay at 63–125 Hz 18–32% longer than measured, while the measurement
    /// agreed with the diffuse decay: real rooms mix grazing and oblique energy by their irregularities,
    /// furniture and surfaces that are not locally reacting. Each run therefore also records 24 probes
    /// spread through the room, whose energy gives the room's average decay in each band; where that is
    /// slower than Eyring's decay for the band's absorption, the band's response is damped by e^(-Δt) from
    /// the direct sound's arrival on, to match it. Every mode in the band is damped alike, so the modes' frequencies, their spatial
    /// pattern and their differences in decay remain.
    func responses(
        source: SIMD3<Double>, receivers: [(position: SIMD3<Double>, microphone: Microphone)], frames: Int,
        fftLength: Int, progress: GenerationProgress? = nil, weight: (Double) -> Double,
        stop: @Sendable () -> Bool
    ) -> (channels: [[Float]], gpuRuns: Int, decay: [Int: (bare: Double?, diffuse: Double?)])? {
        let steps = fftLength / decimation
        let dt = timeStep
        let fft = RealFFT(length: steps)
        let half = steps / 2
        // The injected volume velocity at its sample times, (n + 1/2) dt.
        let q = fft.forward((0..<steps).map { pulse((Double($0) + 0.5) * dt) })
        let audio = RealFFT(length: fftLength)
        var output = Array(repeating: [Double](repeating: 0, count: frames), count: receivers.count)
        var gpuRuns = 0
        var decay: [Int: (bare: Double?, diffuse: Double?)] = [:]
        let probes = probePositions().map { (position: $0, microphone: Microphone.omni) }
        let diffuse = room.withOpenings(openings).eyringReverberationTime(
            atmosphere: atmosphere, airAbsorption: true)
        // Walls absorb differently in each octave band: one run per group of bands with the same
        // impedances, each kept only in its own bands. The band weights sum to one, so together they
        // cover the spectrum once.
        let groups = bandGroups
        for group in groups {
            var solver = self
            solver.impedanceBands = group
            guard
                let run = solver.run(
                    source: source, receivers: receivers + (matchesDiffuseDecay ? probes : []), steps: steps,
                    stop: stop)
            else {
                return nil
            }
            if run.onGPU { gpuRuns += 1 }
            progress?.advance(by: 1 / Double(groups.count))
            // The transfer function of each recorded signal, H = P / free-field reference, in the audio FFT's
            // scaling, at the solver's bins.
            func transfer(_ samples: [Double]) -> (real: [Double], imag: [Double]) {
                let p = fft.forward(samples)
                var real = [Double](repeating: 0, count: half)
                var imag = real
                for k in 1..<half {
                    let f = Double(k) / (Double(steps) * dt)
                    // Pressure was recorded at (n + 1) dt and the pulse injected at (n + 1/2) dt.
                    let pPhase = -2 * Double.pi * Double(k) / Double(steps)
                    let qPhase = -Double.pi * Double(k) / Double(steps)
                    let pr = p.real[k] * cos(pPhase) - p.imag[k] * sin(pPhase)
                    let pi = p.real[k] * sin(pPhase) + p.imag[k] * cos(pPhase)
                    let qr = q.real[k] * cos(qPhase) - q.imag[k] * sin(qPhase)
                    let qi = q.real[k] * sin(qPhase) + q.imag[k] * cos(qPhase)
                    // Free-field pressure 1 m away, without the travel time: j 2πf Q / 4π (ρ = 1).
                    let scale = 2 * Double.pi * f / (4 * Double.pi)
                    let rr = -qi * scale
                    let ri = qr * scale
                    let norm = rr * rr + ri * ri
                    guard norm > 1e-30 else { continue }
                    // vDSP scales the forward transform by 2.
                    real[k] = 2 * (pr * rr + pi * ri) / norm
                    imag[k] = 2 * (pi * rr - pr * ri) / norm
                }
                return (real, imag)
            }
            // Each band's extra damping, from the probes' summed energy in the band, above 20 Hz, over the
            // response's length: the zero-phase band filter wraps its ringing before an arrival round to the
            // end of the run.
            var damping: [Int: Double] = [:]
            if matchesDiffuseDecay {
                let spectra = run.signals[receivers.count...].map(transfer)
                let length = min(frames / decimation, steps)
                for band in group {
                    var energy = [Double](repeating: 0, count: length)
                    for spectrum in spectra {
                        var real = [Double](repeating: 0, count: half)
                        var imag = real
                        for k in 1..<half {
                            let f = Double(k) / (Double(steps) * dt)
                            let w =
                                OctaveBands.weight(band: band, frequency: f)
                                * OctaveBands.rise(f, crossover: 20)
                            real[k] = spectrum.real[k] * w
                            imag[k] = spectrum.imag[k] * w
                        }
                        let signal = fft.inverse(real: real, imag: imag)
                        for n in 0..<length { energy[n] += signal[n] * signal[n] }
                    }
                    let parameters = RoomParameters.measure(
                        energy: energy, sampleRate: sampleRate / decimation, noiseCompensated: false)
                    let bare = parameters.t30 ?? parameters.t20
                    decay[band] = (bare, diffuse[band])
                    if let bare, let target = diffuse[band], target > 0, target < bare {
                        // Energy decays at 6 ln 10 / T; amplitude at half that.
                        damping[band] = 3 * log(10) * (1 / target - 1 / bare)
                    }
                }
            }
            for r in receivers.indices {
                let h = transfer(run.signals[r])
                // Damping starts with the direct sound, which it leaves alone.
                let direct = simd_distance(receivers[r].position, source) / atmosphere.soundSpeed
                for band in group {
                    var real = [Double](repeating: 0, count: fftLength / 2)
                    var imag = real
                    for k in 1..<half {
                        let f = Double(k) / (Double(steps) * dt)
                        let w = weight(f) * OctaveBands.weight(band: band, frequency: f)
                        real[k] = h.real[k] * w
                        imag[k] = h.imag[k] * w
                    }
                    let signal = audio.inverse(real: real, imag: imag)
                    let delta = damping[band] ?? 0
                    let rate = Double(sampleRate)
                    for n in 0..<frames {
                        output[r][n] += signal[n] * exp(-delta * max(Double(n) / rate - direct, 0))
                    }
                }
            }
        }
        return (output.map { $0.map(Float.init) }, gpuRuns, decay)
    }

    /// Points spread through the room for measuring its average decay: the first `count` points of a
    /// Halton sequence that lie at least `clearance` inside every boundary.
    func probePositions(count: Int = 24) -> [SIMD3<Double>] {
        let clearance = min(0.3, 0.2 * room.size.min())
        func radicalInverse(_ i: Int, _ base: Int) -> Double {
            var (i, f, result) = (i, 1.0, 0.0)
            while i > 0 {
                f /= Double(base)
                result += f * Double(i % base)
                i /= base
            }
            return result
        }
        var points: [SIMD3<Double>] = []
        var i = 1
        while points.count < count, i < 4096 {
            let unit = SIMD3(radicalInverse(i, 2), radicalInverse(i, 3), radicalInverse(i, 5))
            let point = SIMD3(repeating: clearance) + unit * (room.size - 2 * clearance)
            i += 1
            if room.plan != nil || room.mesh != nil {
                guard room.contains(point), room.clearance(point) >= clearance else { continue }
            }
            points.append(point)
        }
        return points
    }

    /// Simulates on the GPU when there is one and the engine allows it, otherwise on the CPU, and says
    /// which it used.
    ///
    /// Other work can share the GPU and slow a run many times over. Once a GPU run has shown its pace, if
    /// what remains would take over a second and more than half as long again as the whole run on the CPU,
    /// timed over a few steps of the same grid, the run is abandoned and redone on the CPU. The grid and
    /// crossover stay the same, so the result does not depend on which engine ran it.
    func run(
        source: SIMD3<Double>, receivers: [(position: SIMD3<Double>, microphone: Microphone)], steps: Int,
        stop: @Sendable () -> Bool
    ) -> (signals: [[Double]], onGPU: Bool)? {
        if engine == .automatic, let gpu = MetalWaveSolver.shared {
            var cpuSeconds: Double?
            let result = gpu.simulate(self, source: source, receivers: receivers, steps: steps, stop: stop) {
                done, elapsed in
                Self.abandonsGPU(done: done, steps: steps, elapsed: elapsed) {
                    if let cpuSeconds { return cpuSeconds }
                    let estimate = cpuSecondsEstimate(source: source, receivers: receivers, steps: steps)
                    cpuSeconds = estimate
                    return estimate
                }
            }
            if let result { return (result, true) }
            if stop() { return nil }
        }
        return simulate(source: source, receivers: receivers, steps: steps, stop: stop).map { ($0, false) }
    }

    /// Seconds a GPU run goes before its pace is judged.
    static let gpuTrial = 0.25

    /// Whether a GPU run that has done `done` of `steps` steps in `elapsed` seconds should give way to the
    /// CPU: once it has run for `gpuTrial`, if what remains would take over a second and more than 1.5
    /// times as long as `cpuSeconds()`, the whole run on the CPU, which is only asked for then.
    static func abandonsGPU(done: Int, steps: Int, elapsed: TimeInterval, cpuSeconds: () -> Double) -> Bool {
        guard elapsed > gpuTrial, done > 0 else { return false }
        let remaining = elapsed / Double(done) * Double(steps - done)
        return remaining > 1 && remaining > 1.5 * cpuSeconds()
    }

    /// Seconds the CPU would take for `steps` steps, from a short run of about 5 × 10⁷ cell updates.
    func cpuSecondsEstimate(
        source: SIMD3<Double>, receivers: [(position: SIMD3<Double>, microphone: Microphone)], steps: Int
    ) -> Double {
        let trial = min(max(Int(5e7 / Double(cells.x * cells.y * cells.z)), 8), 256, steps)
        let start = Date()
        _ = simulate(source: source, receivers: receivers, steps: trial, stop: { false })
        return Date().timeIntervalSince(start) / Double(trial) * Double(steps)
    }

    /// Whether `run` will use the GPU.
    var usesGPU: Bool { engine == .automatic && MetalWaveSolver.shared != nil }

    /// The octave bands below the crossover's top, grouped by the impedances their absorption gives every
    /// boundary.
    var bandGroups: [[Int]] {
        let included = OctaveBands.centres.indices.filter { band in
            band == 0 || OctaveBands.crossovers[band - 1] / 2.squareRoot() < topFrequency
        }
        var groups: [(key: [Double], bands: [Int])] = []
        for band in included {
            var solver = self
            solver.impedanceBands = [band]
            let materials = Surface.allCases.map { room[$0] } + (room.plan?.walls ?? [])
            let key = materials.map { solver.impedance(material: $0) }
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].bands.append(band)
            } else {
                groups.append((key, [band]))
            }
        }
        return groups.map(\.bands)
    }

}

extension WaveSolver {
    /// The same scheme for a room with a floor plan or a mesh: cells whose centres lie inside the room are
    /// simulated, and every face between a simulated cell and one that is not is a wall with the
    /// impedance of the nearest wall, plan wall or mesh face (or air, in an opening or open face): a
    /// staircase approximation of walls that are not aligned with the grid. It shares its layout with the
    /// GPU solver.
    func simulateMasked(
        source: SIMD3<Double>, receivers: [(position: SIMD3<Double>, microphone: Microphone)], steps: Int,
        stop: @Sendable () -> Bool
    ) -> [[Double]]? {
        let nx = cells.x
        let ny = cells.y
        let nz = cells.z
        let count = nx * ny * nz
        let plane = nx * ny
        let c = atmosphere.soundSpeed
        let dt = timeStep
        let index = { (i: Int, j: Int, k: Int) in i + nx * (j + ny * k) }
        let layout = gridLayout(source: source, receivers: receivers)
        let inside = layout.inside.map { $0 == 1 }
        let faces = (0..<6).map { Array(layout.faces[($0 * count)..<(($0 + 1) * count)]) }

        let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let ux = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let uy = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let uz = UnsafeMutablePointer<Float>.allocate(capacity: count)
        for field in [p, ux, uy, uz] { field.initialize(repeating: 0, count: count) }
        defer { for field in [p, ux, uy, uz] { field.deallocate() } }

        // Trilinear weights over simulated cells, from the layout; its source weights include c² dt / V.
        let sourceWeights = Array(zip(layout.sourceCells, layout.sourceWeights))
        let receiverWeights = receivers.indices.map { r in
            Array(
                zip(
                    layout.receiverCells[(8 * r)..<(8 * r + 8)], layout.receiverWeights[(8 * r)..<(8 * r + 8)]
                ))
        }
        let receiverCells = receivers.map { receiver -> SIMD3<Int> in
            let g = receiver.position / spacing
            return SIMD3(
                min(max(Int(g.x), 1), nx - 2), min(max(Int(g.y), 1), ny - 2), min(max(Int(g.z), 1), nz - 2))
        }
        var pressure = Array(repeating: [Double](repeating: 0, count: steps), count: receivers.count)
        var velocity = Array(repeating: [Double](repeating: 0, count: steps + 1), count: receivers.count)
        let slabs = count < 4_096 ? 1 : min(nz, 16)
        func forEachSlab(_ body: (Int) -> Void) {
            if slabs == 1 {
                body(0)
            } else {
                DispatchQueue.concurrentPerform(iterations: slabs, execute: body)
            }
        }
        let kx = Float(dt / spacing.x)
        let ky = Float(dt / spacing.y)
        let kz = Float(dt / spacing.z)
        let bx = Float(c * c * dt / spacing.x)
        let by = Float(c * c * dt / spacing.y)
        let bz = Float(c * c * dt / spacing.z)
        let (west, east, south, north, floor, ceiling) = (
            faces[0], faces[1], faces[2], faces[3], faces[4], faces[5]
        )

        for n in 0..<steps {
            if n % 64 == 0, stop() { return nil }
            // Velocity on faces between two simulated cells; others stay zero and are walls.
            forEachSlab { slab in
                for k in (slab * nz / slabs)..<((slab + 1) * nz / slabs) {
                    for j in 0..<ny {
                        let row = nx * (j + ny * k)
                        for i in 0..<nx where inside[row + i] {
                            let at = row + i
                            if i < nx - 1, inside[at + 1] { ux[at] -= kx * (p[at + 1] - p[at]) }
                            if j < ny - 1, inside[at + nx] { uy[at] -= ky * (p[at + nx] - p[at]) }
                            if k < nz - 1, inside[at + plane] { uz[at] -= kz * (p[at + plane] - p[at]) }
                        }
                    }
                }
            }
            forEachSlab { slab in
                for k in (slab * nz / slabs)..<((slab + 1) * nz / slabs) {
                    for j in 0..<ny {
                        let row = nx * (j + ny * k)
                        for i in 0..<nx where inside[row + i] {
                            let at = row + i
                            var divergence: Float = 0
                            var wall: Float = 0
                            if west[at] < 0 { divergence -= bx * ux[at - 1] } else { wall += west[at] }
                            if east[at] < 0 { divergence += bx * ux[at] } else { wall += east[at] }
                            if south[at] < 0 { divergence -= by * uy[at - nx] } else { wall += south[at] }
                            if north[at] < 0 { divergence += by * uy[at] } else { wall += north[at] }
                            if floor[at] < 0 { divergence -= bz * uz[at - plane] } else { wall += floor[at] }
                            if ceiling[at] < 0 { divergence += bz * uz[at] } else { wall += ceiling[at] }
                            p[at] = ((1 - wall) * p[at] - divergence) / (1 + wall)
                        }
                    }
                }
            }
            let q = pulse((Double(n) + 0.5) * dt)
            for (cell, w) in sourceWeights { p[cell] += Float(q) * w }
            for (r, receiver) in receivers.enumerated() {
                var value = 0.0
                for (cell, w) in receiverWeights[r] { value += Double(p[cell]) * Double(w) }
                pressure[r][n] = value
                if !receiver.microphone.isOmni {
                    let cell = receiverCells[r]
                    let at = index(cell.x, cell.y, cell.z)
                    let u = SIMD3<Double>(
                        Double(ux[at - 1] + ux[at]) / 2, Double(uy[at - nx] + uy[at]) / 2,
                        Double(uz[at - plane] + uz[at]) / 2)
                    velocity[r][n + 1] = simd_dot(u, receiver.microphone.axis)
                }
            }
        }
        return receivers.indices.map { r in
            let microphone = receivers[r].microphone
            guard !microphone.isOmni else { return pressure[r] }
            let a = microphone.pattern.omniShare
            return (0..<steps).map { n in
                let v =
                    n + 2 <= steps
                    ? (velocity[r][n + 1] + velocity[r][min(n + 2, steps)]) / 2 : velocity[r][n + 1]
                return a * pressure[r][n] - (1 - a) * c * v
            }
        }
    }
}
