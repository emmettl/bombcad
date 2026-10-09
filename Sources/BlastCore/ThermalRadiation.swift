import Foundation
import simd

/// A study of the fireball's thermal radiation: what it is asked for. Any field left out of its
/// JSON takes its default.
public struct ThermalSpec: Codable, Sendable, Equatable {
    /// Gas at least this hot is luminous, part of the fireball, in kelvin.
    public var luminousTemperature: Float = 1500
    /// The fireball's emissivity: 1, a black body, is the most it could radiate.
    public var emissivity: Float = 1
    /// Receivers' spacing on the faces of blocks and structure, and on the ground, in metres.
    public var surfaceSpacing: Float = 1
    public var groundSpacing: Float = 2
    /// Points on the fireball's surface sampled for each receiver's view of it.
    public var samples = 128

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ThermalSpec()
        luminousTemperature =
            try values.decodeIfPresent(Float.self, forKey: .luminousTemperature)
            ?? defaults.luminousTemperature
        emissivity = try values.decodeIfPresent(Float.self, forKey: .emissivity) ?? defaults.emissivity
        surfaceSpacing =
            try values.decodeIfPresent(Float.self, forKey: .surfaceSpacing) ?? defaults.surfaceSpacing
        groundSpacing =
            try values.decodeIfPresent(Float.self, forKey: .groundSpacing) ?? defaults.groundSpacing
        samples = try values.decodeIfPresent(Int.self, forKey: .samples) ?? defaults.samples
    }

    public func validate() throws {
        guard luminousTemperature.isFinite, luminousTemperature > 300, emissivity.isFinite, emissivity > 0,
            emissivity <= 1, surfaceSpacing.isFinite, surfaceSpacing >= 0.05, groundSpacing.isFinite,
            groundSpacing >= 0.05, (16...4096).contains(samples)
        else {
            throw CocoaError(
                .coderInvalidValue,
                userInfo: [NSLocalizedDescriptionKey: "The thermal radiation description is out of range."])
        }
    }
}

/// The fireball at one moment as the blast sees it: the luminous gas, reduced to the volume,
/// centre and temperature of an equivalent sphere. A few numbers a frame, so the radiation can be
/// worked out anywhere.
public struct FireballFrame: Codable, Sendable, Equatable {
    public var time: Double
    /// Volume of luminous gas, in cubic metres; zero once none is left.
    public var volume: Double
    public var centre: SIMD3<Float>
    /// The fourth root of the luminous gas's mean T⁴, in kelvin: the temperature of a black body
    /// that radiates as the gas does on average.
    public var temperature: Float
    /// The hottest cell, in kelvin.
    public var hottest: Float

    public init(time: Double, volume: Double, centre: SIMD3<Float>, temperature: Float, hottest: Float) {
        self.time = time
        self.volume = volume
        self.centre = centre
        self.temperature = temperature
        self.hottest = hottest
    }

    /// The equivalent sphere's radius.
    public var radius: Float { Float(cbrt(3 * volume / (4 * .pi))) }
}

extension BlastSolver {
    /// The fireball now: every cell of air at least `luminousTemperature` kelvin. Summed on the GPU
    /// if the batch that ended now was asked for it (see `frameRequest`); otherwise read from the
    /// state, spread across the CPU's cores, so call it only while no batch is in flight.
    public func fireball(luminousTemperature: Float) -> FireballFrame {
        if let rows = frameExtractor?.fireballRows(
            luminous: luminousTemperature, grid: grid, time: time, steps: stepCount)
        {
            // In a fixed order and in double precision, so the same from one run to the next.
            var count = 0.0
            var position = SIMD3<Double>.zero
            var fourth = 0.0
            var hottest: Float = 0
            for k in 0..<grid.nz {
                for j in 0..<grid.ny {
                    let row = rows[j + grid.ny * k]
                    let n = Double(row.x)
                    guard n > 0 else { continue }
                    count += n
                    position += SIMD3(Double(row.y), n * (Double(j) + 0.5), n * (Double(k) + 0.5))
                    fourth += Double(row.z)
                    hottest = max(hottest, row.w)
                }
            }
            return Self.fireball(
                time: time, count: count, position: position, fourth: fourth, hottest: hottest,
                cellSize: grid.cellSize)
        }
        let (nx, ny, nz) = (grid.nx, grid.ny, grid.nz)
        let h = grid.cellSize
        let gamma = configuration.gamma
        let airModel = configuration.airModel
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        struct Sums {
            var count = 0
            var position = SIMD3<Double>.zero
            var fourth = 0.0
            var hottest: Float = 0
        }
        var planes = [Sums](repeating: Sums(), count: nz)
        withState { cells in
            planes.withUnsafeMutableBufferPointer { planes in
                DispatchQueue.concurrentPerform(iterations: nz) { k in
                    var sums = Sums()
                    for j in 0..<ny {
                        for i in 0..<nx {
                            let index = grid.index(i, j, k)
                            guard mask[index] == 0 else { continue }
                            let air = Self.primitive(of: cells[index], gamma: gamma, airModel: airModel)
                            // Dissociating air is never hotter than this, so it bounds the search.
                            let bound = air.pressure / (air.density * AirModel.gasConstant)
                            guard bound >= luminousTemperature else { continue }
                            let t =
                                airModel == .dissociating
                                ? airModel.temperature(density: air.density, pressure: air.pressure) : bound
                            guard t >= luminousTemperature, t.isFinite else { continue }
                            sums.count += 1
                            sums.position += SIMD3<Double>(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5)
                            sums.fourth += pow(Double(t), 4)
                            sums.hottest = max(sums.hottest, t)
                        }
                    }
                    planes[k] = sums
                }
            }
        }
        let total = planes.reduce(into: Sums()) { total, plane in
            total.count += plane.count
            total.position += plane.position
            total.fourth += plane.fourth
            total.hottest = max(total.hottest, plane.hottest)
        }
        return Self.fireball(
            time: time, count: Double(total.count), position: total.position, fourth: total.fourth,
            hottest: total.hottest, cellSize: h)
    }

