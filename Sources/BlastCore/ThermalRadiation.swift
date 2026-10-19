import BlastModel
import Foundation
import simd

extension BlastSolver {
    /// The fireball now: every cell of air at least `luminousTemperature` kelvin, summed in
    /// blocks of two cells a side. Summed on the GPU if the batch that ended now was asked for it
    /// (see `frameRequest`); otherwise read from the state, spread across the CPU's cores, so call
    /// it only while no batch is in flight.
    public func fireball(for spec: ThermalSpec) -> FireballFrame {
        fireball(luminousTemperature: spec.luminousTemperature, cells: spec.fireball == .volume)
    }

    /// As `fireball(for:)`; with `cells`, the luminous gas cell by cell too, for the volume model.
    public func fireball(luminousTemperature: Float, cells: Bool = false) -> FireballFrame {
        let blocks =
            frameExtractor?.fireballBlocks(luminous: luminousTemperature, time: time, steps: stepCount)
            ?? cpuLuminousBlocks(luminousTemperature: luminousTemperature)
        // In the blocks' order and in double precision, so the same from one run to the next.
        var count = 0.0
        var position = SIMD3<Double>.zero
        var fourth = 0.0
        var hottest: Float = 0
        for block in blocks {
            count += Double(block.cells)
            position += SIMD3<Double>(block.position)
            fourth += Double(block.fourth)
            hottest = max(hottest, block.hottest)
        }
        guard count > 0 else {
            return FireballFrame(time: time, volume: 0, centre: .zero, temperature: 0, hottest: 0)
        }
        let h = grid.cellSize
        return FireballFrame(
            time: time, volume: count * pow(Double(h), 3), centre: SIMD3<Float>(position / count) * h,
            temperature: Float(pow(fourth / count, 0.25)), hottest: hottest,
            shape: FireballShape(blocks: blocks, grid: grid),
            cells: cells ? luminousCells(blocks, luminousTemperature: luminousTemperature) : nil)
    }
}

/// The fireball's radiation on a scene's surfaces, frame by frame: the irradiance at each
/// receiver, its peak and its time integral, the fluence. The fireball is a partly transparent
/// volume whose cells emit and absorb (`ThermalMedium`), or an opaque grey body, its own shape or
/// its equivalent sphere; each receiver sees what of it is above its own horizon, above the ground
/// and not hidden behind a block or the structure's starting outline. The air between is taken as
/// transparent.
public struct ThermalExposure: Sendable {
    public static let stefanBoltzmann = 5.670_374e-8

    public let spec: ThermalSpec
    public let receivers: [ThermalReceiver]
    /// In watts a square metre.
    public private(set) var peakIrradiance: [Float]
    /// In joules a square metre.
    public private(set) var fluence: [Double]
    public private(set) var frames: [FireballFrame] = []
    /// The receivers' surfaces heating up, unless the spec turns it off.
    public private(set) var heating: SurfaceHeating?
    /// What stands between the receivers and the fireball.
    let visibility: any ThermalVisibility
    /// The volume model's march through the fireball, and the receivers as it takes them.
    let march: (any ThermalMarch)?
    let receiverSet: ThermalReceiverSet
    /// The charge's energy, in joules, to set the radiated energy against.
    let chargeEnergy: Double
    /// Points spread evenly over a cone, each as the fraction of the way to its rim in the
    /// cosine of the angle off its axis, and the cosine and sine of the angle round it.
    let cone: [SIMD3<Float>]
    private var lastIrradiance: [Float]?

    /// `visibility` tests what blocks the receivers' view, by default `defaultVisibility`'s.
    public init(spec: ThermalSpec, scene: FragmentScene, visibility: (any ThermalVisibility)? = nil) {
        self.init(spec: spec, scene: scene, visibility: visibility, march: nil)
    }

