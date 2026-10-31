import BlastCore
import Foundation
import simd

// Fire after the blast (emmettl/bombcad-work#38, stage 3; docs/fire-spread.md): the fire spread over
// the envelope buildings from the quick estimate's glass and walls, or a run's damage, drawn away
// from the main thread whenever its inputs change, a preview's few draws while they move and the
// full ensemble after; a newer request cancels the one under way. The hour shown recolours the
// buildings from the draws kept, without drawing again. Illustrative throughout.

/// The draws of the fire done so far, of how many.
struct FireProgress: Equatable {
    var done: Int
    var of: Int
}

extension SimulationModel {
    /// The draws a preview takes, while the charge or a slider moves, and the full ensemble.
    nonisolated static let fireDraws = (preview: 40, full: 200)

    /// The hours the fire may be drawn over.
    static let fireHorizons: [Double] = [3, 6, 12, 24]

    /// Where the fire's glass and walls come from now: the quick estimate's chances, or a run's
    /// damage once it has stopped; nil without either.
    var fireSource: FireSpread.LayerSource? {
        if envelopeDamageIsEstimate {
            guard !envelopeGlassChances.isEmpty else { return nil }
            // A preview of the glass alone leaves the walls' chances of another place of the charge.
            return .estimate(
                glass: envelopeGlassChances, structure: peopleUsesStructure ? envelopeStructureChances : [])
        }
        guard !envelopeDamage.isEmpty, !isRunning, stepCount > 0 else { return nil }
        return .run(envelopeDamage)
    }

    /// The run's surface-heating flags, once its thermal radiation is all in; nil otherwise.
    var fireThermal: FireSpread.ThermalFlags? {
        guard !envelopeDamageIsEstimate, !isRunning, let thermal, thermal.caughtUp,
            let live = thermal.thermalLive, let spec = reckonedSpec,
            let heating = heatingResult(live, spec: spec)
        else { return nil }
        return FireSpread.ThermalFlags(receivers: thermalReceivers, heating: heating)
    }

    /// Draws the fire again for the inputs as they are now: a preview while they move, the full
    /// ensemble otherwise. The one under way, if any, is cancelled.
    func requestFire() {
        fireTask?.cancel()
        fireTask = nil
        fireGeneration &+= 1
        guard let source = fireSource else {
            fireProgress = nil
            fireStatus = ""
            if fireLayer != nil {
                fireLayer = nil
                if envelopeColouring == .fire { applyEnvelopeDamageColours() }
            }
            return
        }
        guard fireSettings.hasSeeds else {
            fireProgress = nil
            fireStatus =
                "Choose where fires start: pick buildings in the view, near the charge, or at random."
            if fireLayer != nil {
                fireLayer = nil
                if envelopeColouring == .fire { applyEnvelopeDamageColours() }
            }
            return
        }
        let preview = fireAdjusting || (envelopeDamageIsEstimate && envelopeEstimateIsPreview)
        let members = preview ? Self.fireDraws.preview : Self.fireDraws.full
        let (scenario, settings, thermal) = (self.settings.scenario, fireSettings, fireThermal)
        let generation = fireGeneration
        let weak = FireWeakModel(self)
        fireProgress = FireProgress(done: 0, of: members)
        fireTask = Task.detached(priority: .userInitiated) {
            let layer = FireSpread.layer(
                scene: scenario, source: source, thermal: thermal, settings: settings, members: members,
                preview: preview, stop: { Task.isCancelled },
                progress: { done in
                    Task { @MainActor in
                        guard let model = weak.value, model.fireGeneration == generation else { return }
                        model.fireProgress?.done = done
                    }
                })
            await MainActor.run {
                guard let model = weak.value, model.fireGeneration == generation, let layer else { return }
                model.fireTask = nil
                model.fireProgress = nil
                model.fireLayer = layer
                model.fireHour = min(model.fireHour, settings.hours)
                model.fireStatus = Self.fireStatusLine(layer, settings: settings)
                if model.envelopeColouring == .fire { model.applyEnvelopeDamageColours() }
            }
        }
    }

