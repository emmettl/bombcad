import BlastModel
import Foundation
import Metal
import simd

extension AdblastCladdingTest {
    public static func run(_ test: Test, settings: Settings = Settings(), device: MTLDevice) throws -> Result
    {
        let model = model(thicknessMM: test.thicknessMM, settings: settings)
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        solver.damping = 0
        let peak = test.reflectedPeakKPa! * 1000
        let duration = 2 * test.reflectedImpulseKPaMS! / test.reflectedPeakKPa! / 1000
        solver.appliedLoad = PressureLoad(
            axis: 2, positiveSide: true,
            history: [SIMD2(0, peak), SIMD2(duration, 0), SIMD2(duration + 10, 0)])
        let gauge = solver.nearestNode(to: SIMD3(1.23, 1.63, 1))
        let step = solver.criticalTimeStep
        let stepsPerSample = max(1, Int((0.0002 / step).rounded()))
        var history: [SIMD2<Float>] = []
        var time: Float = 0
        while time < settings.duration {
            solver.advance(steps: stepsPerSample)
            time += Float(stepsPerSample) * step
            history.append(SIMD2(time, solver.node(gauge).displacement.z))
        }
        // The first peak: the lowest point before the sheet first comes back up past half of it.
        var first: Float = 0
        for sample in history {
            if sample.y < first { first = sample.y } else if first < 0 && sample.y > 0.5 * first { break }
        }
        let tail = history.filter { $0.x > settings.duration - 0.05 }.map(\.y)
        let edge = solver.nearestNode(to: SIMD3(0, 1.63, 1))
        return Result(
            test: test, firstPeak: first, final: tail.reduce(0, +) / Float(max(tail.count, 1)),
            history: history,
            released: solver.node(edge).displacement.z > 0.05 || abs(solver.node(edge).displacement.x) > 0.05)
    }

    /// The test as shot: the charge, `tntEquivalence` times its C4 by weight (1.13, the heats of
    /// detonation's ratio, UFC 3-340-02 Table 2-1), 3.5 m above the sheets' middle, the sheets 1 m
    /// above rigid ground on two rigid supports under the tubes (the rig's height is not given), in
    /// air of `cellSize`.
    public static func runInAir(
        _ test: Test, settings: Settings = Settings(), cellSize: Float = 0.05, tntEquivalence: Float = 1.13,
        device: MTLDevice
    ) throws -> AirResult {
        let offset = SIMD3<Float>(3, 3, 0)
        let model = model(thicknessMM: test.thicknessMM, settings: settings, offset: offset)
        let middle = offset + SIMD3<Float>(1.23, 1.6315, 1)
        let supports = [Float(0), 2.46].map { x in
            Box(min: offset + SIMD3(x - 0.1, -0.2, 0), max: offset + SIMD3(x + 0.1, 3.463, 0.95))
        }
        let scenario = Scenario(
            name: "ADBLAST test \(test.test)", domainSize: SIMD3(8.5, 9.3, 5.5), boxes: supports,
            charge: Charge(mass: test.chargeKgC4 * tntEquivalence, position: middle + SIMD3(0, 0, 3.5)),
            gauges: [Gauge("Middle", at: middle + SIMD3(0, 0, 0.065))], structure: model)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        guard let shells = solver.shells else { throw BlastError.allocationFailed("the sheets in the air") }
        let gauge = shells.nearestNode(to: middle)
        var history: [SIMD2<Float>] = []
        var time: Double = 0
        while time < Double(settings.duration) {
            time += 0.0005
            _ = solver.advance(until: time)
            history.append(SIMD2(Float(time), shells.node(gauge).displacement.z))
        }
        var first: Float = 0
        for sample in history {
            if sample.y < first { first = sample.y } else if first < 0 && sample.y > 0.5 * first { break }
        }
        let tail = history.filter { $0.x > settings.duration - 0.05 }.map(\.y)
        let samples = solver.gaugeHistories.first ?? []
        let ambient = samples.first?.pressure ?? 101_325
        var impulse: Float = 0
        for (a, b) in zip(samples, samples.dropFirst()) {
            impulse += 0.5 * max(0, a.pressure - ambient + b.pressure - ambient) * Float(b.time - a.time)
        }
        let edge = shells.nearestNode(to: offset + SIMD3(0, 1.63, 1))
        return AirResult(
            structure: Result(
                test: test, firstPeak: first, final: tail.reduce(0, +) / Float(max(tail.count, 1)),
                history: history,
                released: shells.node(edge).displacement.z > 0.05
                    || abs(shells.node(edge).displacement.x) > 0.05),
            reflectedPeak: (samples.map(\.pressure).max() ?? ambient) - ambient, reflectedImpulse: impulse)
    }

    /// The one-way model under the load the air puts on the same panel as a rigid envelope, 1 m
    /// above ground on two rigid supports, the charge as `runInAir`'s: `whole` under the
    /// component's mean net pressure, `plate` under its faces weighted by its deflected shape, and
    /// `strip` under the middle third across its span weighted along it, as envelope damage takes
    /// a sheeted roof. The load depends only
    /// on the charge, so `history` serves every test of it (`envelope(_:history:)`).
    public static func envelopeInAir(
        _ test: Test, cellSize: Float = 0.05, tntEquivalence: Float = 1.13, device: MTLDevice
    ) throws -> (
        whole: EnvelopeResult, plate: EnvelopeResult, strip: EnvelopeResult, history: EnvelopeComponentHistory
    ) {
        let offset = SIMD3<Float>(3, 3, 0)
        let middle = offset + SIMD3<Float>(1.23, 1.6315, 1)
        let panel = Box(min: offset + SIMD3(0, 0, 0.958), max: offset + SIMD3(2.46, 3.263, 1.042))
        let supports = [Float(0), 2.46].map { x in
            Box(min: offset + SIMD3(x - 0.1, -0.2, 0), max: offset + SIMD3(x + 0.1, 3.463, 0.95))
        }
        var scenario = Scenario(
            name: "ADBLAST test \(test.test) as an envelope", domainSize: SIMD3(8.5, 9.3, 5.5),
            boxes: supports,
            charge: Charge(mass: test.chargeKgC4 * tntEquivalence, position: middle + SIMD3(0, 0, 3.5)))
        let owner = try scenario.addEnvelopeObject(try BuildingEnvelope(solids: [panel]), name: "Cladding")
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        try solver.configureEnvelopeComponents(
            objects: scenario.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.03))
        _ = solver.advance(until: 0.03)
        guard
            let history = solver.envelopeComponentHistories()?.first(where: {
                $0.component.owner == owner && $0.component.kind == .roof
            })
        else { throw BlastError.allocationFailed("the cladding's roof component") }
        let (whole, plate, strip) = envelope(test, history: history)
        return (whole, plate, strip, history)
    }

    /// `envelopeInAir`'s two results from its recorded history.
    public static func envelope(_ test: Test, history: EnvelopeComponentHistory)
        -> (whole: EnvelopeResult, plate: EnvelopeResult, strip: EnvelopeResult)
    {
        func run(_ load: EnvelopeComponentLoad) -> EnvelopeResult {
            envelope(
                test, pressures: load.netPa + Array(repeating: 0, count: Int(0.07 / load.binS)),
                step: load.binS)
        }
        let load = EnvelopeComponentLoad(history)
        return (run(EnvelopeComponentLoad(history, whole: true)), run(load), run(load.strip))
    }
}