    /// The fireball from its luminous cells' count, the sum of their positions in cells, of their
    /// temperatures to the fourth power, and the hottest.
    private static func fireball(
        time: Double, count: Double, position: SIMD3<Double>, fourth: Double, hottest: Float,
        cellSize h: Float
    ) -> FireballFrame {
        guard count > 0 else {
            return FireballFrame(time: time, volume: 0, centre: .zero, temperature: 0, hottest: 0)
        }
        return FireballFrame(
            time: time, volume: count * pow(Double(h), 3), centre: SIMD3<Float>(position / count) * h,
            temperature: Float(pow(fourth / count, 0.25)), hottest: hottest)
    }
}

/// A point on a surface where the radiation is reckoned.
public struct ThermalReceiver: Codable, Sendable, Equatable {
    public var position: SIMD3<Float>
    /// Out of the surface.
    public var normal: SIMD3<Float>
    /// `ground`, `block <n>` or `structure`.
    public var surface: String

    public init(position: SIMD3<Float>, normal: SIMD3<Float>, surface: String) {
        self.position = position
        self.normal = normal
        self.surface = surface
    }
}

/// The fireball's radiation on a scene's surfaces, frame by frame: the irradiance at each
/// receiver, its peak and its time integral, the fluence. The fireball radiates from the surface
/// of its equivalent sphere as a grey body, and each receiver sees what of that surface is above
/// its own horizon, above the ground and not hidden behind a block or the structure's starting
/// outline. The air between is taken as transparent.
public struct ThermalExposure: Sendable {
    public static let stefanBoltzmann = 5.670_374e-8

    public let spec: ThermalSpec
    public let receivers: [ThermalReceiver]
    /// In watts a square metre.
    public private(set) var peakIrradiance: [Float]
    /// In joules a square metre.
    public private(set) var fluence: [Double]
    public private(set) var frames: [FireballFrame] = []
    /// What stands between the receivers and the fireball.
    let visibility: any ThermalVisibility
    /// The charge's energy, in joules, to set the radiated energy against.
    let chargeEnergy: Double
    /// Points spread evenly over a cone, each as the fraction of the way to its rim in the
    /// cosine of the angle off its axis, and the cosine and sine of the angle round it.
    let cone: [SIMD3<Float>]
    private var lastIrradiance: [Float]?

    /// `visibility` tests what blocks the receivers' view, by default `defaultVisibility`'s.
    public init(spec: ThermalSpec, scene: FragmentScene, visibility: (any ThermalVisibility)? = nil) {
        self.spec = spec
        receivers = Self.receivers(scene: scene, spec: spec)
        self.visibility = visibility ?? Self.defaultVisibility(occluders: Self.occluders(scene))
        chargeEnergy = Self.chargeEnergy(scene)
        cone = Self.spread(spec.samples)
        peakIrradiance = [Float](repeating: 0, count: receivers.count)
        fluence = [Double](repeating: 0, count: receivers.count)
    }

