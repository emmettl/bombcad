import BlastCore
import BlastRender
import DocumentKit
import Foundation
import Metal
import Observation
import simd

// SimulationModel's companion models and their consumers: ground shock, fragments, placing
// companions by cost, thermal radiation, the cloud and the hazards drawn from them. Split from
// SimulationModel.swift (emmettl/bombcad-work#52).
extension SimulationModel {
    /// Starts estimating the ground's shaking for a run beginning now, if the project has
    /// ground points within its domain.
    func startGroundShock(_ solver: BlastSolver) {
        stopGroundShock()
        guard let spec = groundShockSpec else { return }
        guard (try? spec.validate(domain: scenario.domainSize)) != nil else {
            groundShockStatus =
                "Some ground points lie outside the domain; move them to estimate the shaking."
            return
        }
        if let host = host(groundShockHost, name: "ground"), let worker = workers[host] {
            groundShock = remoteConsumer(worker, kind: .groundShock(spec, live: true))
        } else {
            groundShock = LocalFrameConsumer(.groundShock(spec, live: true))
        }
        estimatedGroundSpec = spec
        sendGroundShockFrame(solver)
        updateGroundShockStatus()
    }

    func stopGroundShock() {
        groundShock?.cancel()
        groundShock = nil
        estimatedGroundSpec = nil
        groundShockTime = -1
        groundShockLive = nil
        groundShockStatus = ""
    }

    /// The air on the ground now: at the start, then once a run passes each millisecond, and at
    /// the end (`last`), as the fragments get theirs. A sample a point, taken in line: the peaks
    /// are the solver's own, kept every step, so the frames miss none of them, and the batches
    /// are not shortened for them, so the air is untouched.
    func sendGroundShockFrame(_ solver: BlastSolver, last: Bool = false) {
        guard groundShock != nil, solver.time > groundShockTime + 1e-9 else { return }
        let interval = Self.fragmentFrameInterval
        let next = groundShockTime < 0 ? 0 : (floor(groundShockTime / interval + 1e-6) + 1) * interval
        guard last || solver.time >= next - 1e-9 else { return }
        groundShockTime = solver.time
        guard let groundShock, let spec = estimatedGroundSpec else { return }
        let region = spec.region(cellSize: solver.grid.cellSize)
        groundShock.send(.ground(solver.groundSlice(low: region.low, high: region.high)))
    }

    func updateGroundShockStatus() {
        guard let groundShock, var result = groundShock.groundShockLive else { return }
        result.place(on: scenario.terrain)
        if groundShockLive != result { groundShockLive = result }
        let open = result.points.filter { !$0.covered }
        let reached = open.filter { $0.arrival != nil }
        var text = "The blast has reached \(reached.count) of \(result.points.count) points"
        if let top = reached.max(by: {
            $0.surfaceVelocity(in: result.soil) < $1.surfaceVelocity(in: result.soil)
        }) {
            text += String(
                format: "; the ground moves fastest under (%.1f, %.1f), %.0f mm/s down",
                top.position.x, top.position.y, top.surfaceVelocity(in: result.soil) * 1000)
        }
        let covered = result.points.count - open.count
        if covered > 0 { text += "; \(covered) under a block or the structure" }
        let outrun = reached.filter { $0.regime == .outrunning }.count
        if outrun > 0 { text += "; outrun by the ground's wave at \(outrun)" }
        if !groundShock.caughtUp {
            text += " · \(groundShock.sent - 1 - groundShock.report.frame) frames to estimate"
        }
        let place = groundShock.placement
        if !place.isEmpty { text += " ·" + place }
        groundShockStatus = text
    }

