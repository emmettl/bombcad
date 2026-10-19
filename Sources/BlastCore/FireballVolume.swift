import BlastModel
import Foundation
import simd

extension BlastSolver {
    /// The luminous gas cell by cell over the box of `blocks` (see `LuminousBlock`): cut out on
    /// the GPU at the end of the batch that ended now if it was asked for (see `frameRequest`),
    /// otherwise read from the state on the CPU.
    func luminousCells(_ blocks: [LuminousBlock], luminousTemperature: Float) -> LuminousCells? {
        guard let firstBlock = blocks.first else { return nil }
        let dims = LuminousBlock.dimensions(grid)
        func coordinates(_ index: Int) -> SIMD3<Int> {
            SIMD3(index % dims.x, (index / dims.x) % dims.y, index / (dims.x * dims.y))
        }
        var lowest = coordinates(firstBlock.index)
        var highest = lowest
        for block in blocks {
            lowest = simd_min(lowest, coordinates(block.index))
            highest = simd_max(highest, coordinates(block.index))
        }
        let size = SIMD3(grid.nx, grid.ny, grid.nz)
        let low = 2 &* lowest
        let counts = simd_min(2 &* (highest &+ 1), size) &- low
        let hasProducts = speciesHoldDetonationProducts
        if let packed = frameExtractor?.luminousCells(
            luminous: luminousTemperature, time: time, steps: stepCount, count: grid.cellCount)
        {
            if let refined = refinedLuminousCells(
                low: low, counts: counts, luminousTemperature: luminousTemperature,
                coarse: { packed[grid.index($0.x, $0.y, $0.z)] })
            {
                return refined
            }
            return LuminousCells(
                cellSize: grid.cellSize, low: low, counts: counts, hasProducts: hasProducts
            ) { n in
                let i = n % counts.x
                let j = (n / counts.x) % counts.y
                let k = n / (counts.x * counts.y)
                return packed[grid.index(low.x + i, low.y + j, low.z + k)]
            }
        }
        let packed = cpuLuminousCells(low: low, counts: counts, luminousTemperature: luminousTemperature)
        if let refined = refinedLuminousCells(
            low: low, counts: counts, luminousTemperature: luminousTemperature,
            coarse: { c in
                let l = c &- low
                return packed[l.x + counts.x * (l.y + counts.y * l.z)]
            })
        {
            return refined
        }
        return LuminousCells(cellSize: grid.cellSize, low: low, counts: counts, hasProducts: hasProducts) {
            packed[$0]
        }
    }

    /// Where the air is refined over the box of `counts` coarse cells from `low`, its luminous gas
    /// at the finest level whose box of cells stays within `LuminousCells.maximumVoxels`: each of
    /// those cells taken from the finest patch that holds it, and from its coarse cell, through
    /// `coarse` (packed as `extractLuminousCells` writes it), where none does. Nil where no patch
    /// holds any of the box, which then goes as the coarse cells have it.
    func refinedLuminousCells(
        low: SIMD3<Int>, counts: SIMD3<Int>, luminousTemperature: Float, coarse: (SIMD3<Int>) -> UInt32
    ) -> LuminousCells? {
        let levels = refinementLevels
        guard let first = levels.first, first.holdsAny(from: low, through: low &+ counts &- 1),
            let top = levels.indices.last(where: {
                let n = counts &* (levels[$0].parentScale * levels[$0].ratio)
                return n.x * n.y * n.z <= LuminousCells.maximumVoxels
            })
        else { return nil }
        // Finest first: each level's cells along a coarse cell's edge, and its reader.
        let readers = levels[0...top].reversed().map { ($0.parentScale * $0.ratio, $0.fineReader()) }
        let scale = readers[0].0
        let fineLow = low &* scale
        let fineCounts = counts &* scale
        let gamma = configuration.gamma
        let airModel = configuration.airModel
        let hasProducts = speciesHoldDetonationProducts
        var packed = [UInt32](repeating: 0, count: fineCounts.x * fineCounts.y * fineCounts.z)
        packed.withUnsafeMutableBufferPointer { packed in
            concurrently(iterations: fineCounts.z) { k in
                for j in 0..<fineCounts.y {
                    for i in 0..<fineCounts.x {
                        let at = fineLow &+ SIMD3(i, j, k)
                        var value: UInt32?
                        for (cells, read) in readers {
                            guard let cell = read(at / (scale / cells)) else { continue }
                            value = Self.packedLuminous(
                                cell.state, products: hasProducts ? cell.products : 0, gamma: gamma,
                                airModel: airModel, luminousTemperature: luminousTemperature)
                            break
                        }
                        packed[i + fineCounts.x * (j + fineCounts.y * k)] = value ?? coarse(at / scale)
                    }
                }
            }
        }
        return LuminousCells(
            cellSize: grid.cellSize / Float(scale), low: fineLow, counts: fineCounts, hasProducts: hasProducts
        ) { packed[$0] }
    }

