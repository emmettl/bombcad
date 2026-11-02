import BlastCore
import BlastRender
import Foundation
import Observation
import simd

/// Whether a window shows the explorer or the workbench (the Run and Edit sidebar).
enum WindowMode: String, Sendable {
    case explore, workbench

    /// Remembered as the user last chose; the explorer until then, so that the first launch opens on it.
    static let key = "explorer.mode"

    static var remembered: WindowMode {
        WindowMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .explore
    }

    static func remember(_ mode: WindowMode) { UserDefaults.standard.set(mode.rawValue, forKey: key) }
}

/// The explorer (emmettl/bombcad-work#114; docs/explorer.md): a first experience for someone who knows
/// nothing about blast. A built-in scene, a charge placed and sized, the wave played with captions, then
/// the glass, the walls, the people and the fire, each in plain words with how sure the model is; and
/// comparisons against a pinned picture. It drives the window's `SimulationModel` through what is
/// already live: the quick estimate, the learned response, the what-ifs, the live wave and the fire.
@MainActor
@Observable
final class ExplorerModel {
    let model: SimulationModel

    /// The scene on screen; nil while the scenes are offered.
    private(set) var scene: ExplorerScene?
    /// The layer shown, as the strip steps through them.
    var layer = ExplorerWords.Layer.wave {
        didSet { if layer != oldValue { applyLayer() } }
    }
    private(set) var isOpening = false
    private(set) var problem: String?
    /// Where the scene's first charge stood, scene metres: the named places are offsets from it.
    private(set) var origin: SIMD3<Float>?
    /// The safety rings over the view.
    var showsRings = false {
        didSet { model.renderSettings.showBlastHazards = showsRings }
    }

    /// A picture pinned to compare the next with, and the settings to put back.
    struct Pinned: Equatable {
        var snapshot: ExplorerSnapshot
        var mass: Float
        var charge: SIMD3<Float>
        var whatIf: LiveResponse.WhatIf
    }

    private(set) var pinned: Pinned?
    /// Whether the view colours each building better, the same or worse than the pinned picture.
    var showsChange = false {
        didSet { if showsChange != oldValue { applyLayer() } }
    }

    /// The comparisons offered, each a change from the pinned picture.
    enum Try: String, CaseIterable, Identifiable {
        case twiceTheCharge, behindABuilding, glassWithFilm
        var id: String { rawValue }
        var title: String {
            switch self {
            case .twiceTheCharge: "Twice the charge"
            case .behindABuilding: "Behind a building"
            case .glassWithFilm: "Glass with film"
            }
        }
        var summary: String {
            switch self {
            case .twiceTheCharge: "Double the charge and see how much further the windows break."
            case .behindABuilding: "Move the charge behind the brick terrace and see the shadow it casts."
            case .glassWithFilm:
                "Give every window security film and see how much less glass flies into the rooms."
            }
        }
    }

    private(set) var tried: Try?

    /// The film the comparison gives every window: 8 mil, wet glazed into its frame.
    static let film = LiveResponse.Glass.filmed(.mils(8, anchorage: .wetGlazed))

    /// The system's Reduce Motion: the wave shown whole, not played.
    @ObservationIgnored var reduceMotion = false
    @ObservationIgnored private var captionCache: (version: Int, captions: [ExplorerCaption])?

    init(model: SimulationModel) {
        self.model = model
    }

    // MARK: Scenes

    /// The scene laid out as a project, as File ▸ New District lays a map's out, on the scene's own cells.
    nonisolated static func document(for scene: ExplorerScene, memory: Int) throws -> ProjectDocument {
        var layout = DistrictLayout(
            buildings: scene.buildings(), charge: scene.charge, mass: scene.defaultMassKg)
        layout.keepsOutlines = true
        layout.attributions = [scene.source]
        let preview = try NewDistrictModel.preview(
            layout, radius: scene.radiusM, clearFaces: true, cellSize: scene.cellSizeM, ground: .rigid,
            memory: memory)
        var document = preview.document
        document.scenario.name = scene.title
        return document
    }