    /// Starts flying the project's fragments for a run beginning now, if it has any.
    /// With glazing vented, the panes the run's fragments hole open in the air when they do: the
    /// fragments flown first in still air to find when (`FragmentCloud.paneHoles`), so the air is
    /// the same however the run is batched and however the fragments' consumer keeps up.
    func setFragmentPaneHoles(_ solver: BlastSolver) {
        guard solver.ventsGlazing else { return }
        guard let spec = paneHoleSpec ?? fragmentSpec, spec.count > 0, (try? spec.validate()) != nil else {
            solver.setEnvelopePaneHoles([:])
            try? solver.setEnvelopeWallHoles([EnvelopeHole]())
            return
        }
        // One flight for both: the panes holed, and the walls, roofs and slabs perforated.
        let holes = FragmentCloud.envelopeHoles(
            spec: spec, scene: FragmentScene(scenario), density: scenario.atmosphere.density,
            pressure: scenario.atmosphere.pressure, until: duration)
        var panes: [String: Double] = [:]
        for hole in holes {
            guard let pane = hole.pane else { continue }
            let id = "\(hole.owner.uuidString)/pane/\(pane).0"
            panes[id] = min(panes[id] ?? .infinity, hole.time)
        }
        solver.setEnvelopePaneHoles(panes)
        do {
            try solver.setEnvelopeWallHoles(holes.filter { $0.pane == nil })
        } catch {
            envelopeVentingStatus = "Holes through walls not opened: \(error.localizedDescription)"
        }
    }

    func startFragments(_ solver: BlastSolver) {
        guard let spec = fragmentSpec, spec.count + spec.tracers > 0, (try? spec.validate()) != nil else {
            return
        }
        stopFragments()
        let scene = FragmentScene(scenario)
        let consumer: any FrameConsumer
        if let host = host(fragmentsHost, name: "fragments"), let worker = workers[host] {
            consumer = remoteConsumer(worker, kind: .fragments(spec, scene, live: true))
        } else {
            consumer = LocalFrameConsumer(.fragments(spec, scene, live: true))
        }
        fragments = consumer
        flownSpec = spec
        fragmentLaunchSpeed = spec.launchSpeed(chargeMass: scenario.charge.mass)
        fragmentLive = consumer.fragmentLive
        fragmentTime = -1
        // The consumer may fall up to four frames behind; then the run waits for it.
        holdBatches = { consumer.sent - 1 - consumer.report.frame > 4 }
        sendFragmentFrame(solver)
        updateFragmentStatus()
    }

    func stopFragments() {
        // The gate is the fragments' only while they run; a headless run may set its own.
        if fragments != nil { holdBatches = nil }
        fragments?.cancel()
        fragments = nil
        flownSpec = nil
        fragmentLive = nil
        fragmentHazard = nil
        fragmentStrikes = nil
        fragmentStatus = ""
    }

    /// The air now, for the fragments: at the start, then once a run passes each millisecond, as a
    /// headless run sends it, not after every batch, which took a copy of the air on the main
    /// thread while the GPU waited; and at the end (`last`).
    func sendFragmentFrame(_ solver: BlastSolver, last: Bool = false) {
        guard let fragments, solver.time > fragmentTime + 1e-9 else { return }
        let interval = Self.fragmentFrameInterval
        let next = fragmentTime < 0 ? 0 : (floor(fragmentTime / interval + 1e-6) + 1) * interval
        guard last || solver.time >= next - 1e-9 else { return }
        fragmentTime = solver.time
        let region = fragments.report.region(
            for: fragments.sent, interval: interval, domain: scenario.domainSize,
            cellSize: solver.grid.cellSize)
        fragments.send(.air(solver.airSlice(region: region.box, stride: region.stride)))
    }

    func updateFragmentStatus() {
        guard let live = fragments?.fragmentLive else { return }
        fragmentLive = live
        let landed = live.impacts.count
        let flying = (0..<live.fragmentCount).filter { !live.landed[$0] }.count
        let energy = live.impacts.map(\.energy).max() ?? 0
        var text = "\(flying) fragments in flight, \(landed) landed"
        if energy > 0 {
            text +=
                energy >= 1e6
                ? String(format: ", hardest %.1f MJ", energy / 1e6)
                : String(format: ", hardest %.0f kJ", energy / 1e3)
        }
        let place = fragments?.placement ?? ""
        if !place.isEmpty { text += " ·" + place }
        if let hazard = fragmentHazard {
            text +=
                hazard.hazardDistance.map {
                    String(format: ". Hazardous fragment distance %.0f m", $0)
                        + (hazard.samplesAtDistance < GroundHazard.wellSampled
                            ? " (few flown; fly more)" : "")
                } ?? ". Nowhere over 1 hazardous fragment per 55.7 m²"
        }
        fragmentStatus = text
    }