    /// A cell of air packed as `extractLuminousCells` writes it: its temperature in kelvin in the
    /// low 16 bits and its unburnt products' density as a half float in the high, or zero if it
    /// is cooler than `luminousTemperature`.
    static func packedLuminous(
        _ cell: CellState, products held: Float, gamma: Float, airModel: AirModel, luminousTemperature: Float
    ) -> UInt32 {
        let air = primitive(of: cell, gamma: gamma, airModel: airModel)
        let bound = air.pressure / (air.density * AirModel.gasConstant)
        guard bound >= luminousTemperature, bound.isFinite else { return 0 }
        let t =
            airModel == .dissociating
            ? airModel.temperature(density: air.density, pressure: air.pressure) : bound
        guard t >= luminousTemperature, t.isFinite else { return 0 }
        let kelvin = UInt32(min(max(t.rounded(), 1), 65535))
        let products = Float16(min(max(held, 0), 65504))
        return kelvin | UInt32(products.bitPattern) << 16
    }

    /// The cells of the box of `counts` from `low` packed as `extractLuminousCells` writes them,
    /// read from the state across the CPU's cores.
    func cpuLuminousCells(low: SIMD3<Int>, counts: SIMD3<Int>, luminousTemperature: Float) -> [UInt32] {
        let gamma = configuration.gamma
        let airModel = configuration.airModel
        let mask = maskContents.bindMemory(to: UInt8.self, capacity: grid.cellCount)
        var packed = [UInt32](repeating: 0, count: counts.x * counts.y * counts.z)
        let hasProducts = speciesHoldDetonationProducts
        withState { cells in
            readSpecies { species in
                packed.withUnsafeMutableBufferPointer { packed in
                    concurrently(iterations: counts.z) { k in
                        for j in 0..<counts.y {
                            for i in 0..<counts.x {
                                let index = grid.index(low.x + i, low.y + j, low.z + k)
                                guard mask[index] == 0 else { continue }
                                packed[i + counts.x * (j + counts.y * k)] = Self.packedLuminous(
                                    cells[index], products: hasProducts ? species?[index].x ?? 0 : 0,
                                    gamma: gamma, airModel: airModel, luminousTemperature: luminousTemperature
                                )
                            }
                        }
                    }
                }
            }
        }
        return packed
    }
}

/// The fireball as the march takes it. Each voxel holds its luminous share, its absorption
/// coefficient κ in 1/m (the gas's own times that share) and its emission κB, B = σT⁴ / π the
/// radiance of a black body at its temperature; and whether gas may be found in it, which it can
/// only where it or a voxel round it has some. Between the voxels' centres all three are
/// interpolated trilinearly, and the gas is where the share is at least one half, as the shape's
/// surface is: within it, the gas absorbs and emits as its luminous voxels round it do. A share
/// interpolated so, rather than whole voxels, keeps the outline from being a staircase of cubes,
/// which seen at an angle shows their sides (a sphere 40 voxels across came out 5% too bright from
/// ten radii away, however small the voxels). The tiles to sample it by are the shape's, round
/// every voxel with any luminous gas.
struct ThermalMedium: Sendable {
    var low: SIMD3<Float>
    var voxelSize: Float
    var counts: SIMD3<Int32>
    /// The share, κ, κB and 1 where gas may be found, else 0, a voxel.
    var voxels: [SIMD4<Float>]
    var tiles: [FireballTile]
    /// The march's step within voxels where gas may be found, in metres.
    var step: Float

    var high: SIMD3<Float> { low + SIMD3<Float>(counts) * voxelSize }

    /// The Planck-mean absorption coefficient of soot small against the wavelength, in 1/(m K)
    /// for a unit volume fraction: 3.72 C / C₂ with C = 7.0 (Williams, Shaddix et al., 2007),
    /// so that a volume fraction f at T absorbs 1817 f T a metre.
    static let sootAbsorption: Float = 1817
    /// Soot's density, kg/m³, to turn its mass into a volume fraction.
    static let sootDensity: Float = 1800