    /// Adds the fireball at the next frame, integrating the irradiance since the last by the
    /// trapezium rule.
    public mutating func add(_ frame: FireballFrame) {
        let now = irradiance(frame)
        if let last = frames.last, let before = lastIrradiance {
            let step = frame.time - last.time
            for n in receivers.indices { fluence[n] += 0.5 * Double(before[n] + now[n]) * step }
        }
        for n in receivers.indices { peakIrradiance[n] = max(peakIrradiance[n], now[n]) }
        frames.append(frame)
        lastIrradiance = now
    }

    /// The irradiance at every receiver from `frame`'s fireball: every receiver's rays toward it,
    /// gathered across the CPU's cores, tested together, then summed.
    public func irradiance(_ frame: FireballFrame) -> [Float] {
        var result = [Float](repeating: 0, count: receivers.count)
        guard frame.volume > 0, frame.temperature > 0 else { return result }
        let power = Float(Double(spec.emissivity) * Self.stefanBoltzmann * pow(Double(frame.temperature), 4))
        let chunk = 256
        let chunks = (receivers.count + chunk - 1) / chunk
        // Each chunk's rays and their weights, laid out a chunk at a time and then put end to end.
        var rays = [[ThermalRay]](repeating: [], count: chunks)
        var weights = [[Float]](repeating: [], count: chunks)
        let views = [View](unsafeUninitializedCapacity: receivers.count) { views, count in
            rays.withUnsafeMutableBufferPointer { rays in
                weights.withUnsafeMutableBufferPointer { weights in
                    DispatchQueue.concurrentPerform(iterations: chunks) { c in
                        let range = c * chunk..<min((c + 1) * chunk, receivers.count)
                        var chunkRays: [ThermalRay] = []
                        var chunkWeights: [Float] = []
                        chunkRays.reserveCapacity(range.count * cone.count)
                        chunkWeights.reserveCapacity(range.count * cone.count)
                        for n in range {
                            (views.baseAddress! + n).initialize(
                                to: view(
                                    from: receivers[n], frame, power: power, rays: &chunkRays,
                                    weights: &chunkWeights))
                        }
                        rays[c] = chunkRays
                        weights[c] = chunkWeights
                    }
                }
            }
            count = receivers.count
        }
        var offsets = [0]
        for chunkRays in rays { offsets.append(offsets.last! + chunkRays.count) }
        let all = [ThermalRay](unsafeUninitializedCapacity: offsets.last!) { buffer, count in
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                _ = UnsafeMutableBufferPointer(rebasing: buffer[offsets[c]..<offsets[c + 1]]).initialize(
                    from: rays[c])
            }
            count = offsets.last!
        }
        let visible = visibility.visible(all)
        result.withUnsafeMutableBufferPointer { result in
            visible.withUnsafeBufferPointer { visible in
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    let chunkVisible = UnsafeBufferPointer(rebasing: visible[offsets[c]..<offsets[c + 1]])
                    var next = 0
                    for n in c * chunk..<min((c + 1) * chunk, receivers.count) {
                        result[n] = irradiance(
                            views[n], visible: chunkVisible, weights: weights[c], from: &next)
                    }
                }
            }
        }
        return result
    }

    /// The irradiance at one receiver. The sphere radiates evenly, a radiance of E / π, so the
    /// irradiance is that times the integral of cos θ over the directions in which the receiver
    /// sees it: sampled evenly over the cone the sphere subtends, each direction counted where it
    /// is above the receiver's horizon and reaches the sphere above the ground with no block or
    /// structure in the way. Exact for a sphere in full view at any distance, (r/d)² cos θ times E,
    /// and well behaved right up to its surface.
    func irradiance(at receiver: ThermalReceiver, _ frame: FireballFrame, power: Float) -> Float {
        var rays: [ThermalRay] = []
        var weights: [Float] = []
        let view = view(from: receiver, frame, power: power, rays: &rays, weights: &weights)
        var next = 0
        return visibility.visible(rays).withUnsafeBufferPointer { visible in
            irradiance(view, visible: visible, weights: weights, from: &next)
        }
    }

    /// What one receiver sees of the fireball before anything in the way is known.
    struct View {
        /// Its irradiance where that needs no rays: inside the fireball, or with all of it below
        /// the receiver's horizon.
        var settled: Float?
        /// How many rays it added.
        var rays = 0
        /// The irradiance is `scale` times the sum of the visible rays' weights, held to `cap`.
        var scale: Float = 1
        var cap: Float = .infinity
    }

    /// One receiver's view of `frame`'s fireball, adding the rays it needs tested to `rays` and the
    /// cosine of each on the receiver to `weights`.
    func view(
        from receiver: ThermalReceiver, _ frame: FireballFrame, power: Float, rays: inout [ThermalRay],
        weights: inout [Float]
    ) -> View {
        let radius = frame.radius
        let x = receiver.position
        let toCentre = frame.centre - x
        let d = simd_length(toCentre)
        // Inside the fireball, surrounded by it: the hemisphere above radiates in full.
        if d <= radius { return View(settled: power) }
        // The whole sphere is below this surface's horizon.
        if simd_dot(receiver.normal, toCentre) < -radius { return View(settled: 0) }
        let axis = toCentre / d
        let cosHalfAngle = sqrt(max(0, 1 - (radius / d) * (radius / d)))
        let solidAngle = 2 * Float.pi * (1 - cosHalfAngle)
        // Two directions square to the axis, for the cone's samples.
        let helper: SIMD3<Float> = abs(axis.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
        let u = simd_normalize(simd_cross(axis, helper))
        let v = simd_cross(axis, u)
        let first = rays.count
        for sample in cone {
            let cosine = 1 - sample.x * (1 - cosHalfAngle)
            let sine = sqrt(max(0, 1 - cosine * cosine))
            let direction = cosine * axis + sine * (sample.y * u + sample.z * v)
            let cosReceiver = simd_dot(receiver.normal, direction)
            guard cosReceiver > 0 else { continue }
            // Where the ray first meets the sphere.
            let b = simd_dot(direction, toCentre)
            let distance = b - sqrt(max(0, b * b - (d * d - radius * radius)))
            rays.append(ThermalRay(origin: x, direction: direction, length: distance))
            weights.append(cosReceiver)
        }
        return View(rays: rays.count - first, scale: power / .pi * solidAngle / Float(cone.count), cap: power)
    }

    /// The irradiance from a receiver's view, its rays' visibility and weights starting at `next`,
    /// which it moves past them.
    func irradiance(
        _ view: View, visible: UnsafeBufferPointer<Bool>, weights: [Float], from next: inout Int
    ) -> Float {
        if let settled = view.settled { return settled }
        var sum: Float = 0
        for k in next..<next + view.rays where visible[k] { sum += weights[k] }
        next += view.rays
        return min(view.scale * sum, view.cap)
    }

    /// What can block a receiver's view besides the ground: the blocks and the structure's starting
    /// outline.
    public static func occluders(_ scene: FragmentScene) -> [Box] {
        scene.blocks + scene.structure
    }

    /// `count` points on a Fibonacci spiral over a cone: even in the cosine of the angle off its
    /// axis, which makes them even in solid angle.
    static func spread(_ count: Int) -> [SIMD3<Float>] {
        let golden = Double.pi * (3 - sqrt(5))
        return (0..<count).map { n in
            let phi = golden * Double(n)
            return SIMD3<Float>(Float((Double(n) + 0.5) / Double(count)), Float(cos(phi)), Float(sin(phi)))
        }
    }

    /// Points over the ground and over every face of the blocks and the structure that the air
    /// touches, about `spacing` apart, lifted a millimetre off their surface.
    public static func receivers(scene: FragmentScene, spec: ThermalSpec) -> [ThermalReceiver] {
        let solids = scene.blocks + scene.structure
        func buried(_ point: SIMD3<Float>) -> Bool {
            solids.contains { $0.contains(point) }
                || point.x < 0 || point.y < 0 || point.x > scene.domain.x || point.y > scene.domain.y
                || point.z > scene.domain.z
        }
        let lift: Float = 0.001
        var result: [ThermalReceiver] = []
        let columns = max(1, Int((scene.domain.x / spec.groundSpacing).rounded(.up)))
        let rows = max(1, Int((scene.domain.y / spec.groundSpacing).rounded(.up)))
        for j in 0..<rows {
            for i in 0..<columns {
                let point = SIMD3<Float>(
                    (Float(i) + 0.5) * scene.domain.x / Float(columns),
                    (Float(j) + 0.5) * scene.domain.y / Float(rows), lift)
                if !buried(point) {
                    result.append(ThermalReceiver(position: point, normal: SIMD3(0, 0, 1), surface: "ground"))
                }
            }
        }
        let labelled =
            scene.blocks.enumerated().map { ($1, "block \($0)") } + scene.structure.map { ($0, "structure") }
        for (box, label) in labelled {
            for axis in 0..<3 {
                for side in [-1, 1] as [Float] {
                    // The underside rests on the ground or faces down into the air, which the
                    // fireball above cannot reach; leave it out.
                    if axis == 2 && side < 0 { continue }
                    let (u, v) = ((axis + 1) % 3, (axis + 2) % 3)
                    let nu = max(1, Int((box.size[u] / spec.surfaceSpacing).rounded(.up)))
                    let nv = max(1, Int((box.size[v] / spec.surfaceSpacing).rounded(.up)))
                    var normal = SIMD3<Float>.zero
                    normal[axis] = side
                    for b in 0..<nv {
                        for a in 0..<nu {
                            var point = SIMD3<Float>.zero
                            point[axis] = (side < 0 ? box.min[axis] : box.max[axis]) + side * lift
                            point[u] = box.min[u] + (Float(a) + 0.5) * box.size[u] / Float(nu)
                            point[v] = box.min[v] + (Float(b) + 0.5) * box.size[v] / Float(nv)
                            if !buried(point) {
                                result.append(
                                    ThermalReceiver(position: point, normal: normal, surface: label))
                            }
                        }
                    }
                }
            }
        }
        return result
    }

    /// The charge's energy, in joules, as the result reports it.
    public static func chargeEnergy(_ scene: FragmentScene) -> Double {
        Double(scene.charge.mass) * Double(Charge.energyPerKilogram)
    }

    public var result: ThermalResult {
        ThermalResult(
            spec: spec, receivers: receivers, peakIrradiance: peakIrradiance,
            fluence: fluence.map { Float($0) },
            fireball: frames, chargeEnergy: chargeEnergy)
    }
}

