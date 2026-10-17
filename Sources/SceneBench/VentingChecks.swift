import BlastCore
import Foundation
import Metal

/// `SceneBench venting-checks [--case office|street] [--dx 0.25] [--duration 0.12]`: envelope damage as
/// the app judges it, with the glazing vented (the default) and with the one-way fill, on the
/// office tower preset's two glazed neighbours (beside the detailed tower) and on the damage
/// references' glazed street, uniform and with the shocks sharpened (refined once by 2). Each
/// building's panes broken, the first, its inside, and the run's wall time.
enum VentingChecks {
    static func run(_ args: [String]) throws {
        func value(_ name: String) -> String? {
            args.firstIndex(of: "--\(name)").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        let which = value("case") ?? "street"
        let dx = value("dx").flatMap(Float.init) ?? 0.25
        guard let device = MTLCreateSystemDefaultDevice() else { throw BlastError.allocationFailed("Metal") }
        var scene: Scenario
        var duration: Double
        var runs: [(name: String, vented: Bool, refined: Bool)]
        switch which {
        case "office":
            scene = ScenarioPreset.officeTower.scenario
            duration = value("duration").flatMap(Double.init) ?? 0.12
            runs = [("fill", false, false), ("vented", true, false)]
        case "cased", "references-fragments":
            try casedChecks(which: which, dx: dx, device: device)
            return
        default:
            scene = try EnvelopeDamageBenchmark.scene(layout: .street, wall: .glass, charge: 50)
            for object in scene.structuralObjects { try scene.useEnvelope(id: object.id) }
            duration = value("duration").flatMap(Double.init) ?? 0.12
            runs = [
                ("fill", false, false), ("vented", true, false), ("fill, refined", false, true),
                ("vented, refined", true, true),
            ]
        }
        for (name, vented, refined) in runs {
            var config = SolverConfiguration.recommended
            if refined {
                config.refinement = 2
                config.refinementLevels = 1
            }
            let start = ContinuousClock.now
            let solver = try BlastSolver(device: device, scenario: scene, cellSize: dx, configuration: config)
            solver.settleStructures()
            try solver.configureEnvelopeExposure(objects: scene.envelopeObjects)
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: duration))
            if vented {
                try solver.configureEnvelopeVenting(objects: scene.envelopeObjects) {
                    scene.envelopeConstruction(for: $0)
                }
            }
            while duration - solver.time > 1e-7 {
                if solver.advance(steps: 64, timeLimit: duration).steps == 0 { break }
            }
            let took = start.duration(to: .now)
            let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
            let snapshot = solver.envelopeVentingSnapshot()
            let histories = solver.envelopeComponentHistories() ?? []
            let loads = histories.filter { !$0.invalid || snapshot?.keeps($0) == true }
                .map(EnvelopeComponentLoad.init)
            let rooms = Dictionary(
                uniqueKeysWithValues: scene.envelopeObjects.map {
                    ($0.id, EnvelopeDamageAssessment.roomVolume(of: $0.envelope!))
                })
            let damage = EnvelopeDamageAssessment.assess(
                loads: loads, constructions: { scene.envelopeConstruction(for: $0) }, rooms: rooms,
                vented: snapshot)
            print(String(format: "%@ (%.0f s, %d steps):", name, seconds, solver.stepCount))
            for building in damage {
                let label = scene.object(id: building.id)?.name ?? "Building"
                print(
                    String(
                        format:
                            "  %@: %d of %d panes broken, first at %.1f ms; inside %.2f kPa, %.0f Pa s%@; walls %@",
                        label, building.panesBroken, building.panes,
                        (building.firstPaneBrokenAtS ?? .nan) * 1000,
                        building.insidePeakPa / 1000, building.insideImpulsePaS,
                        building.vented == true ? " (the air's)" : " (fill)",
                        building.structuralLevels.upperBound.label))
            }
        }
    }

    /// Holes through envelope walls: a cased charge before a concrete envelope ("cased": 20 kg in a
    /// 20 kg steel case 4 m off a 0.2 m concrete box, no glazing), and the damage references'
    /// isolated buildings, concrete and glazed, at 50 and 200 kg cased one to one
    /// ("references-fragments"); each with the fragments' holes and UFC 3-340-02's breaches, and
    /// without fragments.
    static func casedChecks(which: String, dx: Float, device: MTLDevice) throws {
        var cases: [(name: String, scene: Scenario, spec: FragmentSpec?, duration: Double)] = []
        func cased(_ charge: Float) -> FragmentSpec {
            var spec = FragmentSpec()
            spec.casingMass = charge
            spec.count = 20_000
            spec.tracers = 0
            return spec
        }
        if which == "cased" {
            var scene = Scenario(
                name: "Cased charge before concrete", domainSize: SIMD3(24, 20, 8), boxes: [],
                charge: Charge(mass: 20, position: SIMD3(6, 10, 1)))
            let model = EnvelopeDamageBenchmark.building(x: 10, y: 7, wall: .rc)
            try scene.addEnvelopeObject(BuildingEnvelope(structure: model), name: "Concrete box")
            var near = scene
            near.charge.position = SIMD3(9, 10, 1)
            cases = [
                ("bare, 4 m", scene, nil, 0.06), ("cased, 4 m", scene, cased(20), 0.06),
                ("bare, 1 m", near, nil, 0.06), ("cased, 1 m", near, cased(20), 0.06),
            ]
        } else {
            for wall in [EnvelopeDamageBenchmark.Wall.rc, .glass] {
                for charge: Float in [50, 200] {
                    var scene = try EnvelopeDamageBenchmark.scene(
                        layout: .isolated, wall: wall, charge: charge)
                    for object in scene.structuralObjects { try scene.useEnvelope(id: object.id) }
                    cases.append(("\(wall.rawValue) \(Int(charge)) kg bare", scene, nil, 0.1))
                    cases.append(("\(wall.rawValue) \(Int(charge)) kg cased", scene, cased(charge), 0.1))
                }
            }
        }
        for (name, scene, spec, duration) in cases {
            let start = ContinuousClock.now
            let solver = try BlastSolver(
                device: device, scenario: scene, cellSize: dx, configuration: .recommended)
            try solver.configureEnvelopeExposure(objects: scene.envelopeObjects)
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: duration))
            try solver.configureEnvelopeVenting(objects: scene.envelopeObjects) {
                scene.envelopeConstruction(for: $0)
            }
            var perforations = 0
            var areaLine = ""
            if let spec {
                let holes = FragmentCloud.envelopeHoles(
                    spec: spec, scene: FragmentScene(scene), density: scene.atmosphere.density,
                    pressure: scene.atmosphere.pressure, until: duration)
                var panes: [String: Double] = [:]
                for hole in holes {
                    guard let pane = hole.pane else { continue }
                    let id = "\(hole.owner.uuidString)/pane/\(pane).0"
                    panes[id] = min(panes[id] ?? .infinity, hole.time)
                }
                solver.setEnvelopePaneHoles(panes)
                try solver.setEnvelopeWallHoles(holes)
                perforations = holes.filter { $0.pane == nil }.count
                let areas = holes.filter { $0.pane == nil }.map(\.areaM2)
                areaLine = String(
                    format: "  perforations' area: total %.4f m², largest %.5f m², median %.5f m²",
                    areas.reduce(0, +), areas.max() ?? 0, areas.sorted().dropFirst(areas.count / 2).first ?? 0
                )
            }
            let outcomes = try solver.setEnvelopeCloseIn(
                charges: [(scene.charge, spec?.casingMass ?? 0)],
                constructions: { scene.envelopeConstruction(for: $0) })
            while duration - solver.time > 1e-7 {
                if solver.advance(steps: 64, timeLimit: duration).steps == 0 { break }
            }
            let took = start.duration(to: .now)
            let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
            guard let snapshot = solver.envelopeVentingSnapshot() else { continue }
            print(
                String(
                    format: "%@ (%.0f s): %d wall perforations; close-in %@", name, seconds, perforations,
                    outcomes.isEmpty
                        ? "none"
                        : outcomes.map {
                            "\($0.key.split(separator: "/").suffix(2).joined(separator: "/")) \($0.value.rawValue)"
                        }.sorted().joined(separator: ", ")))
            if !areaLine.isEmpty { print(areaLine) }
            for object in scene.envelopeObjects {
                let holes = snapshot.holes.filter { $0.owner == object.id && $0.openedAtS != nil }
                let byCause = Dictionary(grouping: holes, by: \.cause).mapValues(\.count)
                let first = holes.compactMap(\.openedAtS).min()
                let panes = snapshot.panes.filter { $0.owner == object.id }
                let room = snapshot.inside(of: object.id)
                print(
                    String(
                        format:
                            "  %@: %d of %d panes broken; holes opened %@, first at %.1f ms; walls failed %d; inside %.2f kPa, %.0f Pa s",
                        object.name, panes.filter { $0.brokenAtS != nil }.count, panes.count,
                        byCause.isEmpty
                            ? "none"
                            : byCause.map { "\($0.value) by \($0.key)" }.sorted().joined(separator: ", "),
                        (first ?? .nan) * 1000,
                        snapshot.walls.filter { $0.owner == object.id && $0.failedAtS != nil }.count,
                        (room?.peakPa ?? 0) / 1000, room?.impulsePaS ?? 0))
            }
        }
    }
}