    /// The medium of `cells` under `spec`: each voxel's gas absorbs `spec.absorption` a metre for
    /// itself, and as soot `spec.sootYield` of its unburnt products would.
    init(_ cells: LuminousCells, spec: ThermalSpec) {
        low = cells.low
        voxelSize = cells.voxelSize
        counts = cells.counts
        step = spec.marchStep * cells.voxelSize
        let sigma = Float(ThermalExposure.stefanBoltzmann / Double.pi)
        let soot = Self.sootAbsorption * spec.sootYield / Self.sootDensity
        let n = SIMD3<Int>(truncatingIfNeeded: cells.counts)
        let plane = n.x * n.y
        var voxels = [SIMD4<Float>](repeating: .zero, count: cells.fills.count)
        voxels.withUnsafeMutableBufferPointer { voxels in
            concurrently(iterations: n.z) { k in
                for v in k * plane..<(k + 1) * plane {
                    let t = Float(cells.temperatures[v])
                    guard cells.fills[v] > 0, t > 0 else { continue }
                    let share = Float(cells.fills[v]) / 255
                    let products = cells.products.map { Float($0[v]) } ?? 0
                    let kappa = share * (spec.absorption + soot * products * t)
                    let square = t * t
                    voxels[v] = SIMD4(share, kappa, kappa * sigma * square * square, 0)
                }
            }
            // Gas may be found within a voxel only where it or one round it has some.
            concurrently(iterations: n.z) { k in
                for j in 0..<n.y {
                    for i in 0..<n.x {
                        var near = false
                        search: for c in max(k - 1, 0)...min(k + 1, n.z - 1) {
                            for b in max(j - 1, 0)...min(j + 1, n.y - 1) {
                                for a in max(i - 1, 0)...min(i + 1, n.x - 1)
                                where cells.fills[a + n.x * (b + n.y * c)] > 0 {
                                    near = true
                                    break search
                                }
                            }
                        }
                        if near { voxels[i + n.x * (j + n.y * k)].w = 1 }
                    }
                }
            }
        }
        self.voxels = voxels
        tiles = FireballShape.tiles(
            blockSize: cells.voxelSize, first: cells.first, counts: n, fills: cells.fills, threshold: 1)
    }

    /// The gas at `point`: the interpolated share, and where it is at least a half, the gas's
    /// absorption coefficient and its radiance as a black body, otherwise zero.
    func gas(at point: SIMD3<Float>) -> (share: Float, absorption: Float, radiance: Float) {
        let u = (point - low) / voxelSize - 0.5
        let base = floor(u)
        let f = u - base
        let corner = SIMD3<Int>(base)
        let n = SIMD3<Int>(truncatingIfNeeded: counts)
        var share: Float = 0
        var kappa: Float = 0
        var emission: Float = 0
        for dz in 0...1 {
            for dy in 0...1 {
                for dx in 0...1 {
                    let cell = corner &+ SIMD3(dx, dy, dz)
                    guard all(cell .>= 0), all(cell .< n) else { continue }
                    let w = (dx == 1 ? f.x : 1 - f.x) * (dy == 1 ? f.y : 1 - f.y) * (dz == 1 ? f.z : 1 - f.z)
                    let voxel = voxels[cell.x + n.x * (cell.y + n.y * cell.z)]
                    share += w * voxel.x
                    kappa += w * voxel.y
                    emission += w * voxel.z
                }
            }
        }
        guard share >= 0.5, kappa > 0 else { return (share, 0, 0) }
        return (share, kappa / share, emission / kappa)
    }

    /// What one step of `length` between two samples of the gas emits toward its near end, and
    /// what of the light from beyond it lets through. Where both ends are in the gas, it is
    /// taken at their mean; where one is, the surface lies where the share, linear between them,
    /// is a half, and only that part of the step is gas, as the end within it.
    static func step(
        _ a: (share: Float, absorption: Float, radiance: Float),
        _ b: (share: Float, absorption: Float, radiance: Float), length: Float
    ) -> (emitted: Float, passed: Float) {
        let inA = a.absorption > 0
        let inB = b.absorption > 0
        guard inA || inB else { return (0, 1) }
        var kappa: Float
        var radiance: Float
        var span = length
        if inA && inB {
            kappa = 0.5 * (a.absorption + b.absorption)
            radiance = (a.absorption * a.radiance + b.absorption * b.radiance) / (a.absorption + b.absorption)
        } else {
            let (inside, outside) = inA ? (a, b) : (b, a)
            kappa = inside.absorption
            radiance = inside.radiance
            span = length * min(max((inside.share - 0.5) / max(inside.share - outside.share, 1e-6), 0), 1)
        }
        let passed = exp(-kappa * span)
        return (radiance * (1 - passed), passed)
    }