    /// Opens `scene`: laid out away from the main thread, then the quick estimate and the wave, which
    /// plays by itself.
    func open(_ scene: ExplorerScene) async {
        guard !isOpening else { return }
        isOpening = true
        problem = nil
        pinned = nil
        tried = nil
        showsChange = false
        let memory = AdvisorMachine.thisMac.memory
        let result = await Task.detached(priority: .userInitiated) {
            Result { try Self.document(for: scene, memory: memory) }
        }.value
        switch result {
        case .failure(let error):
            problem = "Could not lay out \(scene.title.lowercased()): \(error)"
            isOpening = false
            return
        case .success(let document):
            model.open(document)
        }
        self.scene = scene
        // The solver is the referee, not the experience: no close calls run on it here.
        model.refinesCloseCalls = false
        model.quickEstimateWhatIf = LiveResponse.WhatIf()
        model.isPlacingCharge = true
        while model.isLoadingInputs { try? await Task.sleep(for: .milliseconds(20)) }
        let charge = model.settings.chargePosition
        origin = charge
        let size = model.settings.scenario.domainSize
        model.camera = OrbitCamera(
            target: SIMD3(charge.x, charge.y, 0), distance: 0.7 * max(size.x, size.y), azimuth: -1.9,
            elevation: 0.95)
        model.quickEstimate()
        model.liveWaveShown = true
        applyLayer()
        isOpening = false
        await replayWhenReady()
    }

    /// Back to the scenes' cards.
    func close() {
        model.liveWaveShown = false
        model.explorerColouring = nil
        scene = nil
        origin = nil
        pinned = nil
        tried = nil
    }

    // MARK: The charge

    /// The charge put at `place`, then the wave played again.
    func put(at place: ExplorerScene.Place) {
        guard let origin else { return }
        model.placeCharge(at: SIMD3(origin.x + place.offset.x, origin.y + place.offset.y, origin.z))
        Task { await replayWhenReady() }
    }

    /// The named place the charge stands at, if it stands at one.
    var place: ExplorerScene.Place? {
        guard let origin, let scene else { return nil }
        let at = model.settings.chargePosition
        return scene.places.first {
            simd_length(SIMD2(at.x - origin.x, at.y - origin.y) - $0.offset) < 1
        }
    }

    /// The charge moved `east` and `north` metres, for the keyboard.
    func nudge(east: Float, north: Float) {
        let at = model.settings.chargePosition
        model.placeCharge(at: SIMD3(at.x + east, at.y + north, at.z))
    }

    /// The charge given `kg` as a choice, its full estimate following.
    func setMass(_ kg: Float) { model.setChargeMass(kg) }

    // MARK: The wave

    /// The wave's captions, worked out once a field.
    var captions: [ExplorerCaption] {
        guard let field = model.liveWave else { return [] }
        if let cache = captionCache, cache.version == model.liveWaveVersion { return cache.captions }
        let captions = ExplorerWords.captions(field)
        captionCache = (model.liveWaveVersion, captions)
        return captions
    }

    /// The caption at the wave's time.
    var caption: String? {
        guard model.drawsLiveWave else { return nil }
        return ExplorerWords.caption(captions, at: model.liveWaveTime)?.text
    }

    /// The speed at which the wave lasts closest to five seconds.
    static func speed(for end: Double) -> LiveWaveSpeed {
        LiveWaveSpeed.allCases.min { abs(log(end / $0.rawValue / 5)) < abs(log(end / $1.rawValue / 5)) }
            ?? .tenth
    }