    /// `march` follows rays through the volume, by default `defaultMarch`'s, sharing the
    /// visibility's acceleration structure where it has one.
    init(
        spec: ThermalSpec, scene: FragmentScene, visibility: (any ThermalVisibility)?,
        march: (any ThermalMarch)?
    ) {
        self.spec = spec
        let grids = Self.surfaceGrids(scene: scene, spec: spec)
        receivers = grids.flatMap(\.receivers)
        heating = spec.heating.enabled ? SurfaceHeating(spec: spec.heating, grids: grids, scene: scene) : nil
        let occluders = Self.occluders(scene)
        let visibility = visibility ?? Self.defaultVisibility(occluders: occluders, terrain: scene.terrain)
        self.visibility = visibility
        chargeEnergy = Self.chargeEnergy(scene)
        cone = Self.spread(spec.samples)
        receiverSet = ThermalReceiverSet(receivers)
        self.march =
            spec.fireball != .volume
            ? nil
            : march
                ?? Self.defaultMarch(
                    occluders: occluders, terrain: scene.terrain, spiral: cone,
                    visibility: visibility as? MetalThermalVisibility)
        peakIrradiance = [Float](repeating: 0, count: receivers.count)
        fluence = [Double](repeating: 0, count: receivers.count)
    }

    /// Adds the fireball at the next frame, integrating the irradiance since the last by the
    /// trapezium rule.
    public mutating func add(_ frame: FireballFrame) {
        let medium = self.medium(frame)
        let now =
            medium.map { march!.irradiance($0, receivers: receiverSet, occluded: true) } ?? irradiance(frame)
        if let last = frames.last, let before = lastIrradiance {
            let step = frame.time - last.time
            for n in receivers.indices { fluence[n] += 0.5 * Double(before[n] + now[n]) * step }
        }
        for n in receivers.indices { peakIrradiance[n] = max(peakIrradiance[n], now[n]) }
        heating?.advance(to: frame.time, irradiance: now)
        var kept = frame.withoutShape
        // Measured only for the volume; the opaque models keep their equivalent sphere's.
        kept.radiatedPower = medium.map { radiatedPower(frame, medium: $0) }
        frames.append(kept)
        lastIrradiance = now
    }

    /// The fireball of `frame` as the volume model marches it, if that is the model and the frame
    /// has its cells.
    func medium(_ frame: FireballFrame) -> ThermalMedium? {
        guard spec.fireball == .volume, march != nil, frame.volume > 0, let cells = frame.cells else {
            return nil
        }
        return ThermalMedium(cells, spheres: frame.spheres, spec: spec)
    }