    /// A companion on the Mac set for sweeps that carries on here if that Mac fails it, or on its
    /// own there if its frames cannot be kept.
    private func remoteConsumer(_ worker: SweepWorkerClient, kind: ConsumerKind) -> any FrameConsumer {
        (try? ResilientFrameConsumer(client: worker, kind: kind, ownsClient: false))
            ?? RemoteFrameConsumer(client: worker, kind: kind, ownsClient: false)
    }

    /// The Mac a companion set to run on `setting` runs on in a run starting now; nil for this
    /// one.
    private func host(_ setting: String?, name: String) -> String? {
        guard setting == ConsumerPlacement.automatic else { return setting }
        return automaticPlaces[name].flatMap { $0 == "local" ? nil : $0 }
    }

    /// The companions the project runs, by name, as a run starting now would start them.
    private var companionKinds: [String: ConsumerKind] {
        let scene = FragmentScene(scenario)
        var kinds: [String: ConsumerKind] = [:]
        if let spec = fragmentSpec { kinds["fragments"] = .fragments(spec, scene, live: true) }
        if let spec = thermalSpec { kinds["thermal"] = .thermal(spec, scene, live: true) }
        if let spec = groundShockSpec { kinds["ground"] = .groundShock(spec, live: true) }
        return kinds
    }

    private func costs(for key: String) -> ConsumerCosts {
        measuredCosts[key] ?? costStore?.costs(for: key) ?? ConsumerCosts()
    }

    private func keep(_ costs: ConsumerCosts, for key: String) {
        measuredCosts[key] = costs
        costStore?.record(costs, for: key)
    }

    /// Where each companion set to Automatic goes in a run starting now: by `ConsumerPlacement`'s
    /// plan, among this Mac and the Macs connected, from what the last run and the probes
    /// measured; this Mac until something has been.
    func placeAutomatically() {
        let settings = ["fragments": fragmentsHost, "thermal": thermalHost, "ground": groundShockHost]
        runCostKey = ConsumerCostStore.key(currentInputs, frameInterval: 0.001)
        automaticPlaces = [:]
        guard settings.values.contains(ConsumerPlacement.automatic), let key = runCostKey else { return }
        let kinds = companionKinds
        let hosts = workers.keys.sorted()
        var choices: [String: [String]] = [:]
        for name in kinds.keys {
            let setting = settings[name] ?? nil
            choices[name] =
                setting == ConsumerPlacement.automatic
                ? ["local"] + hosts : [setting.flatMap { workers[$0] == nil ? nil : $0 } ?? "local"]
        }
        let plan = ConsumerPlacement.plan(choices, kinds: kinds, costs: costs(for: key))
        automaticPlaces = plan.places.filter { settings[$0.key] == ConsumerPlacement.automatic }
    }

    /// Probes the thermal radiation, if placed automatically, here and on each Mac connected, so
    /// that the next run is placed by each Mac's speed now.
    func probeAutomatic(timeout: Duration? = .seconds(30)) async {
        guard thermalHost == ConsumerPlacement.automatic, !isRunning, let kind = companionKinds["thermal"],
            let spec = thermalSpec, (try? spec.validate()) != nil,
            let key = ConsumerCostStore.key(currentInputs, frameInterval: 0.001)
        else { return }
        var costs = costs(for: key)
        await ConsumerProbe.probe(
            "thermal", kind: kind, inputs: currentInputs,
            workers: workers.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, into: &costs,
            timeout: timeout)
        keep(costs, for: key)
    }

