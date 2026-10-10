import Foundation
import Testing
import simd

@testable import BlastCore

@Suite("Surfaces heated by the fireball's radiation")
struct SurfaceHeatingTests {
    private let ambient = 293.15

    /// A material that absorbs all and emits nothing, so the closed forms apply.
    private func lossless(_ material: ThermalMaterial) -> ThermalMaterial {
        var material = material
        material.absorptivity = 1
        material.emissivity = 0
        return material
    }

    private func spec(cells: Int = 32, convection: Float = 0) -> SurfaceHeatingSpec {
        var spec = SurfaceHeatingSpec()
        spec.cells = cells
        spec.convection = convection
        return spec
    }

    /// The surface's (and the back node's) temperatures at each of `times` under irradiance `q(t)`,
    /// stepping by `dt`, each step taking the irradiance linearly between its ends.
    private func run(
        _ column: Column, q: (Double) -> Double, times: [Double], dt: Double, convection: Double = 0
    ) -> [(surface: Double, back: Double)] {
        var t = [Double](repeating: ambient, count: column.capacity.count)
        var work = Column.Work(nodes: t.count)
        var now = 0.0
        var answers: [(Double, Double)] = []
        for time in times {
            let steps = max(1, Int(((time - now) / dt).rounded(.up)))
            let step = (time - now) / Double(steps)
            for s in 0..<steps {
                let a = now + Double(s) * step
                t.withUnsafeMutableBufferPointer { t in
                    column.step(
                        t.baseAddress!, dt: step, from: q(a), to: q(a + step), ambient: ambient,
                        convection: convection, work: &work)
                }
            }
            now = time
            answers.append((t[0], t[t.count - 1]))
        }
        return answers
    }

    private func column(
        _ material: ThermalMaterial, thickness: Float? = nil, solid: Float? = nil, spec: SurfaceHeatingSpec
    )
        -> Column
    {
        Column(
            HeatedMaterial(name: material.name, layers: [.init(material, thickness: thickness)]),
            solid: solid, spec: spec)
    }

    /// 2q √(t / πkρc).
    private func closedForm(_ m: ThermalMaterial, q: Double, t: Double) -> Double {
        2 * q
            * (t / (Double.pi * Double(m.conductivity) * Double(m.density) * Double(m.specificHeat)))
            .squareRoot()
    }