    /// The radiance reaching `origin` along the unit `direction` from the medium out to `limit`
    /// metres. The voxels the ray crosses are followed (Amanatides and Woo's traversal), and
    /// through those where gas may be found the ray steps no more than `step` at a time: each step
    /// emits its gas's radiance times 1 - e^(-κ s) (see `step(_:_:length:)`), dimmed by the steps
    /// before it, e^(-Σκs). Given up once less than 10⁻⁴ of what lies beyond could get through.
    func radiance(from origin: SIMD3<Float>, along direction: SIMD3<Float>, limit: Float) -> Float {
        let low = self.low
        let high = self.high
        var enter: Float = 0
        var leave = limit
        for axis in 0..<3 {
            if direction[axis] == 0 {
                if origin[axis] < low[axis] || origin[axis] > high[axis] { return 0 }
                continue
            }
            var a = (low[axis] - origin[axis]) / direction[axis]
            var b = (high[axis] - origin[axis]) / direction[axis]
            if a > b { swap(&a, &b) }
            enter = max(enter, a)
            leave = min(leave, b)
        }
        guard enter < leave else { return 0 }
        let n = SIMD3<Int>(truncatingIfNeeded: counts)
        let start = (origin + enter * direction - low) / voxelSize
        var cell = SIMD3<Int>(simd_clamp(floor(start), SIMD3<Float>.zero, SIMD3<Float>(n &- 1)))
        var stride = SIMD3<Int>(repeating: 0)
        var next = SIMD3<Float>(repeating: .infinity)
        var delta = SIMD3<Float>(repeating: .infinity)
        for axis in 0..<3 where direction[axis] != 0 {
            stride[axis] = direction[axis] > 0 ? 1 : -1
            let boundary = low[axis] + (Float(cell[axis]) + (direction[axis] > 0 ? 1 : 0)) * voxelSize
            next[axis] = (boundary - origin[axis]) / direction[axis]
            delta[axis] = voxelSize / abs(direction[axis])
        }
        var distance = enter
        var radiance: Float = 0
        var through: Float = 1
        // The last sample, if it was at `distance`.
        var last: (share: Float, absorption: Float, radiance: Float)?
        while true {
            let axis: Int
            if next.x < next.y {
                axis = next.x < next.z ? 0 : 2
            } else {
                axis = next.y < next.z ? 1 : 2
            }
            let end = min(next[axis], leave)
            if voxels[cell.x + n.x * (cell.y + n.y * cell.z)].w > 0, end > distance {
                let steps = max(1, Int(((end - distance) / step).rounded(.up)))
                let length = (end - distance) / Float(steps)
                var a = last ?? gas(at: origin + distance * direction)
                for s in 1...steps {
                    let b = gas(at: origin + (distance + Float(s) * length) * direction)
                    let part = Self.step(a, b, length: length)
                    radiance += through * part.emitted
                    through *= part.passed
                    a = b
                }
                last = a
                if through < 1e-4 { break }
            } else {
                last = nil
            }
            if next[axis] >= leave { break }
            distance = next[axis]
            cell[axis] += stride[axis]
            if cell[axis] < 0 || cell[axis] >= n[axis] { break }
            next[axis] += delta[axis]
        }
        return radiance
    }
}

/// Follows rays from receivers through the fireball's medium: the volume model's irradiance.
protocol ThermalMarch: Sendable {
    /// The irradiance at each of `receivers` from `medium`, in W/m²: the radiance along each
    /// sampled direction, out to the ground or, if `occluded`, the first block or structure in
    /// the way, times its cosine on the receiver over the density of samples there from every cone
    /// it lies in.
    func irradiance(_ medium: ThermalMedium, receivers: ThermalReceiverSet, occluded: Bool) -> [Float]
}

/// The march on the CPU's cores, as `MetalThermalMarch` does it on the GPU.
struct CPUThermalMarch: ThermalMarch {
    let occluders: [Box]
    let terrain: TerrainSight?
    let spiral: [SIMD3<Float>]

    init(occluders: [Box], terrain: Terrain? = nil, spiral: [SIMD3<Float>]) {
        self.occluders = occluders
        self.terrain = TerrainSight(terrain)
        self.spiral = spiral
    }