    /// What the run's companions cost, a millisecond of simulated time, once each has every
    /// frame in: each where it ran, and the blast's GPU time, less that of companions here
    /// sharing its GPU.
    func recordCosts(blastGPUSeconds: Double, elapsed: Double) async {
        let start = ContinuousClock.now
        while !companionsCaughtUp, CatchUpLimits.within(catchUpLimits.costs, since: start) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard companionsCaughtUp, let key = runCostKey, elapsed > 0 else { return }
        let frames = elapsed / 0.001
        var costs = costs(for: key)
        var blast = blastGPUSeconds
        for (name, consumer) in [("fragments", fragments), ("thermal", thermal), ("ground", groundShock)] {
            guard let consumer, consumer.sent > 0, (consumer as? ResilientFrameConsumer)?.fallback == nil
            else {
                continue
            }
            let site =
                (consumer as? ResilientFrameConsumer)?.host ?? (consumer as? RemoteFrameConsumer)?.host
                ?? "local"
            let gpu = (consumer as? LocalFrameConsumer)?.gpuSeconds.map { $0 > 0 }
            costs.measured(
                name, kind: consumer.kind, place: site, seconds: consumer.seconds / frames, usesGPU: gpu)
            if site == "local", gpu == true { blast -= consumer.seconds }
        }
        costs.frameSeconds = max(blast, 0) / frames
        if let radius = fireballFrames.map(\.radius).max(), radius > 0 { costs.fireballRadius = radius }
        keep(costs, for: key)
    }

    /// Runs the companions set for `host` through `worker` from the next run, as if connected to
    /// it; for tests.
    func useWorker(_ worker: SweepWorkerClient, host: String) {
        workers[host] = worker
    }

    /// Connects to each of `hosts`, of those the companions are set to run on, sharing one
    /// connection between those on the same Mac, and lets the others go.
    func connectWorkers(_ hosts: Set<String>) async {
        for (host, worker) in workers where !hosts.contains(host) {
            worker.close()
            workers[host] = nil
        }
        for host in hosts.sorted() where workers[host] == nil {
            setPlacementStatus(
                on: host, fragments: "Connecting to \(host)…", thermal: "Connecting to \(host)…",
                ground: "Connecting to \(host)…")
            do {
                let worker = try await RemoteSweepWorker.connect(host: host)
                guard wantedHosts.contains(host) else {
                    worker.close()
                    continue
                }
                workers[host]?.close()
                workers[host] = worker
                setPlacementStatus(
                    on: host, fragments: "Fragments will fly on \(host) from the next run.",
                    thermal: "The thermal radiation will be reckoned on \(host) from the next run.",
                    ground: "The ground's shaking will be estimated on \(host) from the next run.")
            } catch {
                let reason = error.localizedDescription
                setPlacementStatus(
                    on: host, fragments: "Fragments fly here: \(reason)", thermal: "Reckoned here: \(reason)",
                    ground: "Estimated here: \(reason)")
            }
        }
        await probeAutomatic()
    }

    /// Says how the connection to `host` stands, in the status of each companion set to run there.
    private func setPlacementStatus(on host: String, fragments: String, thermal: String, ground: String) {
        if fragmentsHost == host { fragmentStatus = fragments }
        if thermalHost == host { thermalStatus = thermal }
        if groundShockHost == host { groundShockStatus = ground }
    }

