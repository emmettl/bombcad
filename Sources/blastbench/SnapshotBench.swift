import BlastCore
import BlastRender
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

// `blastbench snapshot`.
// Split from main.swift (emmettl/bombcad-work#51).

func runSnapshot() throws {
    var scenario = chosenScenario()
    // `--standing [--dx 0.5]`: the scene's standing on the recommended air with glazing vented, as a
    // new document of the preset shows it, printed in place of a run.
    if flag("standing") {
        let standing = SceneStanding(
            StandingInputs(
                scenario: scenario, cellSize: option("dx").flatMap { Float($0) } ?? 0.25,
                configuration: .recommended, ventsGlazing: true))
        for line in standing.lines { print(line) }
        for line in standing.resolution { print("Resolution: \(line)") }
        for line in standing.unsupported { print("Not compared: \(line)") }
        return
    }
    // `--street-envelopes`: the street study's four buildings as exposure-only envelopes.
    if flag("street-envelopes") {
        scenario = try StreetInteractionStudy.make(.street)
        for object in scenario.structuralObjects { try scenario.useEnvelope(id: object.id) }
    }
    if let mass = option("mass").flatMap({ Float($0) }) { scenario.charge.mass = mass }
    // `--charge-z`: the charge's height above the ground, m.
    if let z = option("charge-z").flatMap({ Float($0) }) { scenario.charge.position.z = z }
    // `--fit-reach 10` fits an open scene to its charge as the app's Domain section does; a
    // `--terrain` is laid again over the domain it fits.
    if let reach = option("fit-reach").flatMap({ Float($0) }) {
        scenario.terrain = nil
        try scenario.fitOpenScene(scaledReach: reach)
        if let terrain = option("terrain") { applyTerrain(terrain, to: &scenario) }
    }
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.25
    let time = option("time").flatMap { Double($0) } ?? 0.03
    let output = option("out") ?? "snapshot.png"
    let width = option("width").flatMap { Int($0) } ?? 1600
    let height = option("height").flatMap { Int($0) } ?? 1000

    let solver = try makeAirSolver(scenario, cellSize: cellSize)
    print("Air: \(solver.grid.cellCount) cells of \(format(Double(cellSize), 3)) m")
    solver.configuration.movingWalls = !flag("stationary-walls")
    // `--blast-hazards`: the safety distances and the injury at standing height, as the app draws them.
    if flag("blast-hazards") { try solver.configureExposurePlane(heightM: 1.5, arrivalThresholdPa: 1_000) }
    let started = ContinuousClock.now
    var sleptAt: Double?
    var largest: Float = 0  // the structure's largest deflection, sampled every batch
    // Fragments, flown alongside a frame a millisecond, as the app does a batch at a time.
    var fragments = try option("fragments").map { path in
        FragmentConsumer(
            spec: try JSONDecoder().decode(
                FragmentSpec.self, from: Data(contentsOf: URL(fileURLWithPath: path))),
            scene: FragmentScene(scenario), keepsFrames: false)
    }
    func feedFragments() {
        guard var consumer = fragments else { return }
        let region = consumer.report.region(
            for: consumer.frame + 1, interval: 0.001, domain: scenario.domainSize,
            cellSize: solver.grid.cellSize)
        consumer.consume(solver.airSlice(region: region.box, stride: region.stride))
        fragments = consumer
    }
    // Ground points, a sample each at every batch's end, as in the app.
    var ground = try option("ground-shock").map { path in
        GroundShockConsumer(
            spec: try JSONDecoder().decode(
                GroundShockSpec.self, from: Data(contentsOf: URL(fileURLWithPath: path))))
    }
    func feedGround() {
        guard let region = ground?.region(cellSize: solver.grid.cellSize) else { return }
        ground?.consume(solver.groundSlice(low: region.low, high: region.high))
    }
    // The fireball's thermal radiation, reckoned a frame a millisecond, as the app does.
    var thermal = try option("thermal").map { path in
        let spec = try JSONDecoder().decode(
            ThermalSpec.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try spec.validate()
        return ThermalExposure(spec: spec, scene: FragmentScene(scenario))
    }
    let replay = try option("thermal-record").map { path in
        guard let thermal else { throw CocoaError(.coderInvalidValue) }
        return try ThermalReplayWriter(path: path, exposure: thermal, scene: FragmentScene(scenario))
    }
    // With --thermal-compare, the same frames reckoned with another fireball model too (the
    // shape against the volume, the sphere against the shape, or --thermal-compare-with's), and
    // each timed.
    var other = thermal.map { exposure in
        var spec = exposure.spec
        if let model = option("thermal-compare-with").flatMap(FireballModel.init(rawValue:)) {
            spec.fireball = model
        } else {
            spec.fireball = spec.fireball == .shape ? .sphere : .shape
        }
        return ThermalExposure(spec: spec, scene: FragmentScene(scenario))
    }
    if !flag("thermal-compare") { other = nil }
    // With --thermal-variants a.json,b.json, the same frames reckoned under each description too.
    var variants = try (option("thermal-variants")?.split(separator: ",") ?? []).map { path in
        let spec = try JSONDecoder().decode(
            ThermalSpec.self, from: Data(contentsOf: URL(fileURLWithPath: String(path))))
        try spec.validate()
        return (name: String(path), exposure: ThermalExposure(spec: spec, scene: FragmentScene(scenario)))
    }
    var thermalSeconds = (0.0, 0.0)
    var fireballSeconds = 0.0
    // What the compared model's fireball radiated, measured round it as the volume's is.
    var otherRadiated: [(time: Double, power: Double)] = []
    var largestShape: FireballShape?
    var largestCells: LuminousCells?
    func feedThermal() throws {
        guard var exposure = thermal else { return }
        let extracting = ContinuousClock.now
        let frame = solver.fireball(for: exposure.spec)
        let extraction = (ContinuousClock.now - extracting) / .seconds(1)
        fireballSeconds += extraction
        if let shape = frame.shape, shape.volume > largestShape?.volume ?? 0 { largestShape = shape }
        if let cells = frame.cells, cells.fills.count > largestCells?.fills.count ?? 0 {
            largestCells = cells
        }
        var started = ContinuousClock.now
        exposure.add(frame)
        let consumer = (ContinuousClock.now - started) / .seconds(1)
        thermalSeconds.0 += consumer
        try replay?.append(frame, extraction: extraction, consumer: consumer)
        thermal = exposure
        if var compared = other {
            started = ContinuousClock.now
            compared.add(frame)
            thermalSeconds.1 += (ContinuousClock.now - started) / .seconds(1)
            otherRadiated.append((frame.time, compared.radiatedPower(frame)))
            other = compared
        }
        for n in variants.indices { variants[n].exposure.add(frame) }
    }
    feedFragments()
    feedGround()
    try feedThermal()
    // The fireball cut out on the GPU at the end of each batch that lands on a frame, as a
    // headless run does.
    if let thermal { solver.frameRequest = FrameRequest(thermal: thermal.spec) }
    // `--envelope-damage`: each envelope judged one way from its components' histories, and
    // coloured by it, as the app does.
    let judgesEnvelopes = flag("envelope-damage") && !scenario.envelopeObjects.isEmpty
    if judgesEnvelopes {
        try solver.configureEnvelopeComponents(
            objects: scenario.envelopeObjects, options: EnvelopeHistoryOptions(windowS: time))
    }
    // Checkpoints (`SolverCheckpoint`): `--resume DIR` carries on from a saved state, `--from DIR`
    // draws it as it was saved, and `--checkpoint-at T --checkpoint-out DIR` saves the state at the
    // first 64-step boundary at or after T s. The fragments, ground points and fireball fed
    // alongside are not saved, so they cannot be used with them.
    let resumeFrom = option("resume") ?? option("from")
    let checkpointAt = option("checkpoint-at").flatMap { Double($0) }
    let checkpointOut = option("checkpoint-out").map { URL(filePath: $0) }
    if resumeFrom != nil || checkpointAt != nil {
        guard fragments == nil, ground == nil, thermal == nil else {
            print("Checkpoints do not cover --fragments, --ground-shock or --thermal.")
            exit(2)
        }
    }
    if let resumeFrom {
        let header = try solver.restoreCheckpoint(from: URL(filePath: resumeFrom), scene: scenario)
        print(
            String(
                format: "Resumed from %@: step %d, %.6f s (%.1f MB stored)", resumeFrom, header.stepCount,
                header.time,
                Double(header.storedBytes) / 1e6))
    }
    var checkpointSaved = false
    func saveCheckpointIfDue() {
        guard let checkpointAt, let checkpointOut, !checkpointSaved, solver.time >= checkpointAt,
            solver.stepCount.isMultiple(of: BlastSolver.checkpointInterval)
        else { return }
        do {
            let header = try solver.saveCheckpoint(to: checkpointOut, scene: scenario)
            checkpointSaved = true
            print(
                String(
                    format:
                        "Saved a checkpoint at step %d, %.6f s, to %@: %.1f MB raw, %.1f MB stored, %.2f s",
                    header.stepCount, header.time, checkpointOut.path, Double(header.rawBytes) / 1e6,
                    Double(header.storedBytes) / 1e6, header.seconds))
        } catch {
            print("No checkpoint: \(error)")
            checkpointSaved = true
        }
    }
    func advance(to end: Double) throws {
        while solver.time < end - 1e-9 {
            // Saving, to the next boundary: a frame's clipped batch leaves the steps off it.
            let interval = BlastSolver.checkpointInterval
            let result = solver.advance(
                steps: checkpointAt == nil || checkpointSaved ? 64 : interval - solver.stepCount % interval,
                timeLimit: fragments == nil && thermal == nil ? end : min(end, solver.time + 0.001))
            saveCheckpointIfDue()
            feedFragments()
            feedGround()
            try feedThermal()
            if solver.airIsAsleep, sleptAt == nil { sleptAt = solver.time }
            if let summary = solver.bodySummary() { largest = max(largest, summary.maxDisplacement) }
            if result.steps == 0 || !result.isStable { break }
        }
    }
    // `--frames 0.05,0.5,1`: a snapshot at each of these times too, `out` with the time in it.
    let frames = (option("frames")?.split(separator: ",").compactMap { Double($0) } ?? []).filter {
        $0 < time
    }
    for frameTime in frames.sorted() {
        try advance(to: frameTime)
        let stem = (output as NSString).deletingPathExtension
        try writeSnapshot(to: "\(stem)-\(format(frameTime * 1000, 0))ms.png")
    }
    if option("from") == nil { try advance(to: time) }
    if let thermal { try replay?.finish(thermal) }
    if checkpointAt != nil, !checkpointSaved {
        print(
            "No checkpoint: the run ended before a \(BlastSolver.checkpointInterval)-step boundary from --checkpoint-at"
        )
    }
    let wall = ContinuousClock.now - started
    try writeSnapshot(to: output)

    func writeSnapshot(to output: String) throws {
        solver.refreshVisualization()
        let renderer = try SceneRenderer(device: device)
        renderer.setScene(scenario, solver: solver)
        if judgesEnvelopes, let histories = solver.envelopeComponentHistories() {
            let rooms = Dictionary(
                uniqueKeysWithValues: scenario.envelopeObjects.map {
                    ($0.id, EnvelopeDamageAssessment.roomVolume(of: $0.envelope!))
                })
            let damage = EnvelopeDamageAssessment.assess(
                loads: histories.map(EnvelopeComponentLoad.init),
                constructions: { scenario.envelopeConstruction(for: $0) }, rooms: rooms)
            renderer.setEnvelopeDamage(
                Dictionary(uniqueKeysWithValues: damage.map { ($0.id, EnvelopeDamageColour.code($0)) }))
            // `--envelope-loads`: each component's faces and peak loads, to check what the air reached.
            if flag("envelope-loads") {
                for history in histories {
                    print(
                        "  \(history.component.kind) of \(history.component.owner.uuidString.prefix(8)): "
                            + "faces \(history.faceCount), peak outer "
                            + "\(format(Double(history.peakOuterPa) / 1000, 1)) kPa, "
                            + "net \(format(Double(history.peakNetPa) / 1000, 1)) kPa")
                }
            }
            for building in damage {
                let name = scenario.object(id: building.id)?.name ?? "Building"
                print(
                    "\(name): code \(EnvelopeDamageColour.code(building)), \(building.structuralLevels.lowerBound.label)"
                        + "–\(building.structuralLevels.upperBound.label), panes \(building.panesBroken)/\(building.panes)"
                        + ", \(building.components.filter { $0.material.isGlass && $0.failedAtS != nil }.count) gone"
                        + ", inside \(format(building.insidePeakPa / 1000, 1)) kPa"
                        + (building.worstGlazing.map { ", glazing GSA \($0.condition.rawValue)" } ?? "")
                        + (building.worstOverhead.map {
                            ", roof glass \($0.fall.rawValue)"
                                + ($0.fall == .whole || $0.fall == .shards
                                    ? " from \(format($0.dropM, 1)) m at \(format($0.impactSpeedMS, 0)) m/s, "
                                        + "\(format($0.energyPerAreaJM2, 0)) J/m²" : "")
                        } ?? "")
                )
            }
        }
        // Vent panels that have released are not drawn.
        let panels = (scenario.ventPanels ?? []).filter { $0.releasePressure > 0 }
        renderer.setVentPanels(zip(panels, solver.ventPanelOpenTimes).compactMap { $1 == nil ? $0.box : nil })
        switch option("mode") {
        case "now": renderer.settings.mode = .overpressure
        case "impulse": renderer.settings.mode = .impulse
        case "fluence": renderer.settings.thermal = .fluence
        case "irradiance": renderer.settings.thermal = .peakIrradiance
        case "temperature": renderer.settings.thermal = .surfaceTemperature
        case "ignition": renderer.settings.thermal = .ignition
        default: renderer.settings.mode = .peakOverpressure
        }
        renderer.settings.showWave = !flag("no-wave")
        if flag("highlight") {
            renderer.settings.highlight = scenario.structure?.solids.first ?? scenario.boxes.first
        }
        if let opacity = option("opacity").flatMap({ Float($0) }) { renderer.settings.waveOpacity = opacity }
        if let scale = option("scale").flatMap({ Float($0) }) { renderer.settings.pressureScale = scale }
        renderer.settings.showCharge = time == 0
        // `--ground alluvium [--explosive anfo]`: the craters the charges dig, shaded in as the app
        // does once a run ends (the air here still sees rigid ground); `--crater-time 0.1` draws
        // them as dug by then, as the app's replay does.
        if let name = option("ground"), let ground = GroundType(rawValue: name) {
            let craters = CraterEstimate.craters(
                of: scenario, ground: ground,
                explosive: option("explosive").flatMap(CraterExplosive.init) ?? .tnt)
            let dug = option("crater-time").flatMap(Float.init).map { time in
                craters.compactMap { $0.grown(atTime: time) }
            }
            renderer.settings.craters = (dug ?? craters).map(CraterMark.init)
            if let time = option("crater-time") {
                for crater in craters {
                    print(String(format: "  Formed by %.3f s; shown at %@ s", crater.formedAt, time))
                }
            }
            for crater in craters { print("  " + crater.summary) }
        }
        var dots: [SIMD4<Float>] = []
        if let ground {
            var result = ground.result(frameInterval: 0)
            result.place(on: scenario.terrain)
            dots += result.dots
            print("  " + result.summary)
        }
        if let thermal {
            // Painted onto the surfaces with --mode fluence, irradiance, temperature or ignition, as
            // the app paints them.
            let quantity = renderer.settings.thermal ?? .fluence
            let heating = thermal.result.heating
            let values: [Float] =
                switch quantity {
                case .fluence: thermal.fluence.map { Float($0) }
                case .peakIrradiance: thermal.peakIrradiance
                case .surfaceTemperature: heating.map { h in h.peakTemperature.map { $0 - h.ambient } } ?? []
                case .ignition: heating?.ignition.map(Float.init) ?? []
                }
            renderer.setSurfacePaint(
                SurfacePaint(
                    grids: ThermalExposure.surfaceGrids(scene: FragmentScene(scenario), spec: thermal.spec),
                    shades: values.map(quantity.shade)))
            print("Thermal radiation, the fireball as its \(thermal.spec.fireball.rawValue):")
            for line in thermal.result.summary { print(line) }
            // What it had radiated by each of a few moments.
            let result = thermal.result
            if result.isRadiationMeasured {
                var line = "  radiated by"
                for moment in [0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.17] where moment <= time + 1e-9 {
                    var sum = 0.0
                    for (a, b) in zip(result.fireball, result.fireball.dropFirst())
                    where b.time <= moment + 1e-9 {
                        sum += 0.5 * ((a.radiatedPower ?? 0) + (b.radiatedPower ?? 0)) * (b.time - a.time)
                    }
                    line += String(
                        format: " %.0f ms: %.1f%%;", moment * 1000, 100 * sum / max(result.chargeEnergy, 1))
                }
                print(line)
            }
            // How large and hot it was at each of a few moments.
            var across = "  across, and its temperature, at"
            for moment in [0.01, 0.02, 0.05, 0.1, 0.17, 0.3, 0.5] where moment <= time + 1e-9 {
                guard let frame = result.fireball.last(where: { $0.time <= moment + 1e-9 }) else { continue }
                across += String(
                    format: " %.0f ms: %.1f m, %.0f K;", moment * 1000, 2 * frame.radius, frame.temperature)
            }
            print(across)
            if let other {
                print("The same frames, the fireball as its \(other.spec.fireball.rawValue):")
                for line in other.result.summary { print(line) }
                print(
                    String(
                        format:
                            "Reckoned in %.2f s as its %@ and %.2f s as its %@, over %d frames; found in %.2f ms a frame",
                        thermalSeconds.0, thermal.spec.fireball.rawValue, thermalSeconds.1,
                        other.spec.fireball.rawValue,
                        thermal.frames.count, 1000 * fireballSeconds / Double(max(thermal.frames.count, 1))))
                for exposure in [thermal, other] {
                    if let gpu = exposure.marchGPUSeconds {
                        print(
                            String(
                                format: "  The %@'s march: %.2f ms of GPU time a frame",
                                exposure.spec.fireball.rawValue,
                                1000 * gpu / Double(max(exposure.frames.count, 1))))
                    }
                }
                let measured = zip(otherRadiated, otherRadiated.dropFirst()).reduce(0.0) {
                    $0 + 0.5 * ($1.0.power + $1.1.power) * ($1.1.time - $1.0.time)
                }
                print(
                    String(
                        format:
                            "As its %@, measured round it as the volume is: radiated %.1f MJ, %.1f%% of the charge's energy",
                        other.spec.fireball.rawValue, measured / 1e6,
                        100 * measured / max(other.result.chargeEnergy, 1)))
                // Each receiver's fluence by the first model against the second, by surface.
                let (shape, sphere) = (thermal, other)
                var surfaces: [String] = []
                for receiver in shape.receivers where !surfaces.contains(receiver.surface) {
                    surfaces.append(receiver.surface)
                }
                for surface in surfaces {
                    let indices = shape.receivers.indices.filter { shape.receivers[$0].surface == surface }
                    let a = indices.reduce(0.0) { $0 + shape.fluence[$1] }
                    let b = indices.reduce(0.0) { $0 + sphere.fluence[$1] }
                    let lit = indices.filter { shape.fluence[$0] > 0 || sphere.fluence[$0] > 0 }
                    let ratios = lit.map { (shape.fluence[$0] + 1) / (sphere.fluence[$0] + 1) }.sorted()
                    let median = ratios.isEmpty ? 0 : ratios[ratios.count / 2]
                    let shapeOnly = indices.filter { shape.fluence[$0] > 1000 && sphere.fluence[$0] < 1 }
                        .count
                    let sphereOnly = indices.filter { sphere.fluence[$0] > 1000 && shape.fluence[$0] < 1 }
                        .count
                    print(
                        String(
                            format:
                                "  %@: mean fluence %.1f kJ/m² as the %@, %.1f as the %@ (%+.0f%%); median ratio %.2f; over 1 kJ/m² by one only: %d, %d",
                            surface, a / Double(indices.count) / 1000, shape.spec.fireball.rawValue,
                            b / Double(indices.count) / 1000, sphere.spec.fireball.rawValue,
                            100 * (a / max(b, 1) - 1), median, shapeOnly, sphereOnly))
                }
            }
            for variant in variants {
                print("The same frames, as \(variant.name) describes them:")
                for line in variant.exposure.result.summary { print(line) }
            }
            if let largestCells {
                print(
                    String(
                        format: "Largest cells: %d by %d by %d voxels %.3f m a side, %.2f MB a frame",
                        largestCells.counts.x,
                        largestCells.counts.y, largestCells.counts.z, largestCells.voxelSize,
                        Double(largestCells.binary.count) / 1e6))
            }
            if solver.configuration.radiativeCooling != nil {
                // What the gas lost to its radiation by each of the same moments.
                var line = String(
                    format: "The gas lost %.1f MJ to its radiation, %.1f%% of the charge's energy; by",
                    solver.radiatedEnergy / 1e6,
                    100 * solver.radiatedEnergy / max(thermal.result.chargeEnergy, 1)
                )
                for moment in [0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.17] where moment <= time + 1e-9 {
                    let lost = solver.radiationHistory.last { $0.time <= moment + 1e-9 }?.energy ?? 0
                    line += String(
                        format: " %.0f ms: %.1f%%;", moment * 1000,
                        100 * lost / max(thermal.result.chargeEnergy, 1))
                }
                print(line)
            }
            let unburnt = solver.speciesTotals()
            if unburnt.fuel > 0 {
                print(
                    String(
                        format: "Unburnt products left: %.1f kg of %.1f kg", unburnt.fuel,
                        scenario.charge.mass))
            }
            if let largestShape {
                print(
                    String(
                        format: "Largest shape: %.1f m³ in blocks %.2f m a side, %d by %d by %d, %d tiles",
                        largestShape.volume, largestShape.blockSize, largestShape.counts.x,
                        largestShape.counts.y,
                        largestShape.counts.z, largestShape.tileCount))
            }
        }
        if let fragments {
            let launch = max(fragments.cloud.launchSpeed, 1)
            for (n, particle) in fragments.cloud.particles.enumerated() where !particle.landed {
                let value =
                    n < fragments.cloud.fragmentCount
                    ? min(simd_length(particle.velocity) / launch, 0.999) : 1
                dots.append(SIMD4(particle.position, value))
            }
            // `--hazard`: those in flight land, and the hazard distance is drawn as the app draws it.
            let landed = flag("hazard") ? fragments.result(frameInterval: 0.001) : nil
            for impact in landed?.impacts ?? fragments.cloud.impacts {
                if let outcome = impact.penetration?.outcome {
                    // A strike on a judged target, as the app draws it.
                    dots.append(
                        SIMD4(
                            impact.position, 4 + (outcome == .stopped ? 0.1 : outcome == .spalled ? 0.5 : 0.9)
                        ))
                    continue
                }
                dots.append(SIMD4(impact.position, 2 + min(max(log10(max(impact.energy, 1)) / 7, 0), 0.999)))
            }
            if let landed, !landed.strikeSummary.isEmpty { print("Strikes" + landed.strikeSummary) }
            print("Fragments: \(fragments.cloud.airborne) in flight, \(fragments.cloud.impacts.count) landed")
            if let hazard = landed?.hazard {
                print("Hazard: " + hazard.summary)
                let terrain = scenario.terrain
                renderer.setLines(HazardOverlay.lines(hazard) { terrain?.height(at: SIMD3($0, 0)) ?? 0 })
            }
        }
        renderer.setDots(dots)
        if let size = option("dot").flatMap({ Float($0) }) { renderer.settings.dotSize = size }
        var camera = OrbitCamera.framing(scenario)
        // `--target 40,40,2`: the point the camera looks at, rather than the scene's framing.
        if let values = option("target")?.split(separator: ",").compactMap({ Float($0) }), values.count == 3 {
            camera.target = SIMD3(values[0], values[1], values[2])
        }
        if let distance = option("distance").flatMap({ Float($0) }) { camera.distance = distance }
        if let azimuth = option("azimuth").flatMap({ Float($0) }) { camera.azimuth = azimuth }
        if let elevation = option("elevation").flatMap({ Float($0) }) { camera.elevation = elevation }
        // The fireball's cloud, handed over at the end and followed, drawn as the app draws it, and
        // with --frame-cloud seen as its button frames it.
        if let path = option("cloud") {
            let spec = try JSONDecoder().decode(
                CloudSpec.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let cloud = CloudResult(
                spec: spec, handOver: solver.cloudHandOver(hotterThan: spec.handOverTemperature))
            for line in cloud.summary { print(line) }
            if let results = option("cloud-results") {
                try JSONEncoder().encode(cloud).write(to: URL(fileURLWithPath: results))
            }
            if flag("frame-cloud") { camera = CloudOverlay.framing(cloud) }
            if let distance = option("distance").flatMap({ Float($0) }) { camera.distance = distance }
            if let azimuth = option("azimuth").flatMap({ Float($0) }) { camera.azimuth = azimuth }
            if let elevation = option("elevation").flatMap({ Float($0) }) { camera.elevation = elevation }
            renderer.setLines(CloudOverlay.lines(cloud, eye: camera.eye))
        }
        if flag("blast-hazards"), let snapshot = solver.exposureSnapshot() {
            let centre = SIMD2(scenario.charge.position.x, scenario.charge.position.y)
            let field = InjuryField(snapshot, centre: centre)
            print("Injury: " + field.summary)
            var lines: [SIMD4<Float>] = []
            for k in [KFactorDistance.k24, .k40] {
                lines += HazardOverlay.ring(
                    centre: centre, radius: k.requiredDistance(kilograms: scenario.charge.mass),
                    kind: .kFactor)
            }
            lines += HazardOverlay.contour(field, level: .eardrumThreshold, kind: .eardrum)
            lines += HazardOverlay.contour(field, level: .lethality50, kind: .lung)
            renderer.setLines(lines)
        }

        guard
            let frame = renderer.snapshot(
                commandQueue: solver.commandQueue, width: width, height: height, camera: camera),
            let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            print("Could not render the snapshot")
            exit(1)
        }
        CGImageDestinationAddImage(destination, frame.image, nil)
        CGImageDestinationFinalize(destination)
        print(
            "Wrote \(output): t = \(format(solver.time * 1000)) ms after \(solver.stepCount) steps, "
                + "frame rendered in \(format(frame.gpuSeconds * 1000, 2)) ms")
    }

    print(
        "Simulated in \(format(Double(wall.components.seconds) + Double(wall.components.attoseconds) * 1e-18, 1)) s"
            + (sleptAt.map { "; the air went quiet and was frozen at \(format($0 * 1000, 0)) ms" } ?? ""))
    if let summary = solver.bodySummary() {
        print(
            "Structure: \(summary.activeElements) elements intact, \(summary.erodedElements) failed, "
                + "deflection \(format(Double(summary.maxDisplacement) * 1000, 0)) mm "
                + "(largest \(format(Double(largest) * 1000, 0)) mm), "
                + "worst damage \(format(Double(min(summary.maxDamage, 1)) * 100, 0))%"
                + (summary.selfWeightSag > 0
                    ? "; sagged \(format(Double(summary.selfWeightSag) * 1000, 0)) mm under its own weight first"
                    : ""))
        if summary.activeBeams + summary.erodedBeams > 0 {
            print(
                "  Members: \(summary.erodedBeams) of \(summary.activeBeams + summary.erodedBeams) beam elements failed, "
                    + "moved up to \(format(Double(summary.maxBeamDisplacement) * 1000, 0)) mm"
                    + (summary.hinges > 0
                        ? "; \(summary.hingesReleased) of \(summary.hinges) connections fractured" : ""))
        }
    }
    printResultValues("snapshot", solver: solver)
    // `--hinges`: the steel connections by the height of their joints, 4 m bands: how many have
    // fractured, and the largest turn.
    if flag("hinges"), let shells = solver.shells {
        let positions = shells.referencePositions
        var moved = [SIMD3<Float>](repeating: .zero, count: positions.count)
        shells.mutateNodes { nodes in for n in nodes.indices { moved[n] = nodes[n].displacement } }
        var bands: [Int: (count: Int, released: Int, turn: Float, sideways: SIMD2<Float>)] = [:]
        for hinge in shells.hingeTurns {
            let band = Int(positions[hinge.jointNode].z / 4)
            var entry = bands[band] ?? (0, 0, 0, .zero)
            entry.count += 1
            entry.released += hinge.released ? 1 : 0
            entry.turn = max(entry.turn, hinge.turn)
            entry.sideways += SIMD2(moved[hinge.jointNode].x, moved[hinge.jointNode].y)
            bands[band] = entry
        }
        // The floors' largest vertical movement, on the horizontal beams' nodes in each band.
        var sag: [Int: Float] = [:]
        for beam in shells.beamNodes where beam.axis != 2 {
            for node in [beam.first, beam.second] {
                let band = Int(positions[node].z / 4)
                sag[band] = max(sag[band] ?? 0, abs(moved[node].z))
            }
        }
        for (band, entry) in bands.sorted(by: { $0.key < $1.key }) {
            print("    floors' beams moved up to \(format(Double(sag[band] ?? 0) * 1000, 0)) mm vertically")
            let sideways = entry.sideways / Float(entry.count) * 1000
            print(
                "  connections at \(4 * band)–\(4 * band + 4) m: \(entry.released) of \(entry.count) fractured, "
                    + "largest turn \(format(Double(entry.turn), 3)) rad; joints moved "
                    + "(\(format(Double(sideways.x), 0)), \(format(Double(sideways.y), 0))) mm sideways on average"
            )
        }
        var kinds: [String: (count: Int, released: Int)] = [:]
        for (hinge, kind) in zip(shells.hingeTurns, shells.hingeJointKinds) {
            kinds[kind, default: (0, 0)].count += 1
            kinds[kind, default: (0, 0)].released += hinge.released ? 1 : 0
        }
        for (kind, entry) in kinds.sorted(by: { $0.key < $1.key }) {
            print("  joints held by a \(kind): \(entry.released) of \(entry.count) fractured")
        }
        let plastic = shells.hingePlasticTurns
        if !plastic.isEmpty {
            let n = Double(plastic.count)
            print(
                "  plastic turn, mean (largest): about the vertical "
                    + "\(format(plastic.reduce(0) { $0 + Double($1.aboutVertical) } / n, 3)) "
                    + "(\(format(Double(plastic.map(\.aboutVertical).max() ?? 0), 3))) rad, about the horizontal "
                    + "\(format(plastic.reduce(0) { $0 + Double($1.aboutHorizontal) } / n, 3)) "
                    + "(\(format(Double(plastic.map(\.aboutHorizontal).max() ?? 0), 3))) rad")
        }
    }
    // `--runaway m`: the active elements with a node moved further than m, by material.
    if let limit = option("runaway").flatMap(Float.init), let shells = solver.shells {
        let (counts, nonFinite) = shells.runaway(beyond: limit)
        print(
            "Runaway beyond \(format(Double(limit), 0)) m: \(nonFinite) nodes not finite, turned off unit or spinning over 10⁴ rad/s"
        )
        for (name, count) in counts.sorted(by: { $0.value > $1.value }) { print("  \(count)  \(name)") }
    }
    if solver.bodies.count > 1 {
        for body in solver.bodies {
            guard let summary = body.summary() else { continue }
            print(
                "  \(body.name): \(summary.erodedElements) of \(summary.activeElements + summary.erodedElements) "
                    + "elements failed, moved up to \(format(Double(summary.maxDisplacement) * 1000, 0)) mm"
                    + (summary.selfWeightSag > 0
                        ? " (after sagging \(format(Double(summary.selfWeightSag) * 1000, 0)) mm under its own weight)"
                        : ""))
        }
    }
    // Each gauge's peak overpressure and positive impulse over the run.
    let ambient = solver.configuration.ambientPressure
    for (gauge, samples) in zip(scenario.gauges, solver.gaugeHistories) where !samples.isEmpty {
        var peak: Float = 0
        var impulse: Double = 0
        for (a, b) in zip(samples, samples.dropFirst()) {
            impulse += Double(max(b.pressure - ambient, 0)) * (b.time - a.time)
            peak = max(peak, b.pressure - ambient)
        }
        print(
            "  \(gauge.name): \(format(Double(peak) / 1000, 1)) kPa "
                + "(\(format(Double(peak) / 6894.76, 2)) psi), \(format(impulse, 0)) Pa s")
    }
}