    /// The irradiance at every receiver from `frame`'s fireball: every receiver's rays toward it,
    /// gathered across the CPU's cores, tested together, then summed.
    public func irradiance(_ frame: FireballFrame) -> [Float] {
        if let medium = medium(frame), let march {
            return march.irradiance(medium, receivers: receiverSet, occluded: true)
        }
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
                    concurrently(iterations: chunks) { c in
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
            concurrently(iterations: chunks) { c in
                _ = UnsafeMutableBufferPointer(rebasing: buffer[offsets[c]..<offsets[c + 1]]).initialize(
                    from: rays[c])
            }
            count = offsets.last!
        }
        let visible = visibility.visible(all)
        result.withUnsafeMutableBufferPointer { result in
            visible.withUnsafeBufferPointer { visible in
                concurrently(iterations: chunks) { c in
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
        // The volume falls back on the shape where a frame has no cells.
        if spec.fireball != .sphere, let shape = frame.shape {
            return view(from: receiver, shape, rays: &rays, weights: &weights)
        }
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
        surfaceGrids(scene: scene, spec: spec).flatMap(\.receivers)
    }

    /// The receivers by surface, as the grids they lie on: the ground's, and each face's of the
    /// blocks and the structure, in the order `receivers` lists them.
    public static func surfaceGrids(scene: FragmentScene, spec: ThermalSpec) -> [ThermalSurfaceGrid] {
        let solids = scene.blocks + scene.structure
        func buried(_ point: SIMD3<Float>) -> Bool {
            solids.contains { $0.contains(point) } || (scene.terrain?.contains(point) ?? false)
                || point.x < 0 || point.y < 0 || point.x > scene.domain.x || point.y > scene.domain.y
                || point.z > scene.domain.z
        }
        let lift: Float = 0.001
        var grids: [ThermalSurfaceGrid] = []
        var first = 0
        let spacing = spec.groundSpacing(over: scene.domain)
        let columns = max(1, Int((scene.domain.x / spacing).rounded(.up)))
        let rows = max(1, Int((scene.domain.y / spacing).rounded(.up)))
        var ground = ThermalSurfaceGrid(
            surface: "ground", origin: .zero, u: SIMD3(scene.domain.x, 0, 0), v: SIMD3(0, scene.domain.y, 0),
            normal: SIMD3(0, 0, 1), columns: columns, rows: rows)
        for j in 0..<rows {
            for i in 0..<columns {
                // Over a terrain, on its surface and facing out of it.
                let at = SIMD2<Float>(
                    (Float(i) + 0.5) * scene.domain.x / Float(columns),
                    (Float(j) + 0.5) * scene.domain.y / Float(rows))
                let normal = scene.terrain?.normal(at: at) ?? SIMD3(0, 0, 1)
                let point = SIMD3(at.x, at.y, scene.terrain?.height(at: at) ?? 0) + lift * normal
                ground.add(point, column: i, row: j, buried: buried(point), first: &first, normal: normal)
            }
        }
        grids.append(ground)
        let labelled =
            scene.blocks.enumerated().map { ($1, "block \($0)") } + scene.structure.map { ($0, "structure") }
        for (solid, (box, label)) in labelled.enumerated() {
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
                    var origin = box.min
                    origin[axis] = side < 0 ? box.min[axis] : box.max[axis]
                    var (uEdge, vEdge) = (SIMD3<Float>.zero, SIMD3<Float>.zero)
                    uEdge[u] = box.size[u]
                    vEdge[v] = box.size[v]
                    var face = ThermalSurfaceGrid(
                        surface: label, origin: origin, u: uEdge, v: vEdge, normal: normal, columns: nu,
                        rows: nv, solid: solid)
                    for b in 0..<nv {
                        for a in 0..<nu {
                            var point = SIMD3<Float>.zero
                            point[axis] = (side < 0 ? box.min[axis] : box.max[axis]) + side * lift
                            point[u] = box.min[u] + (Float(a) + 0.5) * box.size[u] / Float(nu)
                            point[v] = box.min[v] + (Float(b) + 0.5) * box.size[v] / Float(nv)
                            face.add(point, column: a, row: b, buried: buried(point), first: &first)
                        }
                    }
                    grids.append(face)
                }
            }
        }
        return grids
    }

    /// The charge's energy, in joules, as the result reports it.
    public static func chargeEnergy(_ scene: FragmentScene) -> Double {
        Double(scene.charge.mass) * Double(Charge.energyPerKilogram)
    }

    public var result: ThermalResult {
        ThermalResult(
            spec: spec, receivers: receivers, peakIrradiance: peakIrradiance,
            fluence: fluence.map { Float($0) },
            fireball: frames, chargeEnergy: chargeEnergy,
            heating: heating?.result(fluence: fluence.map { Float($0) }))
    }
}

extension ThermalResult {
    /// What the fireball radiated through the run, in joules, by the trapezium rule: as each
    /// frame measured it (`FireballFrame.radiatedPower`), or where a frame did not, from its
    /// equivalent sphere, its emissive power over the part above the ground. Nothing takes this
    /// energy out of the gas, so a share of the charge's energy beyond what fireballs are seen to
    /// radiate shows the emissivity, or the volume's absorption, is too high.
    public var radiatedEnergy: Double {
        let measured = isRadiationMeasured
        let power = fireball.map { frame -> Double in
            if measured { return frame.radiatedPower ?? 0 }
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
            let how =
                spec.fireball == .volume
                ? (isRadiationMeasured
                    ? String(format: "from its cells, absorbing %g/m", spec.absorption)
                        + (spec.sootYield > 0
                            ? String(format: " and soot %g of its products", spec.sootYield) : "")
                    : "as its equivalent sphere, not measured from its cells")
                : String(format: "at emissivity %.2f", spec.emissivity)
            lines.append(
                String(
                    format: "  radiated %.1f MJ, %.1f%% of the charge's energy, %@",
                    radiatedEnergy / 1e6, 100 * radiatedEnergy / max(chargeEnergy, 1), how))
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
        if let heating { lines += heating.summary(receivers: receivers) }
        return lines
    }
}