    func irradiance(_ medium: ThermalMedium, receivers set: ThermalReceiverSet, occluded: Bool) -> [Float] {
        let receivers = set.receivers
        return [Float](unsafeUninitializedCapacity: receivers.count) { result, count in
            concurrently(iterations: receivers.count) { n in
                (result.baseAddress! + n).initialize(
                    to: irradiance(medium, at: receivers[n], occluded: occluded))
            }
            count = receivers.count
        }
    }

    func irradiance(_ medium: ThermalMedium, at receiver: ThermalReceiver, occluded: Bool) -> Float {
        let x = receiver.position
        let cones = SamplingCone.cones(
            at: x, normal: receiver.normal, tiles: medium.tiles, samples: spiral.count)
        var sum: Float = 0
        for (c, cone) in cones.enumerated() {
            for s in 0..<cone.count {
                let direction = cone.direction(s, spiral: spiral)
                let cosReceiver = simd_dot(receiver.normal, direction)
                guard cosReceiver > 0 else { continue }
                var limit = Float.infinity
                if direction.z < 0 { limit = -x.z / direction.z }
                if occluded { limit = nearest(from: x, along: direction, within: limit) }
                let radiance = medium.radiance(from: x, along: direction, limit: limit)
                guard radiance > 0 else { continue }
                var density = cone.density
                for (other, cone) in cones.enumerated()
                where other != c && simd_dot(direction, cone.axis) >= cone.cosHalfAngle {
                    density += cone.density
                }
                sum += cosReceiver * radiance / density
            }
        }
        return sum
    }

    /// How far along the ray the first occluder is, or `limit` if none is nearer.
    func nearest(from origin: SIMD3<Float>, along direction: SIMD3<Float>, within limit: Float) -> Float {
        var nearest = limit
        for box in occluders {
            if let t = Self.entry(box, origin, direction, nearest) { nearest = t }
        }
        if let terrain { nearest = terrain.nearest(from: origin, along: direction, within: nearest) }
        return nearest
    }

    /// Where the ray enters `box`, if before `limit`; zero if it starts inside.
    static func entry(_ box: Box, _ origin: SIMD3<Float>, _ direction: SIMD3<Float>, _ limit: Float) -> Float?
    {
        var low: Float = 0
        var high = limit
        for axis in 0..<3 {
            if direction[axis] == 0 {
                if origin[axis] < box.min[axis] || origin[axis] > box.max[axis] { return nil }
                continue
            }
            var a = (box.min[axis] - origin[axis]) / direction[axis]
            var b = (box.max[axis] - origin[axis]) / direction[axis]
            if a > b { swap(&a, &b) }
            low = max(low, a)
            high = min(high, b)
            if low > high { return nil }
        }
        return low < limit ? low : nil
    }
}

extension ThermalExposure {
    /// The march to use: on the GPU where there is one with ray tracing, borrowing `visibility`'s
    /// acceleration structure if given, otherwise on the CPU; `BOMBCAD_THERMAL_VISIBILITY=cpu` in
    /// the environment keeps it on the CPU.
    static func defaultMarch(
        occluders: [Box], terrain: Terrain? = nil, spiral: [SIMD3<Float>],
        visibility: MetalThermalVisibility? = nil
    ) -> any ThermalMarch {
        if ProcessInfo.processInfo.environment["BOMBCAD_THERMAL_VISIBILITY"] != "cpu",
            let metal = MetalThermalMarch(
                occluders: occluders, terrain: terrain, spiral: spiral, visibility: visibility)
        {
            return metal
        }
        return CPUThermalMarch(occluders: occluders, terrain: terrain, spiral: spiral)
    }

    /// The GPU's time on the volume's march so far, in seconds; nil if it is not marched there.
    public var marchGPUSeconds: Double? {
        (march as? MetalThermalMarch)?.usage.gpuSeconds
    }

    /// How many points each part of the enclosure has.
    static let enclosurePoints = 256

