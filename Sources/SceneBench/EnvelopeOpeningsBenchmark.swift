import BlastCore
import Foundation
import Metal
import simd

/// `SceneBench envelope-openings [--dx 0.25] [--out file.json]`: the air that enters an envelope
/// building through an open window, against UFC 3-340-02 §2-15.4's interior loads
/// (`UFCInteriorLoads`), with the one-way fill and the UFC's §2-15.5 leakage fill on the same
/// opening. The UFC's own case: a shock striking the front wall head-on, the openings in the front
/// alone, a rigid box (4.5 m wide, 3 m tall, 3 or 6 m deep inside, so W/H = 3/2 and L/H = 1 or 2)
/// with 0.14 or 0.23 of its front open, under hemispherical TNT 28 m away whose incident pressure
/// at the front is 2, 4, 8 or 16 psi. Each charge is also run with no building, for the incident
/// pressure there.
enum EnvelopeOpeningsBenchmark {
    struct Case: Codable {
        var depthM: Float
        var openingWidthM: Float
        var openingRatio: Double
        var chargeKg: Double
        var targetPsi: Double
        /// The incident wave at the front wall's middle with no building: peak (psi) and Kingery-Bulmash's.
        var incidentPsi: Double
        var kingeryBulmashPsi: Double
        /// Figure 2-15's positive wave length there, m.
        var wavelengthM: Double
        /// Peak area-mean overpressure on the inside of each wall (psi): the air's and the UFC's.
        var backPsi: Double
        var ufcBackPsi: Double
        var sidePsi: Double
        var ufcSidePsi: Double
        var frontPsi: Double
        var ufcFrontPsi: Double
        /// The room's mean (18 gauges): peak (psi) and positive impulse (psi ms).
        var roomPsi: Double
        var roomImpulsePsiMs: Double
        /// The one-way fill and the UFC's leakage fill through the opening on its outer pressure.
        var fillPsi: Double
        var fillImpulsePsiMs: Double
        var leakagePsi: Double
        var leakageImpulsePsiMs: Double
        var wallClockS: Double
    }

    static let psi = 6_894.757
    static let width: Float = 4.5
    static let height: Float = 3
    static let thickness: Float = 0.25
    static let front: Float = 34
    static let middle: Float = 14
    static let chargePosition = SIMD3<Float>(6, 14, 1)
    static let domain = SIMD3<Float>(48, 28, 10)

    /// The building: front, back, sides and roof, the front holding one window 1.25 m tall.
    static func building(depth: Float, openingWidth: Float) throws -> BuildingEnvelope {
        let (x, y, t, w, h) = (front, middle - width / 2, thickness, width, height)
        let back = x + t + depth
        let solids = [
            Box(min: SIMD3(x, y - t, 0), max: SIMD3(x + t, y + w + t, h)),
            Box(min: SIMD3(back, y - t, 0), max: SIMD3(back + t, y + w + t, h)),
            Box(min: SIMD3(x + t, y - t, 0), max: SIMD3(back, y, h)),
            Box(min: SIMD3(x + t, y + w, 0), max: SIMD3(back, y + w + t, h)),
            Box(min: SIMD3(x, y - t, h), max: SIMD3(back + t, y + w + t, h + t)),
        ]
        let window = Box(
            min: SIMD3(x, middle - openingWidth / 2, 0.75), max: SIMD3(x + t, middle + openingWidth / 2, 2))
        return try BuildingEnvelope(solids: solids, openings: [window], panes: [])
    }

    /// The charge whose Kingery-Bulmash incident pressure at `range` is `pressure` Pa.
    static func charge(pressure: Double, range: Double) -> Double {
        var (low, high) = (0.5, 40.0)
        for _ in 0..<60 {
            let z = (low + high) / 2
            if (KingeryBulmash.point(at: z)?.incidentPressure ?? 0) > pressure { low = z } else { high = z }
        }
        return pow(range / ((low + high) / 2), 3)
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }

    static func run(_ args: [String]) throws {
        func value(_ name: String) -> String? {
            args.firstIndex(of: "--\(name)").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        let dx = value("dx").flatMap(Float.init) ?? 0.25
        guard let device = MTLCreateSystemDefaultDevice() else { throw BlastError.allocationFailed("Metal") }
        var config = SolverConfiguration.recommended
        config.airSleepThreshold = 0
        config.airSleepCrossings = 0
        let wallMiddle = SIMD3<Float>(front, middle, 1.5)
        let range = Double(simd_distance(SIMD2(chargePosition.x, chargePosition.y), SIMD2(front, middle)))
        var cases: [Case] = []
        for target in [2.0, 4, 8, 16] {
            let mass = charge(pressure: target * psi, range: range)
            let z = range / cbrt(mass)
            let arrival = (KingeryBulmash.point(at: z)?.arrival(mass: mass) ?? 0.05)
            let duration = arrival + 0.08
            // The incident wave at the front wall's middle, with no building.
            let open = Scenario(
                name: "Open \(target) psi", domainSize: domain, boxes: [],
                charge: Charge(mass: Float(mass), position: chargePosition),
                gauges: [Gauge("Front", at: wallMiddle)])
            let free = try BlastSolver(device: device, scenario: open, cellSize: dx, configuration: config)
            _ = free.advance(until: arrival + 0.03)
            let incident =
                Double((free.gaugeHistories[0].map(\.pressure).max() ?? 0)) - Double(config.ambientPressure)
            for depth: Float in [3, 6] {
                for openingWidth: Float in [1.5, 2.5] {
                    let envelope = try building(depth: depth, openingWidth: openingWidth)
                    var scene = Scenario(
                        name: "Openings", domainSize: domain, boxes: [],
                        charge: Charge(mass: Float(mass), position: chargePosition))
                    let inside = (front + thickness, middle - width / 2)
                    for fx in [1.0 / 6, 0.5, 5.0 / 6] {
                        for fy in [1.0 / 6, 0.5, 5.0 / 6] {
                            for gz: Float in [0.75, 2.25] {
                                scene.gauges.append(
                                    Gauge(
                                        "Room",
                                        at: SIMD3(
                                            inside.0 + depth * Float(fx), inside.1 + width * Float(fy), gz)
                                    ))
                            }
                        }
                    }
                    try scene.addEnvelopeObject(envelope, name: "Building")
                    let start = ContinuousClock.now
                    let solver = try BlastSolver(
                        device: device, scenario: scene, cellSize: dx, configuration: config)
                    try solver.configureEnvelopeComponents(
                        objects: scene.envelopeObjects,
                        options: EnvelopeHistoryOptions(windowS: duration, openingsAsPanes: true))
                    _ = solver.advance(until: duration)
                    let took = seconds(start.duration(to: .now))
                    let histories = solver.envelopeComponentHistories() ?? []
                    func inner(_ source: Int) -> Double {
                        Double(
                            histories.first { $0.component.kind != .pane && $0.component.source == source }?
                                .peakInnerPa ?? 0)
                            / psi
                    }
                    // The room's mean: the gauges' samples are taken together.
                    let samples = solver.gaugeHistories
                    let count = samples.map(\.count).min() ?? 0
                    let ambient = Double(config.ambientPressure)
                    let mean = (0..<count).map { i in
                        (
                            samples.map { Double($0[i].pressure) }.reduce(0, +) / Double(samples.count)
                                - ambient,
                            samples[0][i].time
                        )
                    }
                    let roomPeak = mean.map(\.0).max() ?? 0
                    let roomImpulse = zip(mean, mean.dropFirst()).reduce(0.0) {
                        $0 + max(0.5 * ($1.0.0 + $1.1.0), 0) * ($1.1.1 - $1.0.1)
                    }
                    // The fills on the opening's outer pressure.
                    let opening = histories.first { $0.component.kind == .pane }
                    let area = Double(openingWidth * 1.25)
                    let outer = (opening?.outerImpulsePaS ?? []).map { Double($0) / (opening?.binS ?? 1) }
                    let volume = Double(width * height * depth)
                    let openings = [(area: area, opens: 0.0, outer: outer)]
                    let bin = opening?.binS ?? 1e-4
                    let fill = EnvelopeDamageAssessment.fill(volume: volume, openings: openings, bin: bin)
                    let leakage = EnvelopeDamageAssessment.leakageFill(
                        volume: volume, openings: openings, bin: bin)
                    let ratio = area / Double(width * height)
                    let wavelength = UFCInteriorLoads.wavelength(mass: mass, range: range)
                    let pso = incident / psi
                    let lengthToHeight = Double(depth / height)
                    let row = Case(
                        depthM: depth, openingWidthM: openingWidth, openingRatio: ratio, chargeKg: mass,
                        targetPsi: target, incidentPsi: pso,
                        kingeryBulmashPsi: (KingeryBulmash.point(at: z)?.incidentPressure ?? 0) / psi,
                        wavelengthM: wavelength, backPsi: inner(1),
                        ufcBackPsi: pso
                            * UFCInteriorLoads.backWallRatio(
                                pressurePsi: pso, openingRatio: ratio, lengthToHeight: lengthToHeight),
                        sidePsi: (inner(2) + inner(3)) / 2,
                        ufcSidePsi: UFCInteriorLoads.sideWallPsi(
                            pressurePsi: pso, openingRatio: ratio,
                            wavelengthToLength: wavelength / Double(depth),
                            widthToHeight: Double(width / height), lengthToHeight: lengthToHeight),
                        frontPsi: inner(0),
                        ufcFrontPsi: UFCInteriorLoads.frontWallPsi(
                            pressurePsi: pso, openingRatio: ratio,
                            wavelengthToHeight: wavelength / Double(height)),
                        roomPsi: roomPeak / psi, roomImpulsePsiMs: roomImpulse / psi * 1000,
                        fillPsi: fill.peak / psi, fillImpulsePsiMs: fill.impulse / psi * 1000,
                        leakagePsi: leakage.peak / psi, leakageImpulsePsiMs: leakage.impulse / psi * 1000,
                        wallClockS: took)
                    cases.append(row)
                    print(
                        String(
                            format:
                                "L %.0f m, Ao/Aw %.3f, %.0f kg: Pso %.2f psi (KB %.2f), Lw %.1f m | back %.2f (UFC %.2f) side %.2f (UFC %.2f) front %.2f (UFC %.2f) | room %.2f psi %.1f psi ms | fill %.2f psi %.1f psi ms, leakage %.2f psi %.1f psi ms | %.0f s",
                            depth, ratio, mass, pso, row.kingeryBulmashPsi, wavelength, row.backPsi,
                            row.ufcBackPsi,
                            row.sidePsi, row.ufcSidePsi, row.frontPsi, row.ufcFrontPsi, row.roomPsi,
                            row.roomImpulsePsiMs, row.fillPsi, row.fillImpulsePsiMs, row.leakagePsi,
                            row.leakageImpulsePsiMs, took))
                }
            }
        }
        if let out = value("out") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(cases).write(to: URL(fileURLWithPath: out))
        }
    }
}