    /// Starts reckoning the project's thermal radiation for a run beginning now, if it has any.
    func startThermal(_ solver: BlastSolver) {
        stopThermal()
        guard let spec = thermalSpec, (try? spec.validate()) != nil else { return }
        let scene = FragmentScene(scenario)
        if let host = host(thermalHost, name: "thermal"), let worker = workers[host] {
            thermal = remoteConsumer(worker, kind: .thermal(spec, scene, live: true))
        } else {
            thermal = LocalFrameConsumer(.thermal(spec, scene, live: true))
        }
        thermalGrids = ThermalExposure.surfaceGrids(scene: scene, spec: spec)
        thermalReceivers = thermalGrids.flatMap(\.receivers)
        thermalHeating =
            spec.heating.enabled
            ? SurfaceHeating.Layout(spec: spec.heating, grids: thermalGrids, scene: scene) : nil
        reckonedSpec = spec
        nextFireballTime = 0
        // A mapped start's clock starts at its solution's time: the fireball before it, a frame a
        // millisecond, from the one-dimensional solution, so that the record starts at detonation.
        if solver.stepCount == 0, solver.time > 0.001 {
            let times = (1...Int((solver.time / 0.001).rounded(.down))).map { Double($0) * 0.001 }
            for frame in solver.earlyFireballFrames(for: spec, at: times) {
                fireballFrames.append(frame.withoutShape)
                thermal?.send(.fireball(frame))
            }
        }
        sendFireball(solver)
        updateThermalStatus()
    }

    func stopThermal() {
        thermal?.cancel()
        thermal = nil
        thermalReceivers = []
        thermalGrids = []
        thermalHeating = nil
        reckonedSpec = nil
        fireballFrames = []
        thermalPaintCache = nil
        thermalStatus = ""
        thermalReckoned = 0
    }

    /// The fireball now, for the thermal radiation, at the first batch's end in each millisecond
    /// and at the run's end.
    func sendFireball(_ solver: BlastSolver) {
        guard let thermal, let spec = reckonedSpec,
            solver.time >= nextFireballTime - 1e-9 || solver.time >= duration - 1e-9,
            solver.time > (fireballFrames.last?.time ?? -1) + 1e-9
        else { return }
        let frame = solver.fireball(for: spec)
        fireballFrames.append(frame.withoutShape)
        thermal.send(.fireball(frame))
        nextFireballTime = (floor(solver.time / 0.001 + 1e-6) + 1) * 0.001
    }

    /// The thermal radiation or the ground shock has fallen too far behind the run, which waits
    /// for it.
    var thermalIsBehind: Bool {
        [thermal, groundShock].contains { consumer in
            consumer.map { $0.sent - 1 - $0.report.frame > 4 } ?? false
        }
    }

    func updateThermalStatus() {
        guard let thermal else { return }
        let live = thermal.thermalLive ?? ThermalLive(receivers: thermalReceivers.count)
        if thermalReckoned != live.frames { thermalReckoned = live.frames }
        var text: String
        if let largest = fireballFrames.max(by: { $0.volume < $1.volume }), largest.volume > 0 {
            text = String(format: "Fireball up to %.1f m across", 2 * largest.radius)
            if let now = fireballFrames.last, now.volume > 0 {
                text += String(format: ", %.0f K now", now.temperature)
            }
        } else {
            text = "No gas luminous yet"
        }
        let dose = live.fluence.max() ?? 0
        text += String(format: " · fluence up to %.1f kJ/m² over ", dose / 1000)
        text += "\(thermalReceivers.count.formatted()) receivers"
        if let spec = reckonedSpec, let heating = heatingResult(live, spec: spec) {
            let hottest = heating.peakTemperature.max() ?? heating.ambient
            text += String(format: " · surfaces up to %.0f K", hottest)
            let flagged = heating.ignition.filter { $0 != 0 }.count
            if flagged > 0 { text += " · \(flagged.formatted()) past ignition thresholds (illustrative)" }
        }

        if live.frames < thermal.sent { text += " · \(thermal.sent - live.frames) frames to reckon" }
        let place = thermal.placement
        if !place.isEmpty { text += " ·" + place }
        thermalStatus = text
    }