    /// A closed surface round a box on the ground, to measure what the fireball in it radiates: a
    /// dome centred under the box's middle, reaching a tenth beyond its farthest corner, its
    /// points facing in, and the ground within it, its points facing up. Each part has
    /// `enclosurePoints` points even in area; each point's area comes with it.
    static func enclosure(around low: SIMD3<Float>, _ high: SIMD3<Float>) -> [(ThermalReceiver, Float)] {
        let middle = (low + high) / 2
        let centre = SIMD3<Float>(middle.x, middle.y, 0)
        var reach: Float = 0
        for corner in 0..<8 {
            let point = SIMD3<Float>(
                corner & 1 == 0 ? low.x : high.x, corner & 2 == 0 ? low.y : high.y,
                corner & 4 == 0 ? max(low.z, 0) : max(high.z, 0))
            reach = max(reach, simd_length(point - centre))
        }
        let radius = 1.1 * reach + 0.01
        let count = enclosurePoints
        let golden = Double.pi * (3 - sqrt(5))
        var points: [(ThermalReceiver, Float)] = []
        for n in 0..<count {
            let z = (Float(n) + 0.5) / Float(count)
            let ring = sqrt(max(0, 1 - z * z))
            let phi = golden * Double(n)
            let out = SIMD3<Float>(ring * Float(cos(phi)), ring * Float(sin(phi)), z)
            points.append(
                (
                    ThermalReceiver(position: centre + radius * out, normal: -out, surface: "dome"),
                    2 * .pi * radius * radius / Float(count)
                ))
        }
        for n in 0..<count {
            let r = radius * sqrt((Float(n) + 0.5) / Float(count))
            let phi = golden * Double(n)
            points.append(
                (
                    ThermalReceiver(
                        position: centre + SIMD3(r * Float(cos(phi)), r * Float(sin(phi)), 0.001),
                        normal: SIMD3(0, 0, 1), surface: "ground"),
                    .pi * radius * radius / Float(count)
                ))
        }
        return points
    }

    /// What `frame`'s fireball radiates now, in watts, as this exposure's model has it: what crosses a closed surface round it
    /// (`enclosure`) with nothing in the way but the ground, so all it sends into the air, the
    /// part that then falls on the ground included. The ground under the fireball, within its
    /// luminous gas, is left out: what the gas sends into the ground it rests on is not radiated
    /// into the air. For an opaque sphere this is εσT⁴ over its surface above the ground.
    public func radiatedPower(_ frame: FireballFrame) -> Double {
        radiatedPower(frame, medium: medium(frame))
    }

    /// As `radiatedPower(_:)`, with the volume's medium already made.
    func radiatedPower(_ frame: FireballFrame, medium: ThermalMedium?) -> Double {
        guard frame.volume > 0, frame.temperature > 0 else { return 0 }
        let shape = spec.fireball != .sphere ? frame.shape : nil
        let (low, high): (SIMD3<Float>, SIMD3<Float>)
        if let medium {
            (low, high) = (medium.low, medium.high)
        } else if let shape {
            (low, high) = (shape.low, shape.high)
        } else {
            (low, high) = (frame.centre - frame.radius, frame.centre + frame.radius)
        }
        let enclosure = Self.enclosure(around: low, high)
        // Points on the ground within the luminous gas.
        let within = enclosure.map { point, _ -> Bool in
            guard point.surface == "ground" else { return false }
            let x = point.position
            if let medium { return medium.isLuminous(at: x) }
            if let shape { return shape.isInside(x) }
            return simd_length(x - frame.centre) <= frame.radius
        }
        let irradiance: [Float]
        if let medium, let march {
            irradiance = march.irradiance(
                medium, receivers: ThermalReceiverSet(enclosure.map(\.0)), occluded: false)
        } else {
            let ground = CPUThermalVisibility(occluders: [])
            let power = Float(
                Double(spec.emissivity) * Self.stefanBoltzmann * pow(Double(frame.temperature), 4))
            irradiance = [Float](unsafeUninitializedCapacity: enclosure.count) { result, count in
                concurrently(iterations: enclosure.count) { n in
                    var rays: [ThermalRay] = []
                    var weights: [Float] = []
                    let view = view(from: enclosure[n].0, frame, power: power, rays: &rays, weights: &weights)
                    var next = 0
                    let value = ground.visible(rays).withUnsafeBufferPointer { visible in
                        self.irradiance(view, visible: visible, weights: weights, from: &next)
                    }
                    (result.baseAddress! + n).initialize(to: value)
                }
                count = enclosure.count
            }
        }
        var total = 0.0
        for (n, (_, area)) in enclosure.enumerated() where !within[n] {
            total += Double(irradiance[n]) * Double(area)
        }
        return total
    }
}

extension ThermalMedium {
    /// Whether `point` is within the luminous gas.
    func isLuminous(at point: SIMD3<Float>) -> Bool { gas(at: point).radiance > 0 }
}
