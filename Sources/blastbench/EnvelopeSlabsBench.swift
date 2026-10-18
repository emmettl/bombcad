import BlastCore
import Foundation
import Metal
import simd

// `blastbench envelope-slabs [--cases contest,reynolds,wu,wang,mendonca] [--out <dir>]`: envelope
// damage's SDOF panels and strips against the measured slabs of the validation record. The contest
// slab and Reynolds's slabs are driven by their measured loads (one-way strips on the blast load
// simulator's supports); Wu's, Wang's and Mendonça's by the model's own air load on the slab as a
// rigid envelope in its test's scene (the recommended air), recorded by the envelope recorder. Each
// is judged with its edges fixed and simply supported, built as tested.

/// A concrete of `strength` (Pa) with bars yielding at `yield` (Pa), elastic–perfectly plastic in
/// the SDOF systems (only the yield is read).
func slabMaterial(strength: Float, yield: Float, density: Float) -> StructureMaterial {
    StructureMaterial.concrete(
        name: "Slab", compressiveStrength: strength, density: density,
        steel: SteelProperties(
            yieldStress: yield, ultimateStress: yield, ultimateStrain: 0.05, ruptureStrain: 0.15))
}

/// Mean pressures per bin of `step` from a prescribed history, held at nothing past its end.
func binned(_ load: PressureLoad, step: Double) -> [Double] {
    let history = load.history
    guard let end = history.last?.x else { return [] }
    let count = Int((Double(end) / step).rounded(.up))
    func pressure(at t: Double) -> Double {
        let time = Float(t)
        guard let after = history.firstIndex(where: { $0.x >= time }) else { return 0 }
        if after == 0 { return Double(history[0].y) }
        let a = history[after - 1]
        let b = history[after]
        let w = b.x > a.x ? (time - a.x) / (b.x - a.x) : 1
        return Double(a.y + (b.y - a.y) * w)
    }
    return (0..<count).map { pressure(at: (Double($0) + 0.5) * step) }
}

struct SlabCase {
    var id: String
    var measured: String
    var detailed: String
    /// The systems to judge it by, named.
    var systems: [(String, SDOFSystem)]
    var span: Double
    var pressures: [Double]
    var step: Double
    var load: String
    /// The model's air load as the whole component's mean, beside `pressures`, its equivalent
    /// uniform load weighted by its deflected shape.
    var whole: [Double]? = nil
}