    @Test("A constant flux on a semi-infinite solid: the rise is 2q√(t/πkρc)")
    func semiInfinite() {
        for material in [ThermalMaterial.concrete, .steel, .softwood, .glass] {
            let m = lossless(material)
            let times = [0.001, 0.01, 0.17, 1]
            let answers = run(column(m, spec: spec()), q: { _ in 1e6 }, times: times, dt: 2.5e-4)
            for (time, answer) in zip(times, answers) {
                let exact = closedForm(m, q: 1e6, t: time)
                let error = (answer.surface - ambient) / exact - 1
                #expect(
                    abs(error) < 0.005,
                    "\(material.name) at \(time) s: \(answer.surface - ambient) K against \(exact)")
            }
        }
    }

    @Test("The error falls as the grid and the step are refined")
    func convergence() {
        let m = lossless(.concrete)
        let times = [0.002, 0.17]
        func surface(cells: Int, resolved: Float, dt: Double) -> [Double] {
            var spec = spec(cells: cells)
            spec.resolvedTime = resolved
            return run(column(m, spec: spec), q: { _ in 1e6 }, times: times, dt: dt).map(\.surface)
        }
        // The grid: twice the cells, the first half as thick, against the closed form.
        let exact = times.map { closedForm(m, q: 1e6, t: $0) }
        let grids: [(cells: Int, resolved: Float)] = [(16, 4e-4), (32, 1e-4), (64, 2.5e-5), (128, 6.25e-6)]
        let grid = grids.map { g -> Double in
            let answers = surface(cells: g.cells, resolved: g.resolved, dt: 1e-5)
            return zip(answers, exact).map { abs(($0 - ambient) / $1 - 1) }.max()!
        }
        // The step, on the default grid, against a step of a microsecond on it.
        let reference = surface(cells: 32, resolved: 2.5e-5, dt: 1e-6)
        let steps = [1e-3, 5e-4, 2.5e-4, 1.25e-4].map { dt in
            zip(surface(cells: 32, resolved: 2.5e-5, dt: dt), reference).map {
                abs(($0 - $1) / ($1 - ambient))
            }.max()!
        }
        print("Surface heating: grid errors", grid, "step errors", steps)
        #expect(grid[0] > grid[1] && grid[1] > grid[2] && grid[2] > grid[3] && grid[2] < 0.005)
        #expect(steps[0] > steps[1] && steps[1] > steps[2] && steps[2] > steps[3] && steps[2] < 0.002)
        // Second order in the step.
        #expect(steps[1] / steps[2] > 3 && steps[2] / steps[3] > 3)
    }

    /// A slab 0 < x < L heated by q at x = 0 and insulated at L (Carslaw and Jaeger §3.3):
    /// T − T₀ = qL/k [αt/L² + (3(L−x)² − L²)/(6L²) − (2/π²) Σ (−1)ⁿ/n² e^(−αn²π²t/L²) cos(nπ(L−x)/L)].
    private func slab(_ m: ThermalMaterial, length: Double, q: Double, t: Double, x: Double) -> Double {
        let alpha = m.diffusivity
        let k = Double(m.conductivity)
        var sum = 0.0
        for n in 1...200 {
            let n = Double(n)
            sum +=
                (Int(n) % 2 == 0 ? 1 : -1) / (n * n) * exp(-alpha * n * n * .pi * .pi * t / (length * length))
                * cos(n * .pi * (length - x) / length)
        }
        let y = length - x
        return q * length / k
            * (alpha * t / (length * length) + (3 * y * y - length * length) / (6 * length * length) - 2
                / (.pi * .pi) * sum)
    }

    @Test("A slab insulated behind follows its analytical series")
    func slabSeries() {
        for (material, length) in [(ThermalMaterial.steel, 0.005), (.glass, 0.002), (.canvas, 0.0005)] {
            let m = lossless(material)
            let c = column(m, thickness: Float(length), spec: spec())
            #expect(c.back != nil)
            let diffusion = length * length / m.diffusivity
            let times = [0.02, 0.1, 0.5, 2].map { $0 * diffusion }
            let answers = run(c, q: { _ in 1e5 }, times: times, dt: diffusion / 2000)
            for (time, answer) in zip(times, answers) {
                let front = slab(m, length: length, q: 1e5, t: time, x: 0)
                let back = slab(m, length: length, q: 1e5, t: time, x: length)
                #expect(
                    abs((answer.surface - ambient) / front - 1) < 0.005, "\(material.name) front at \(time)")
                // The back barely moves at first; compare it against the front's rise.
                #expect(abs(answer.back - ambient - back) < 0.005 * front, "\(material.name) back at \(time)")
            }
        }
    }

    @Test("Re-radiation limits a thin sheet to where it radiates what it absorbs")
    func reradiation() {
        // A millimetre of steel radiating from both faces: αq = 2εσ(T⁴ − T₀⁴).
        var m = ThermalMaterial.steel
        m.absorptivity = 1
        let c = column(m, thickness: 0.001, spec: spec())
        let q = 2e5
        let limit = pow(q / (2 * Double(m.emissivity) * Column.stefanBoltzmann) + pow(ambient, 4), 0.25)
        let answers = run(c, q: { _ in q }, times: [5, 60], dt: 0.01)
        #expect(answers[0].surface < limit)
        #expect(abs(answers[1].surface / limit - 1) < 0.002, "\(answers[1].surface) against \(limit)")
        // Unpainted softwood under 3 MW/m² rises toward, and stays below, αq = εσ(T⁴ − T₀⁴),
        // far below the rise it would have without losing heat.
        let wood = ThermalMaterial.softwood
        let deep = column(wood, spec: spec())
        let flux = 3e6
        let woodLimit = pow(
            Double(wood.absorptivity) * flux / (Double(wood.emissivity) * Column.stefanBoltzmann)
                + pow(ambient, 4), 0.25)
        let hot = run(deep, q: { _ in flux }, times: [0.01, 0.17, 2], dt: 2.5e-4, convection: 20)
        let lossless = closedForm(wood, q: Double(wood.absorptivity) * flux, t: 0.17)
        #expect(hot.allSatisfy { $0.surface < woodLimit })
        #expect(hot[0].surface < hot[1].surface && hot[1].surface < hot[2].surface)
        #expect(hot[1].surface - ambient < 0.7 * lossless, "\(hot[1].surface - ambient) against \(lossless)")
        #expect(hot[2].surface > 0.85 * woodLimit, "\(hot[2].surface) against \(woodLimit)")
    }

    @Test("Frames cut into steps no longer than the maximum agree with finer steps")
    func frameSteps() throws {
        let scene = scene(blocks: [Box(min: SIMD3(60, 40, 0), max: SIMD3(70, 60, 10))])
        var spec = ThermalSpec()
        spec.fireball = .sphere
        spec.samples = 32
        spec.groundSpacing = 10
        spec.surfaceSpacing = 5
        func peaks(_ step: Float) -> [Float] {
            var spec = spec
            spec.heating.maximumStep = step
            var exposure = ThermalExposure(spec: spec, scene: scene)
            for n in 0...40 {
                let t = Double(n) * 0.005
                let radius: Float = n == 0 ? 0 : 4 + Float(n) * 0.05
                exposure.add(
                    sphere(SIMD3(50, 50, 6), radius: radius, temperature: 2400 - Float(n) * 15, time: t))
            }
            return exposure.heating!.peakTemperature
        }
        let coarse = peaks(5e-3)
        let fine = peaks(1e-4)
        let worst = zip(coarse, fine).map { abs($0 - $1) / max($1 - 293.15, 1) }.max()!
        #expect(worst < 0.01, "\(worst)")
    }

    private func scene(blocks: [Box]) -> FragmentScene {
        var scenario = Scenario(
            name: "Heating", domainSize: SIMD3(100, 100, 50), boxes: blocks,
            charge: Charge(mass: 1, position: SIMD3(50, 50, 5)))
        scenario.gauges = []
        return FragmentScene(scenario)
    }

    private func sphere(_ centre: SIMD3<Float>, radius: Float, temperature: Float, time: Double)
        -> FireballFrame
    {
        FireballFrame(
            time: time, volume: 4 / 3 * Double.pi * pow(Double(radius), 3), centre: centre,
            temperature: radius > 0 ? temperature : 0, hottest: temperature)
    }

    @Test("Each surface takes its material, its override and its finish, and the result keeps them")
    func materials() throws {
        let block = Box(min: SIMD3(54.5, 45, 0), max: SIMD3(58, 55, 8))
        var spec = ThermalSpec()
        spec.fireball = .sphere
        spec.samples = 32
        spec.groundSpacing = 5
        spec.surfaceSpacing = 1
        spec.heating.overrides = [
            SurfaceOverride(surface: "block 0", material: "timber", finish: "black paint")
        ]
        var exposure = ThermalExposure(spec: spec, scene: scene(blocks: [block]))
        for n in 0...20 {
            exposure.add(sphere(SIMD3(50, 50, 5), radius: 4, temperature: 2600, time: Double(n) * 0.01))
        }
        let result = exposure.result
        let heating = try #require(result.heating)
        #expect(heating.materials.map(\.name).sorted() == ["asphalt", "timber, black paint"])
        #expect(heating.peakTemperature.count == result.receivers.count)
        for n in result.receivers.indices {
            if result.fluence[n] > 0 {
                #expect(heating.peakTemperature[n] > Float(ambient))
            } else {
                #expect(heating.peakTemperature[n] == Float(ambient))
            }
        }
        // The timber face toward the fireball, half a metre from its surface, passes the short pulse's
        // 9 cal/cm² and the ignition temperature; the asphalt is never flagged.
        let timber = heating.materials.firstIndex { $0.name.hasPrefix("timber") }!
        let facing = result.receivers.indices.filter {
            heating.material[$0] == timber && result.receivers[$0].normal.x < 0
        }
        #expect(facing.contains { heating.ignition[$0] == IgnitionFlags([.fluence, .temperature]).rawValue })
        #expect(
            heating.material.indices.allSatisfy {
                heating.material[$0] == timber || heating.ignition[$0] == 0
            })
        #expect(result.summary.contains { $0.contains("illustrative") })
        // Kept and read back; a result from before the heating reads without it.
        let decoded = try JSONDecoder().decode(ThermalResult.self, from: JSONEncoder().encode(result))
        #expect(decoded == result)
        var old = result
        old.heating = nil
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        var oldSpec = json["spec"] as! [String: Any]
        oldSpec["heating"] = nil
        json["spec"] = oldSpec
        let before = try JSONDecoder().decode(
            ThermalResult.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(before.heating == nil && before.spec.heating == SurfaceHeatingSpec())
    }

    @Test("The description turns it off, names unknown materials as invalid, and maps the structure's")
    func description() throws {
        let off = try JSONDecoder().decode(
            ThermalSpec.self, from: Data(#"{"heating": {"enabled": false}}"#.utf8))
        #expect(!off.heating.enabled)
        let exposure = ThermalExposure(spec: off, scene: scene(blocks: []))
        #expect(exposure.heating == nil && exposure.result.heating == nil)
        var bad = ThermalSpec()
        bad.heating.ground = "marzipan"
        #expect(throws: (any Error).self) { try bad.validate() }
        #expect(SurfaceMaterial.named(forStructure: "Reinforced concrete") == "concrete")
        #expect(SurfaceMaterial.named(forStructure: "Concrete block") == "concrete")
        #expect(SurfaceMaterial.named(forStructure: "Masonry") == "masonry")
        #expect(SurfaceMaterial.named(forStructure: "Structural steel") == "steel")
        #expect(SurfaceMaterial.named(forStructure: "Annealed glass") == "glass")
    }
}