    /// Plays the wave from the start once its field is worked out for the charge where it is; with
    /// Reduce Motion, shows it whole instead.
    func replayWhenReady() async {
        let start = ContinuousClock.now
        while model.liveWaveShown,
            model.liveWave == nil || model.liveWaveInFlight
                || model.liveWaveShownFor?.charge != model.settings.chargePosition
        {
            guard ContinuousClock.now - start < .seconds(10) else { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        replay()
    }

    func replay() {
        guard model.liveWave != nil else { return }
        if reduceMotion {
            model.scrubLiveWave(to: model.liveWaveEnd)
            return
        }
        model.setLiveWaveSpeed(Self.speed(for: model.liveWaveEnd))
        model.scrubLiveWave(to: 0)
        model.playLiveWave()
    }

    // MARK: Layers

    /// The model coloured for the layer shown: the wave alone on plain buildings, or the buildings by
    /// their glass, walls, people or fire; by what changed against the pinned picture when asked.
    func applyLayer() {
        guard scene != nil else { return }
        let change = showsChange ? pinned.map(\.snapshot) : nil
        switch layer {
        case .wave:
            model.explorerColouring = nil
            model.showsEnvelopeDamage = false
        case .glass:
            model.showsEnvelopeDamage = true
            model.envelopeColouring = .blownOut
            model.explorerColouring =
                change.map { .change($0, tried == .glassWithFilm ? .thrown : .glass) } ?? .glass
        case .walls:
            model.showsEnvelopeDamage = true
            model.envelopeColouring = .wallsModerate
            model.explorerColouring = change.map { .change($0, .walls) }
        case .people:
            model.showsEnvelopeDamage = true
            model.envelopeColouring = .peopleHurt
            model.explorerColouring = nil
        case .fire:
            if !model.fireSettings.hasSeeds {
                var fire = model.fireSettings
                fire.nearChargeM = 40
                fire.wind = FireSpread.Wind(speedMS: 4, fromDegrees: 240)
                fire.hours = 12
                model.fireSettings = fire
            }
            model.fireHour = 12
            model.showsEnvelopeDamage = true
            model.envelopeColouring = .fire
            model.explorerColouring = nil
        }
    }

    /// Whether the full estimate is still on its way after a preview.
    var isRefining: Bool { model.estimatingEnvelopeDamage || model.envelopeEstimateIsPreview }

    /// The layer's figure in words: how far the windows break, or how the people compare.
    var finding: String? {
        guard !model.envelopeGlassChances.isEmpty else { return nil }
        switch layer {
        case .glass: return model.explorerSnapshot.reach.sentence
        case .people: return model.peopleComparison.map(explorerPeopleChange)
        default: return nil
        }
    }

    // MARK: Pinned and compared

    /// Pins the picture on screen, the people's with it.
    func pin() {
        pinned = Pinned(
            snapshot: model.explorerSnapshot, mass: model.settings.chargeMass,
            charge: model.settings.chargePosition,
            whatIf: model.quickEstimateWhatIf)
        model.pinPeopleBaseline()
        applyLayer()
    }

    func unpin() {
        pinned = nil
        tried = nil
        showsChange = false
        model.peopleBaseline = nil
        applyLayer()
    }

    /// Pins the picture, then makes the one change `t` asks for.
    func run(_ t: Try) {
        guard let scene, !model.envelopeGlassChances.isEmpty else { return }
        if tried != nil, let pinned { restore(pinned) }
        pin()
        tried = t
        switch t {
        case .twiceTheCharge:
            setMass(model.settings.chargeMass * 2)
        case .behindABuilding:
            put(at: scene.behindABuilding)
        case .glassWithFilm:
            model.quickEstimateWhatIf.glass = Self.film
        }
        layer = .glass
        showsChange = t != .twiceTheCharge
        applyLayer()
    }

    /// Puts the pinned settings back.
    func putBack() {
        guard let pinned else { return }
        restore(pinned)
        tried = nil
        showsChange = false
        applyLayer()
    }

    private func restore(_ pinned: Pinned) {
        model.quickEstimateWhatIf = pinned.whatIf
        model.setChargeMass(pinned.mass)
        model.placeCharge(at: pinned.charge)
    }

    /// What changed against the pinned picture, in words; nil without one, or until the estimate is in.
    var comparison: String? {
        guard let pinned, !model.envelopeGlassChances.isEmpty else { return nil }
        let now = model.explorerSnapshot
        var lines: [String] = []
        if tried == .twiceTheCharge || now.massKg != pinned.mass {
            lines.append(
                ExplorerReach.scaled(
                    from: pinned.snapshot.reach, to: now.reach, ratio: Double(now.massKg / pinned.mass)))
        }
        if tried == .glassWithFilm {
            lines.append(pinned.snapshot.change(to: now, measure: .thrown).sentence)
            // Film holds the pieces; the people estimate counts the panes broken, which film does not change.
            lines.append(ExplorerWords.filmAndPeople)
        } else {
            if tried != .twiceTheCharge {
                lines.append(
                    pinned.snapshot.change(to: now, measure: layer == .walls ? .walls : .glass).sentence)
            }
            if let people = model.peopleComparison { lines.append(explorerPeopleChange(people)) }
        }
        return lines.joined(separator: " ")
    }

    // MARK: For VoiceOver

    /// The view's description in the explorer: the scene, the charge, the layer and what it shows.
    var viewSummary: String {
        guard let scene else { return "No scene yet: choose one beside the view." }
        var parts = [
            scene.title,
            ExplorerWords.massText(model.settings.chargeMass) + " of TNT "
                + (place.map { $0.name.prefix(1).lowercased() + $0.name.dropFirst() } ?? "where it was put"),
            "showing \(layer.title.lowercased())",
        ]
        if let caption, model.liveWavePlaying { parts.append(caption) }
        if let finding { parts.append(finding) }
        return parts.joined(separator: "; ")
    }
}