    /// Hands the hot gas left at the run's end over to the cloud model, if the project follows
    /// it, and follows the cloud away from this thread; a few milliseconds for ten minutes.
    func followCloud(_ solver: BlastSolver) {
        guard let spec = cloudSpec, (try? spec.validate()) != nil, cloud == nil, !followingCloud else {
            return
        }
        let handOver = solver.cloudHandOver(hotterThan: spec.handOverTemperature)
        followingCloud = true
        cloudTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                CloudResult(spec: spec, handOver: handOver)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.cloud = result
            self.followingCloud = false
            self.cloudTask = nil
        }
    }

    func stopCloud() {
        cloudTask?.cancel()
        cloudTask = nil
        followingCloud = false
        cloud = nil
    }

    /// Frames the view on the cloud: the whole of its path up to where it stopped rising, if that
    /// is near enough to see whole, and otherwise the cloud where it stopped.
    func frameCloud() {
        guard let cloud, cloud.handOver.mass > 0 else { return }
        camera = CloudOverlay.framing(cloud)
    }
}

extension SimulationModel {
    /// The hazardous fragment distance on the ground (`HazardOverlay`), once the run's
    /// fragments have landed.
    /// The safety standards' K-factor distances (K24, K40), the minimum safe distance, and the run's
    /// injury contours at standing height: where eardrums begin to rupture and where half would die.
    func blastHazardLines() -> [SIMD4<Float>] {
        let terrain = scenario.terrain
        let ground: (SIMD2<Float>) -> Float = { terrain?.height(at: SIMD3($0, 0)) ?? 0 }
        let centre = SIMD2(scenario.charge.position.x, scenario.charge.position.y)
        var lines: [SIMD4<Float>] = []
        for k in [KFactorDistance.k24, .k40] {
            lines += HazardOverlay.ring(
                centre: centre, radius: k.requiredDistance(kilograms: scenario.charge.mass), kind: .kFactor,
                ground: ground)
        }
        let safe = MinimumSafeDistance(
            kilograms: scenario.charge.mass, fragments: fragmentHazard, cased: isCased,
            debris: envelopeDebris?.hazard, inStructure: scenario.chargeInsideBuilding)
        if safe.distanceM > safe.overpressureM {
            lines += HazardOverlay.ring(
                centre: centre, radius: safe.distanceM, kind: .kFactor, ground: ground)
        }
        if let injuryField {
            lines += HazardOverlay.contour(
                injuryField, level: .eardrumThreshold, kind: .eardrum, ground: ground)
            lines += HazardOverlay.contour(injuryField, level: .lethality50, kind: .lung, ground: ground)
        }
        return lines
    }

    /// Whether the charge is cased: its fragments flown, in the app or headless.
    var isCased: Bool { (paneHoleSpec ?? fragmentSpec).map { $0.casingMass > 0 && $0.count > 0 } ?? false }

    /// A headless run's fragments' hazard, which its own consumer finds, for the minimum safe distance.
    func setFragmentHazard(_ hazard: GroundHazard?) { if let hazard { fragmentHazard = hazard } }

    /// The run's blast hazards in words: the safety standards' distances, the minimum safe
    /// distance and what governs it, and the injury's reach at standing height.
    var blastHazardSummary: [String] {
        let mass = scenario.charge.mass
        var lines = KFactorDistance.all.map { k in
            String(format: "%@: %.0f m", k.name, k.requiredDistance(kilograms: mass)) + " — "
                + k.use.lowercased()
                + (k.requiredDistance(kilograms: mass) > k.distance(kilograms: mass)
                    ? String(format: "; the K-factor alone gives %.0f m", k.distance(kilograms: mass)) : "")
        }
        lines.append(
            "M"
                + MinimumSafeDistance(
                    kilograms: mass, fragments: fragmentHazard, cased: isCased,
                    debris: envelopeDebris?.hazard,
                    inStructure: scenario.chargeInsideBuilding
                ).summary
                .dropFirst())
        if let envelopeDebris { lines.append(envelopeDebris.summary) }
        if let injuryField { lines.append(injuryField.summary) }
        return lines
    }

    func hazardLines() -> [SIMD4<Float>] {
        let terrain = scenario.terrain
        // The fragments' rings, and the envelope debris's beside them.
        return [fragmentHazard, envelopeDebris?.hazard].compactMap { $0 }.flatMap { hazard in
            HazardOverlay.lines(hazard) { terrain?.height(at: SIMD3($0, 0)) ?? 0 }
        }
    }