func runEnvelopeSlabs(device: MTLDevice) throws {
    let names = Set(
        (option("cases") ?? "contest,reynolds,wu,wang,mendonca").split(separator: ",").map(String.init))
    var cases: [SlabCase] = []
    func strips(
        thickness: Double, depth: Double, steel: Double, material: StructureMaterial, span: Double
    ) -> [(String, SDOFSystem)] {
        [EnvelopePanel.Edges.simplySupported, .fixed].map { edges in
            (
                "strip, \(edges == .fixed ? "fixed" : "simply supported")",
                EnvelopePanel.reinforcedOneWay(
                    thickness: thickness, depth: depth, steelArea: steel, material: material, span: span,
                    edges: edges)
            )
        }
    }
    let step = 1e-4
    // The 2013 contest slab in the blast load simulator, on its measured load and its lower shot.
    if names.contains("contest") {
        let material = slabMaterial(strength: 5400 * 6894.76, yield: 72_000 * 6894.76, density: 2400)
        let systems = strips(
            thickness: 0.1016, depth: 0.0762, steel: 745e-6, material: material, span: 1.3208)
        let full = binned(SlabBenchmark.load, step: step)
        cases.append(
            SlabCase(
                id: "contest", measured: "109 mm (the repeat 113)", detailed: "113 mm on 8 elements (1.05)",
                systems: systems, span: 1.3208, pressures: full, step: step, load: "measured"))
        cases.append(
            SlabCase(
                id: "contest, lower shot", measured: "about 72 mm (Table 15: 80.5)",
                detailed: "59 mm on 8 elements",
                systems: systems, span: 1.3208, pressures: full.map { $0 * 0.764 }, step: step,
                load: "measured × 0.764"))
    }
    // Reynolds's high-strength slabs in the same rig, on their digitised loads (revealed; calibration data).
    if names.contains("reynolds") {
        let inputs = try ReynoldsSlabTest.inputs(
            from: URL(filePath: "Samples/Reynolds2015/inputs/slabs.json"))
        let measured: [String: String] = [
            "HSCV1": "98.8 mm", "HSCV2": "114.3 mm", "HSCV3": "62.7 mm", "HSCV4": "181.9 mm",
            "HSCV5": "86.4 mm", "HSCV6": "85.9 mm",
        ]
        let detailed: [String: String] = [
            "HSCV1": "94.2 mm (0.95)", "HSCV2": "94.2 mm (0.82)", "HSCV3": "52.4 mm (0.84)",
            "HSCV4": "broken through blind; 161 mm (0.89) at 15% rupture", "HSCV5": "66.3 mm (0.77)",
            "HSCV6": "91.2 mm (1.06)",
        ]
        let material = slabMaterial(strength: 108.6e6, yield: 572.3e6, density: 2454)
        for slab in inputs.slabs where slab.name.hasPrefix("HSCV") {
            let steel = slab.barSpacingInches < 6 ? 745e-6 : 414e-6
            cases.append(
                SlabCase(
                    id: slab.name, measured: measured[slab.name] ?? "-", detailed: detailed[slab.name] ?? "-",
                    systems: strips(
                        thickness: 0.1016, depth: 0.0746, steel: steel, material: material, span: 1.3208),
                    span: 1.3208,
                    pressures: binned(
                        ReynoldsSlabTest.load(slab, settings: ReynoldsSlabTest.Settings()), step: step),
                    step: step, load: "measured"))
        }
    }
    /// The model's own load on the slab: its scene with the slab an envelope, the recorder on,
    /// the net pressure on its largest component turned to push from the struck face.
    func airLoad(_ scenario: Scenario, cellSize: Float, duration: Double) throws -> (
        pressures: [Double], step: Double, whole: [Double]
    ) {
        // Each case's solver freed before the next (its Metal buffers held by the pool otherwise).
        try autoreleasepool { try airLoadInPool(scenario, cellSize: cellSize, duration: duration) }
    }
    func airLoadInPool(_ scenario: Scenario, cellSize: Float, duration: Double) throws -> (
        pressures: [Double], step: Double, whole: [Double]
    ) {
        var scene = scenario
        for object in scenario.structuralObjects { try scene.useEnvelope(id: object.id) }
        // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
        var configuration = SolverConfiguration.recommended.balloonStart
        configuration.airSleepThreshold = 0
        configuration.airSleepCrossings = 0
        let solver = try BlastSolver(
            device: device, scenario: scene, cellSize: cellSize, configuration: configuration)
        try solver.configureEnvelopeComponents(
            objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: duration))
        while solver.time < duration {
            if solver.advance(steps: 16, timeLimit: duration).steps == 0 { break }
        }
        let histories = solver.envelopeComponentHistories() ?? []
        func area(_ history: EnvelopeComponentHistory) -> Double {
            EnvelopeComponentLoad(history).spans.short * EnvelopeComponentLoad(history).spans.long
        }
        guard let slab = histories.max(by: { area($0) < area($1) }) else {
            throw BlastError.allocationFailed("no envelope component")
        }
        let plate = EnvelopeComponentLoad(slab)
        let whole = EnvelopeComponentLoad(slab, whole: true)
        return (
            EnvelopeDamageAssessment.cantileverLoad(plate.netPa), plate.binS,
            EnvelopeDamageAssessment.cantileverLoad(whole.netPa)
        )
    }
    // Wu's slabs with steel in one face (S) or both (D), on two opposite edges, the charge above.
    if names.contains("wu") {
        let material = slabMaterial(strength: 0.8 * 47e6, yield: 455e6, density: 2400)
        let detailed: [String: String] = [
            "S5": "2.1 mm", "D5": "2.8 mm", "S6": "3.9 mm", "D6": "3.9 mm", "S7": "7.4 mm", "D7": "7.5 mm",
            "S8": "16.3 mm (0.91)", "D8": "16.4 mm (1.18)",
        ]
        for test in TwoFaceSlabTests.wuTests where test.standoff != nil {
            let air = try airLoad(TwoFaceSlabTests.scenario(test), cellSize: 0.0125, duration: 0.02)
            let steel = test.name.hasPrefix("S") ? 503e-6 : 251e-6
            cases.append(
                SlabCase(
                    id: "Wu \(test.name)",
                    measured: test.peak.map { String(format: "%.1f mm", $0 * 1000) } ?? "-",
                    detailed: detailed[test.name] ?? "-",
                    systems: strips(thickness: 0.1, depth: 0.08, steel: steel, material: material, span: 1.9),
                    span: 1.9, pressures: air.pressures, step: air.step, load: "model's air", whole: air.whole
                ))
        }
    }
    // Wang's slabs, clamped all round: two-way panels over their clear 0.4 × 1.1 m.
    if names.contains("wang") {
        let material = slabMaterial(strength: 30e6, yield: 400e6, density: 2300)
        let detailed = ["A": "3.1 mm fixed, 6.3 sliding", "B": "2.8 mm fixed, 5.7 sliding"]
        for test in TwoFaceSlabTests.wangTests {
            let air = try airLoad(TwoFaceSlabTests.scenario(test), cellSize: 0.025, duration: 0.02)
            let steel = Double(Float.pi * test.bar * test.bar / 4 / 0.1)
            let systems = [EnvelopePanel.Edges.fixed, .simplySupported].map { edges in
                (
                    "panel, \(edges == .fixed ? "fixed" : "simply supported")",
                    EnvelopePanel.reinforcedConcrete(
                        thickness: 0.1, depth: 0.08, steelArea: steel, material: material, a: 0.4, b: 1.1,
                        edges: edges)
                )
            }
            let centre = test.peaks.count / 2
            cases.append(
                SlabCase(
                    id: "Wang \(test.name)", measured: String(format: "%.1f mm", test.peaks[centre] * 1000),
                    detailed: detailed[test.name] ?? "-", systems: systems, span: 0.4,
                    pressures: air.pressures,
                    step: air.step, load: "model's air", whole: air.whole))
        }
    }
    // Mendonça's slabs on trestles, the charge above (revealed; calibration data).
    if names.contains("mendonca") {
        let inputs = try MendoncaSlabTest.inputs(
            from: URL(filePath: "Samples/Mendonca2020/inputs/slabs.json"))
        let settings = MendoncaSlabTest.Settings()
        let measured: [String: String] = [
            "1": "collapsed", "10": "collapsed", "2": "38.2 mm", "5": "23.5 mm", "4": "20.4 mm",
            "7": "25.8 mm",
            "9": "24.0 mm",
        ]
        for slab in inputs.slabs {
            let air = try airLoad(
                MendoncaSlabTest.scenario(slab, inputs: inputs, settings: settings), cellSize: 0.0125,
                duration: 0.03)
            let steel: Double
            switch slab.layout {
            case .a: steel = 137e-6 + 157e-6
            case .b: steel = 196e-6
            case .c: steel = 137e-6
            }
            let material = slabMaterial(
                strength: slab.compressiveStrength, yield: 350e6, density: slab.density)
            let number = slab.name.filter(\.isNumber)
            cases.append(
                SlabCase(
                    id: "Mendonça \(slab.name)", measured: measured[number] ?? "-",
                    detailed: "first peak about 4 mm (slab 1 10 mm), standing",
                    systems: strips(
                        thickness: 0.08, depth: 0.055, steel: steel, material: material, span: 0.9),
                    span: 0.9, pressures: air.pressures, step: air.step, load: "model's air", whole: air.whole
                ))
        }
    }
    for slabCase in cases {
        let peak = slabCase.pressures.max() ?? 0
        let impulse = slabCase.pressures.reduce(0) { $0 + max($1, 0) } * slabCase.step
        print(
            String(
                format: "%@ (%@ load: peak %.0f kPa, impulse %.0f Pa s)", slabCase.id, slabCase.load,
                peak / 1000,
                impulse))
        for (name, system) in slabCase.systems {
            let response = system.response(pressures: slabCase.pressures, step: slabCase.step)
            let rotation = response.supportRotationDegrees(span: slabCase.span)
            let level = EnvelopeDamageLevel.concrete(ductility: response.ductility, rotationDeg: rotation)
                .label
            print(
                String(
                    format: "  %@: %.1f mm, %.2f°, ductility %.1f, %@ (r_u %.0f kPa, T %.1f ms)", name,
                    response.peakDeflection * 1000, rotation, response.ductility, level,
                    system.ultimateResistance / 1000, system.period * 1000))
            if let whole = slabCase.whole {
                let mean = system.response(pressures: whole, step: slabCase.step)
                let turned = mean.supportRotationDegrees(span: slabCase.span)
                print(
                    String(
                        format: "    on the whole component: %.1f mm, %.2f°, %@ (impulse %.0f Pa s)",
                        mean.peakDeflection * 1000, turned,
                        EnvelopeDamageLevel.concrete(ductility: mean.ductility, rotationDeg: turned).label,
                        whole.reduce(0) { $0 + max($1, 0) } * slabCase.step))
            }
        }
        print("  measured: \(slabCase.measured); the detailed model: \(slabCase.detailed)")
    }
}
