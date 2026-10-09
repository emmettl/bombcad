import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

@Suite("The fireball as a partly transparent volume")
struct FireballVolumeTests {
    private let sigma = Float(ThermalExposure.stefanBoltzmann)

    private func scene(blocks: [Box] = []) -> FragmentScene {
        var scenario = Scenario(
            name: "Volume", domainSize: SIMD3(100, 100, 50), boxes: blocks,
            charge: Charge(mass: 1, position: SIMD3(50, 50, 10)))
        scenario.gauges = []
        return FragmentScene(scenario)
    }

    private func spec(absorption: Float, samples: Int = 2048) -> ThermalSpec {
        var spec = ThermalSpec()
        spec.fireball = .volume
        spec.absorption = absorption
        spec.sootYield = 0
        spec.samples = samples
        spec.groundSpacing = 20
        spec.surfaceSpacing = 20
        return spec
    }

    /// The exposure, its march on the CPU unless `gpu`, which is then required.
    private func exposure(_ spec: ThermalSpec, blocks: [Box] = [], gpu: Bool = false) throws
        -> ThermalExposure
    {
        let spiral = ThermalExposure.spread(spec.samples)
        let occluders = blocks
        let march: any ThermalMarch =
            gpu
            ? try #require(
                MetalThermalMarch(occluders: occluders, spiral: spiral), "This test needs ray tracing")
            : CPUThermalMarch(occluders: occluders, spiral: spiral)
        return ThermalExposure(
            spec: spec, scene: scene(blocks: blocks), visibility: CPUThermalVisibility(occluders: occluders),
            march: march)
    }

    /// A sphere of gas at `temperature` in voxels `size` a side: each voxel filled as much as it is
    /// inside the sphere, judged at 4³ points in it, or with `sharp` wholly where its centre is.
    private func sphere(
        _ centre: SIMD3<Float>, radius: Float, size: Float, temperature: UInt16 = 2000, sharp: Bool = false
    ) -> LuminousCells {
        let low = centre - radius - size
        let first = SIMD3<Int32>((low / size).rounded(.down))
        let counts = SIMD3<Int32>(repeating: Int32((2 * (radius + size) / size).rounded(.up)) + 1)
        var fills: [UInt8] = []
        for k in 0..<counts.z {
            for j in 0..<counts.y {
                for i in 0..<counts.x {
                    let corner = SIMD3<Float>(first &+ SIMD3(i, j, k)) * size
                    if sharp {
                        fills.append(simd_distance(corner + size / 2, centre) <= radius ? 255 : 0)
                        continue
                    }
                    var count = 0
                    for c in 0..<4 {
                        for b in 0..<4 {
                            for a in 0..<4 {
                                let point =
                                    corner + (SIMD3<Float>(Float(a), Float(b), Float(c)) + 0.5) / 4 * size
                                if simd_distance(point, centre) <= radius { count += 1 }
                            }
                        }
                    }
                    fills.append(UInt8((255 * Double(count) / 64).rounded()))
                }
            }
        }
        return LuminousCells(
            voxelSize: size, first: first, counts: counts, fills: fills,
            temperatures: fills.map { $0 > 0 ? temperature : 0 }, products: nil)
    }

    /// A sphere of gas at 2,400 K at its centre, cooling by 120 K a metre outwards.
    private func hotSphere(_ centre: SIMD3<Float>, radius: Float, size: Float) -> LuminousCells {
        let cells = sphere(centre, radius: radius, size: size)
        let counts = SIMD3<Int>(truncatingIfNeeded: cells.counts)
        let temperatures = cells.temperatures.indices.map { n -> UInt16 in
            guard cells.temperatures[n] > 0 else { return 0 }
            let at = SIMD3<Float>(
                Float(n % counts.x), Float((n / counts.x) % counts.y), Float(n / (counts.x * counts.y)))
            return UInt16(2400 - 120 * simd_distance(cells.low + (at + 0.5) * cells.voxelSize, centre))
        }
        return LuminousCells(
            voxelSize: cells.voxelSize, first: cells.first, counts: cells.counts, fills: cells.fills,
            temperatures: temperatures, products: nil)
    }

    /// The voxels of `cells` above the ground.
    private func above(_ cells: LuminousCells) -> LuminousCells {
        let n = SIMD3<Int>(truncatingIfNeeded: cells.counts)
        let start = Int(max(0, -cells.first.z))
        let kept = (start..<n.z).flatMap { k in (0..<n.x * n.y).map { k * n.x * n.y + $0 } }
        return LuminousCells(
            voxelSize: cells.voxelSize,
            first: SIMD3(cells.first.x, cells.first.y, cells.first.z + Int32(start)),
            counts: SIMD3(cells.counts.x, cells.counts.y, cells.counts.z - Int32(start)),
            fills: kept.map { cells.fills[$0] }, temperatures: kept.map { cells.temperatures[$0] },
            products: nil)
    }

    private func frame(
        _ cells: LuminousCells, _ centre: SIMD3<Float>, temperature: Float = 2000, time: Double = 0
    )
        -> FireballFrame
    {
        FireballFrame(
            time: time, volume: cells.volume, centre: centre, temperature: temperature, hottest: temperature,
            cells: cells)
    }

    private func irradiance(
        _ exposure: ThermalExposure, _ frame: FireballFrame, at position: SIMD3<Float>,
        facing normal: SIMD3<Float>
    ) throws -> Float {
        let medium = try #require(exposure.medium(frame))
        let receiver = ThermalReceiver(position: position, normal: simd_normalize(normal), surface: "test")
        return exposure.march!.irradiance(medium, receivers: ThermalReceiverSet([receiver]), occluded: true)[
            0]
    }

    /// The irradiance `d` from the centre of a uniform sphere of radius `r` absorbing `kappa` a
    /// metre, on a surface facing it: B ∫ (1 − e^(−κ c)) cos α dω over the cone the sphere fills, c
    /// the chord along α. By Simpson's rule in α.
    private func uniformSphere(radius r: Double, distance d: Double, kappa: Double, temperature: Double)
        -> Double
    {
        let b = ThermalExposure.stefanBoltzmann * pow(temperature, 4) / Double.pi
        let top = asin(r / d)
        let steps = 20_000
        func f(_ a: Double) -> Double {
            let chord = 2 * (max(0, r * r - d * d * sin(a) * sin(a))).squareRoot()
            return (1 - exp(-kappa * chord)) * cos(a) * 2 * Double.pi * sin(a)
        }
        var sum = f(0) + f(top)
        for n in 1..<steps { sum += Double(n % 2 == 0 ? 2 : 4) * f(top * Double(n) / Double(steps)) }
        return b * sum * top / Double(steps) / 3
    }

    @Test("An opaque isothermal sphere gives the present answer, (r/d)² cos θ σT⁴")
    func opaque() throws {
        let centre = SIMD3<Float>(50, 50, 20)
        let cells = sphere(centre, radius: 2, size: 0.1, sharp: true)
        let frame = frame(cells, centre)
        let exposure = try exposure(spec(absorption: 500))
        let r = Float(cbrt(3 * cells.volume / (4 * Double.pi)))
        let power = sigma * pow(2000, 4)
        let below = SIMD3<Float>(50, 50, 10)
        let faceOn = try irradiance(exposure, frame, at: below, facing: SIMD3(0, 0, 1))
        #expect(abs(faceOn / (power * (r / 10) * (r / 10)) - 1) < 0.02, "\(faceOn)")
        let tilt = Float.pi / 3
        let atAngle = try irradiance(exposure, frame, at: below, facing: SIMD3(sin(tilt), 0, cos(tilt)))
        #expect(abs(atAngle / (power * (r / 10) * (r / 10) * cos(tilt)) - 1) < 0.02, "\(atAngle)")
        // The present model, the same frame as its sphere.
        var sphereSpec = spec(absorption: 500)
        sphereSpec.fireball = .sphere
        let present = ThermalExposure(
            spec: sphereSpec, scene: scene(), visibility: CPUThermalVisibility(occluders: [])
        )
        .irradiance(
            at: ThermalReceiver(position: below, normal: SIMD3(0, 0, 1), surface: "test"), frame, power: power
        )
        #expect(abs(faceOn / present - 1) < 0.02, "\(faceOn) against \(present)")
        // Within the gas, all of σT⁴.
        let inside = try irradiance(exposure, frame, at: centre, facing: SIMD3(0, 0, 1))
        #expect(abs(inside / power - 1) < 1e-3, "\(inside)")
    }

    @Test(
        "An optically thin uniform sphere gives the volume's emission, κ B V / d², and thicker ones the integral"
    )
    func thin() throws {
        let centre = SIMD3<Float>(50, 50, 20)
        let cells = sphere(centre, radius: 2, size: 0.2)
        let frame = frame(cells, centre)
        let below = SIMD3<Float>(50, 50, 12)
        for kappa: Float in [0.005, 0.5, 2] {
            let found = try irradiance(
                try exposure(spec(absorption: kappa)), frame, at: below, facing: SIMD3(0, 0, 1))
            let expected = uniformSphere(radius: 2, distance: 8, kappa: Double(kappa), temperature: 2000)
            #expect(abs(Double(found) / expected - 1) < 0.01, "κ \(kappa): \(found) against \(expected)")
            if kappa < 0.01 {
                // Nothing absorbed: every cell's emission, 4κσT⁴ a cubic metre spread evenly, reaches it.
                let emitted = Double(kappa) * Double(sigma) * pow(2000, 4) / Double.pi * cells.volume / 64
                #expect(abs(Double(found) / emitted - 1) < 0.02, "\(found) against \(emitted)")
            }
        }
    }

    @Test("A receiver behind a block sees none of the fireball, one beside it all")
    func hidden() throws {
        let centre = SIMD3<Float>(50, 50, 20)
        let frame = frame(sphere(centre, radius: 2, size: 0.2), centre)
        let slab = Box(min: SIMD3(40, 40, 14), max: SIMD3(60, 60, 15))
        let blocked = try exposure(spec(absorption: 1), blocks: [slab])
        let open = try exposure(spec(absorption: 1))
        let below = SIMD3<Float>(50, 50, 5)
        #expect(try irradiance(blocked, frame, at: below, facing: SIMD3(0, 0, 1)) == 0)
        #expect(try irradiance(open, frame, at: below, facing: SIMD3(0, 0, 1)) > 0)
        // Beside the slab the view is clear.
        let beside = SIMD3<Float>(30, 50, 20)
        let a = try irradiance(blocked, frame, at: beside, facing: SIMD3(1, 0, 0))
        let b = try irradiance(open, frame, at: beside, facing: SIMD3(1, 0, 0))
        #expect(a == b && a > 0)
        // Facing away, nothing.
        #expect(try irradiance(open, frame, at: beside, facing: SIMD3(-1, 0, 0)) == 0)
    }

    @Test("The answer converges as the voxels shrink and the rays grow in number")
    func convergence() throws {
        let centre = SIMD3<Float>(50, 50, 20)
        let power = sigma * pow(2000, 4)
        // Opaque, against the sphere of the voxels' volume: as the step shrinks, and as the
        // voxels do, filled as much as they are inside it or, as the air's cells are, wholly or
        // not at all.
        func opaqueError(divisions: Float, step: Float, sharp: Bool = false) throws -> Float {
            let cells = sphere(centre, radius: 2, size: 2 / divisions, sharp: sharp)
            var spec = spec(absorption: 500)
            spec.marchStep = step
            let r = Float(cbrt(3 * cells.volume / (4 * Double.pi)))
            let found = try irradiance(
                try exposure(spec), frame(cells, centre), at: SIMD3(50, 50, 12), facing: SIMD3(0, 0, 1))
            return found / (power * (r / 8) * (r / 8)) - 1
        }
        var errors = try [2, 1, 0.5, 0.25, 0.1].map { try opaqueError(divisions: 10, step: $0) }
        print("Opaque sphere 10 voxels in radius, steps 2 to 0.1 voxels:", errors)
        #expect(abs(errors.last!) < 0.01 && abs(errors.last!) <= abs(errors.first!), "\(errors)")
        errors = try [4, 8, 16, 32].map { try opaqueError(divisions: $0, step: 0.25) }
        print("Opaque sphere 4 to 32 voxels in radius:", errors)
        #expect(abs(errors.last!) < 0.005 && abs(errors.last!) < abs(errors.first!), "\(errors)")
        errors = try [4, 8, 16, 32].map { try opaqueError(divisions: $0, step: 0.25, sharp: true) }
        print("Opaque sphere of whole voxels, 4 to 32 voxels in radius:", errors)
        #expect(errors.last! < 0.02 && errors.last! < errors.first!, "\(errors)")
        // A fireball hotter within, partly transparent, as the rays grow in number, against 4096.
        let hot = hotSphere(SIMD3(50, 50, 20), radius: 2, size: 0.1)
        let answers = try [16, 64, 256, 1024, 4096].map { samples in
            try irradiance(
                exposure(spec(absorption: 0.5, samples: samples)), frame(hot, SIMD3(50, 50, 20)),
                at: SIMD3(46, 50, 16), facing: SIMD3(1, 0, 1))
        }
        errors = answers.map { abs($0 / answers.last! - 1) }
        print("A hot-cored sphere, 16 to 1024 rays against 4096:", errors.dropLast())
        #expect(errors[3] < 0.005 && errors[3] < errors[0], "\(errors)")
    }

    @Test("The GPU's march agrees with the CPU's")
    func gpuAgrees() throws {
        guard MTLCreateSystemDefaultDevice()?.supportsRaytracing == true else { return }
        let centre = SIMD3<Float>(50, 40, 6)
        // Hotter within, as a fireball is.
        let cells = hotSphere(centre, radius: 4, size: 0.25)
        let blocks = [
            Box(min: SIMD3(56, 30, 0), max: SIMD3(60, 50, 8)),
            Box(min: SIMD3(40, 48, 0), max: SIMD3(44, 52, 12)),
        ]
        var spec = spec(absorption: 0.4, samples: 64)
        spec.groundSpacing = 8
        spec.surfaceSpacing = 4
        let cpu = try exposure(spec, blocks: blocks).irradiance(frame(cells, centre))
        let gpu = try exposure(spec, blocks: blocks, gpu: true).irradiance(frame(cells, centre))
        let largest = cpu.max() ?? 0
        #expect(largest > 0 && cpu.count == gpu.count)
        let worst = zip(cpu, gpu).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 1e-3 * largest, "\(worst) of \(largest)")
        #expect(cpu.filter { $0 == 0 }.count == gpu.filter { $0 == 0 }.count)
    }

    @Test("What a fireball radiates is measured round it: σT⁴ over an opaque sphere, 4κσT⁴V for a thin one")
    func radiated() throws {
        let power = Double(sigma) * pow(2000, 4)
        // Opaque and above the ground: all of its surface.
        let high = SIMD3<Float>(50, 50, 10)
        var cells = sphere(high, radius: 2, size: 0.1, sharp: true)
        var r = cbrt(3 * cells.volume / (4 * Double.pi))
        let opaque = try exposure(spec(absorption: 500, samples: 256))
        let free = opaque.radiatedPower(frame(cells, high), medium: opaque.medium(frame(cells, high)))
        #expect(abs(free / (power * 4 * Double.pi * r * r) - 1) < 0.03, "\(free)")
        // Resting on the ground, half of it: its dome, not its base.
        let low = SIMD3<Float>(50, 50, 0)
        cells = sphere(low, radius: 2, size: 0.1, sharp: true)
        let half = above(cells)
        r = cbrt(3 * half.volume / (2 * Double.pi))
        let resting = opaque.radiatedPower(frame(half, low), medium: opaque.medium(frame(half, low)))
        #expect(abs(resting / (power * 2 * Double.pi * r * r) - 1) < 0.05, "\(resting)")
        // Thin: every cell's emission.
        cells = sphere(high, radius: 2, size: 0.2)
        let thin = try exposure(spec(absorption: 0.005, samples: 256))
        let emitted = thin.radiatedPower(frame(cells, high), medium: thin.medium(frame(cells, high)))
        let expected = 4 * 0.005 * power * cells.volume
        #expect(abs(emitted / expected - 1) < 0.03, "\(emitted) against \(expected)")
    }

    @Test("The products' soot absorbs as Rayleigh particles do, 1817 f T a metre")
    func soot() {
        var spec = spec(absorption: 0.1)
        spec.sootYield = 0.2
        let cells = LuminousCells(
            voxelSize: 1, first: .zero, counts: SIMD3(2, 1, 1), fills: [255, 128],
            temperatures: [2000, 1500],
            products: [0.05, 0.1])
        let medium = ThermalMedium(cells, spec: spec)
        let f = 0.2 * 0.05 / 1800 as Float
        #expect(abs(medium.voxels[0].y / (0.1 + 1817 * f * 2000) - 1) < 1e-3)
        #expect(
            abs(medium.voxels[1].y / (128 / 255 * (0.1 + 1817 * 0.2 * Float(Float16(0.1)) / 1800 * 1500)) - 1)
                < 1e-3)
        #expect(abs(medium.voxels[0].z / medium.voxels[0].y / (sigma * pow(2000, 4) / .pi) - 1) < 1e-5)
        // At the first voxel's centre, the gas is its own.
        let gas = medium.gas(at: SIMD3(0.5, 0.5, 0.5))
        #expect(abs(gas.absorption / medium.voxels[0].y - 1) < 1e-5 && gas.radiance > 0)
    }

    @Test("The cells travel intact, and a fireball too large is merged until it fits")
    func cells() throws {
        let cells = LuminousCells(
            voxelSize: 0.25, first: SIMD3(3, 4, 0), counts: SIMD3(2, 2, 1), fills: [255, 0, 255, 255],
            temperatures: [2000, 0, 1800, 2400], products: [0.5, 0, 1, 0.25])
        #expect(try LuminousCells(binary: cells.binary) == cells)
        let frame = FireballFrame(
            time: 0.01, volume: 1, centre: .zero, temperature: 2000, hottest: 2400, cells: cells)
        #expect(try JSONDecoder().decode(FireballFrame.self, from: JSONEncoder().encode(frame)) == frame)
        #expect(frame.withoutShape.cells == nil && frame.withoutCells.cells == nil)
        #expect(throws: (any Error).self) { try LuminousCells(binary: cells.binary.dropLast()) }
        // 128 by 128 by 128 cells, all luminous, merged in twos.
        let counts = SIMD3(128, 128, 128)
        let merged = try #require(
            LuminousCells(cellSize: 0.1, low: SIMD3(10, 10, 0), counts: counts, hasProducts: false) { _ in
                2000
            })
        #expect(
            merged.voxelSize == 0.2 && merged.counts == SIMD3(64, 64, 64) && merged.first == SIMD3(5, 5, 0))
        #expect(merged.fills.allSatisfy { $0 == 255 } && merged.temperatures.allSatisfy { $0 == 2000 })
        #expect(abs(merged.volume - 12.8 * 12.8 * 12.8) < 1e-3)
    }

    @Test("A description is the volume unless it says otherwise, and older ones keep their model")
    func model() throws {
        let defaults = try JSONDecoder().decode(ThermalSpec.self, from: Data("{}".utf8))
        #expect(defaults.fireball == .volume && defaults.absorption == 0.1 && defaults.sootYield == 0.185)
        let shape = try JSONDecoder().decode(ThermalSpec.self, from: Data(#"{"fireball": "shape"}"#.utf8))
        #expect(shape.fireball == .shape)
        var bad = ThermalSpec()
        bad.absorption = -1
        #expect(throws: (any Error).self) { try bad.validate() }
    }
}