/// What a thermal radiation study found.
public struct ThermalResult: Codable, Sendable, Equatable {
    public var spec: ThermalSpec
    public var receivers: [ThermalReceiver]
    /// In watts a square metre, one a receiver.
    public var peakIrradiance: [Float]
    /// In joules a square metre, one a receiver.
    public var fluence: [Float]
    public var fireball: [FireballFrame]
    /// The charge's energy, in joules.
    public var chargeEnergy: Double

    public init(
        spec: ThermalSpec, receivers: [ThermalReceiver], peakIrradiance: [Float], fluence: [Float],
        fireball: [FireballFrame], chargeEnergy: Double
    ) {
        self.spec = spec
        self.receivers = receivers
        self.peakIrradiance = peakIrradiance
        self.fluence = fluence
        self.fireball = fireball
        self.chargeEnergy = chargeEnergy
    }

    /// What the fireball radiated through the run, in joules: its emissive power over the part of
    /// its sphere above the ground, by the trapezium rule. Nothing takes this energy out of the
    /// gas, so a share of the charge's energy beyond what fireballs are seen to radiate shows the
    /// emissivity is too high.
    public var radiatedEnergy: Double {
        let power = fireball.map { frame -> Double in
            guard frame.volume > 0 else { return 0 }
            let r = Double(frame.radius)
            // The sphere's area above z = 0: a cap of height r + z, between none and all of it.
            let above = 2 * Double.pi * r * min(max(r + Double(frame.centre.z), 0), 2 * r)
            return Double(spec.emissivity) * ThermalExposure.stefanBoltzmann
                * pow(Double(frame.temperature), 4)
                * above
        }
        return zip(fireball, fireball.dropFirst()).enumerated().reduce(0) { total, step in
            let (n, (a, b)) = step
            return total + 0.5 * (power[n] + power[n + 1]) * (b.time - a.time)
        }
    }