    /// Lets the fire go with the results it was drawn on (a new scene, or a run started).
    func dropFire() {
        fireTask?.cancel()
        fireTask = nil
        fireGeneration &+= 1
        fireProgress = nil
        fireLayer = nil
        fireStatus = ""
    }

    /// What the fire was drawn from and how long it took.
    nonisolated static func fireStatusLine(_ layer: FireSpread.Layer, settings: FireSpread.LayerSettings)
        -> String
    {
        var seeds: [String] = []
        if layer.fixedSeeds > 0 {
            seeds.append(layer.fixedSeeds == 1 ? "1 building alight" : "\(layer.fixedSeeds) buildings alight")
        }
        if settings.randomCount > 0 {
            seeds.append("\(min(settings.randomCount, layer.randomCandidates)) at random a draw")
        }
        if let flagged = layer.thermalFlagged {
            seeds.append(
                flagged == 0
                    ? "the surface heating flags none" : "\(flagged) of them flagged by the surface heating")
        }
        return String(
            format: "%d draws over %.0f h in %.2f s, from %@%@.", layer.members, settings.hours,
            layer.seconds,
            seeds.isEmpty ? "no building" : seeds.joined(separator: ", "),
            layer.preview ? ": a preview, the full \(fireDraws.full) follow" : "")
    }

    /// Whether building `id` is picked to start a fire.
    func firePicked(_ id: UUID) -> Bool { fireSettings.picked.contains(id) }

    /// Starts a fire in building `id`, or takes it away.
    func toggleFireSeed(_ id: UUID) {
        guard settings.scenario.object(id: id)?.envelope != nil else { return }
        if let index = fireSettings.picked.firstIndex(of: id) {
            fireSettings.picked.remove(at: index)
        } else {
            fireSettings.picked.append(id)
        }
    }

    /// Each building's colour code by its chance at the hour shown, the same on every side.
    func fireCodes() -> [UUID: Int] {
        guard let layer = fireLayer else { return [:] }
        let t = fireHour * 3600
        var codes: [UUID: Int] = [:]
        codes.reserveCapacity(layer.ids.count)
        for n in layer.ids.indices {
            let c = layer.chance(n, at: t, alight: fireShowsAlight)
            codes[layer.ids[n]] = EnvelopeChanceColour.code([(0, -1, c), (0, 1, c), (1, -1, c), (1, 1, c)])
        }
        return codes
    }

    /// The buildings set alight in every draw, outlined over the view while the fire is shown or
    /// seeds are being picked: those the last fire was drawn from, or those picked since.
    func fireSeedOutlines() -> [SIMD4<Float>] {
        guard showsEnvelopeDamage, envelopeColouring == .fire || firePicksSeeds else { return [] }
        var ids = Set(fireSettings.picked)
        if let layer = fireLayer {
            for seed in layer.ensemble.seeds where layer.ids.indices.contains(seed.building) {
                ids.insert(layer.ids[seed.building])
            }
        }
        let kind = Float(11)
        var lines: [SIMD4<Float>] = []
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let box = settings.scenario.object(id: id)?.bounds else { continue }
            let z = box.max.z + 0.5
            let corners = [
                SIMD3(box.min.x, box.min.y, z), SIMD3(box.max.x, box.min.y, z),
                SIMD3(box.max.x, box.max.y, z),
                SIMD3(box.min.x, box.max.y, z),
            ]
            for n in 0..<4 {
                lines += [SIMD4(corners[n], kind), SIMD4(corners[(n + 1) % 4], 0)]
            }
        }
        return lines
    }
}

/// A model held weakly, to be reached from the fire's draws and used on the main actor.
private final class FireWeakModel: @unchecked Sendable {
    weak var value: SimulationModel?
    init(_ value: SimulationModel) { self.value = value }
}