    /// Draws the run's particles: in flight, coloured by speed; tracers; where fragments landed,
    /// coloured by their energy; and where they struck a judged target, by what they did. Each is
    /// a position and a code, the kind (0 a fragment, 1 a tracer, 2 a landing, 4 a strike) plus a
    /// value from 0 to 1.
    func fragmentDots(showFragments: Bool, showTracers: Bool) -> [SIMD4<Float>] {
        // Straight from the consumer, so the dots move with every frame drawn.
        fragmentDots(
            fragments?.fragmentLive ?? fragmentLive, showFragments: showFragments, showTracers: showTracers)
    }

    /// `live`'s fragments and tracers in flight, and its strikes, as the view draws them.
    func fragmentDots(_ live: FragmentLive?, showFragments: Bool, showTracers: Bool) -> [SIMD4<Float>] {
        guard let live else { return [] }
        var dots: [SIMD4<Float>] = []
        dots.reserveCapacity(live.positions.count)
        for n in live.positions.indices {
            let fragment = n < live.fragmentCount
            if fragment, showFragments, !live.landed[n] {
                dots.append(SIMD4(live.positions[n], min(live.speeds[n] / fragmentScale, 0.999)))
            } else if !fragment, showTracers, !live.landed[n] {
                dots.append(SIMD4(live.positions[n], 1))
            }
        }
        if showFragments {
            for impact in live.impacts {
                if let outcome = impact.penetration?.outcome {
                    // A strike on a judged target, by what it did (Render.metal's kind 4).
                    let value: Float = outcome == .stopped ? 0.1 : outcome == .spalled ? 0.5 : 0.9
                    dots.append(SIMD4(impact.position, 4 + value))
                    continue
                }
                // log10 of the energy over 7 decades: 1 J to 10 MJ.
                dots.append(SIMD4(impact.position, 2 + min(max(log10(max(impact.energy, 1)) / 7, 0), 0.999)))
            }
        }
        return dots
    }

    private var fragmentScale: Float { max(fragmentLaunchSpeed, 1) }

    /// Draws the ground points as the run has left them, or before a run where they will be.
    func groundShockDots() -> [SIMD4<Float>] {
        groundShockLive?.dots ?? groundShockSpec?.dots(on: settings.scenario.terrain) ?? []
    }

    /// Paints the thermal radiation so far onto the ground and the faces, its fluence or its peak
    /// irradiance on the view's scale, interpolated between the receivers.
    func thermalPaint(_ quantity: ThermalQuantity) -> SurfacePaint? {
        guard let thermal, let live = thermal.thermalLive else { return nil }
        if let cache = thermalPaintCache, cache.frames == live.frames, cache.quantity == quantity {
            return cache.paint
        }
        let values: [Float]
        switch quantity {
        case .fluence: values = live.fluence
        case .peakIrradiance: values = live.peakIrradiance
        case .surfaceTemperature, .ignition:
            guard let spec = reckonedSpec, let heating = heatingResult(live, spec: spec) else { return nil }
            values =
                quantity == .ignition
                ? heating.ignition.map(Float.init) : heating.peakTemperature.map { $0 - heating.ambient }
        }
        let paint = SurfacePaint(grids: thermalGrids, shades: values.map(quantity.shade))
        thermalPaintCache = (live.frames, quantity, paint)
        return paint
    }

    /// The surfaces' heating so far, with the materials they were given and the ignition thresholds
    /// they passed; nil where it is not reckoned or has not come in.
    func heatingResult(_ live: ThermalLive, spec: ThermalSpec) -> SurfaceHeatingResult? {
        guard let thermalHeating, live.peakTemperature.count == thermalHeating.material.count else {
            return nil
        }
        return thermalHeating.result(
            peakTemperature: live.peakTemperature, fluence: live.fluence, ambient: spec.heating.ambient)
    }
}