    /// The largest fireball, and each surface's highest peak irradiance and fluence.
    public var summary: [String] {
        var lines: [String] = []
        if let largest = fireball.max(by: { $0.volume < $1.volume }), largest.volume > 0 {
            let lasting = fireball.last { $0.volume > 0 }?.time ?? 0
            lines.append(
                String(
                    format:
                        "Fireball: largest %.1f m across at %.1f ms, %.0f K (hottest gas %.0f K); luminous until %.1f ms",
                    2 * largest.radius, largest.time * 1000, largest.temperature, largest.hottest,
                    lasting * 1000))
            lines.append(
                String(
                    format: "  radiated %.1f MJ, %.0f%% of the charge's energy, at emissivity %.2f",
                    radiatedEnergy / 1e6, 100 * radiatedEnergy / max(chargeEnergy, 1), spec.emissivity))
        } else {
            lines.append("Fireball: no gas reached the luminous temperature")
        }
        var surfaces: [String] = []
        for receiver in receivers where !surfaces.contains(receiver.surface) {
            surfaces.append(receiver.surface)
        }
        for surface in surfaces {
            let indices = receivers.indices.filter { receivers[$0].surface == surface }
            let peak = indices.map { peakIrradiance[$0] }.max() ?? 0
            let dose = indices.map { fluence[$0] }.max() ?? 0
            lines.append(
                String(
                    format: "  %@: %d points, peak %.2f MW/m², fluence up to %.1f kJ/m²", surface,
                    indices.count,
                    peak / 1e6, dose / 1e3))
        }
        return lines
    }
}
