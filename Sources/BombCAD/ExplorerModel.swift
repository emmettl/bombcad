import BlastCore
import BlastRender
import Foundation
import Observation
import SwiftUI
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
        case twiceTheCharge, behindABuilding, glassWithFilm, laminatedGlass, aWallInFront
        var id: String { rawValue }
        var title: String {
            switch self {
            case .twiceTheCharge: "Twice the charge"
            case .behindABuilding: "Behind a building"
            case .glassWithFilm: "Glass with film"
            case .laminatedGlass: "Laminated glass"
            case .aWallInFront: "A wall in front"
            }
        }

        /// Whether it changes the glass, and so is judged by the glass thrown into the rooms.
        var isGlass: Bool { self == .glassWithFilm || self == .laminatedGlass }
        /// What it does, in `scene`: its place behind a building named.
        func summary(in scene: ExplorerScene?) -> String {
            switch self {
            case .twiceTheCharge: "Double the charge and see how much further the windows break."
            case .behindABuilding:
                scene == .street
                    ? "Move the charge into the back lane behind the shops and see the shadow they cast."
                    : "Move the charge behind the brick terrace and see the shadow it casts."
            case .glassWithFilm:
                "Give every window security film and see how much less glass flies into the rooms."
            case .laminatedGlass:
                "Give every window laminated glass, held together by a layer of plastic."
            case .aWallInFront:
                scene?.standOff.map {
                    "Put a wall 3 m tall just in front of \($0.building.prefix(1).lowercased() + $0.building.dropFirst()), then drag it."
                } ?? "Put a wall 3 m tall in front of the charge, then drag it."
            }
        }
    }

    private(set) var tried: Try?

    /// The film the comparison gives every window: 8 mil, wet glazed into its frame.
    nonisolated static let film = LiveResponse.Glass.filmed(.mils(8, anchorage: .wetGlazed))
    /// The laminated glass it gives: the façade laminate the what-ifs offer.
    nonisolated static let laminated = LiveResponse.Glass.laminated(.facade)

    /// The glass the protections offer, in plain words.
    enum GlassChoice: String, CaseIterable, Identifiable {
        case asBuilt, filmed, laminated
        var id: String { rawValue }
        var title: String {
            switch self {
            case .asBuilt: "As built"
            case .filmed: "With film"
            case .laminated: "Laminated"
            }
        }
        var glass: LiveResponse.Glass? {
            switch self {
            case .asBuilt: nil
            case .filmed: ExplorerModel.film
            case .laminated: ExplorerModel.laminated
            }
        }
    }

    /// How much coarser the wave's cells are while dragging over a plan of more than
    /// `SimulationModel.liveWaveDragCells` (the workbench's is 2).
    static let dragCoarsening: Float = 4

    /// The system's Reduce Motion: the wave shown whole, not played.
    @ObservationIgnored var reduceMotion = false
    @ObservationIgnored private var captionCache: (version: Int, captions: [ExplorerCaption])?

    init(model: SimulationModel) {
        self.model = model
    }

    // MARK: Scenes

    /// The scene laid out as a project, as File ▸ New District lays a map's out: on the scene's own
    /// cells, or, for Beirut's, the advisor's for this Mac, from its downloaded `asset`.
    nonisolated static func document(for scene: ExplorerScene, memory: Int, asset: URL? = nil) throws
        -> ProjectDocument
    {
        let district = try scene.district(asset: asset)
        var layout = DistrictLayout(
            buildings: district.buildings, charge: scene.charge, mass: scene.defaultMassKg)
        layout.keepsOutlines = true
        layout.ground = district.ground
        layout.attributions =
            scene == .beirut ? ExplorerScene.Beirut.attributions : [scene.source]
        let preview = try NewDistrictModel.preview(
            layout, radius: scene.radiusM, clearFaces: true, cellSize: scene.cellSizeM, ground: scene.ground,
            memory: memory)
        var document = preview.document
        document.scenario.name = scene.title
        return document
    }

    // MARK: Beirut's download

    /// Where Beirut's file is kept: `BOMBCAD_EXPLORER_BEIRUT` if set, else Application Support.
    static var beirutURL: URL {
        if let path = ProcessInfo.processInfo.environment["BOMBCAD_EXPLORER_BEIRUT"] {
            return URL(filePath: path)
        }
        return URL.applicationSupportDirectory.appending(
            path: "BombCAD/Explorer/\(ExplorerScene.Beirut.fileName)")
    }

    static var beirutItem: LearnedFieldDownload.Item {
        var item = LearnedFieldDownload.Item(ExplorerScene.Beirut.Release.asset, to: beirutURL)
        item.readsAsWeights = false
        return item
    }

    /// Whether Beirut's file is here, with its pinned hash; one given by `BOMBCAD_EXPLORER_BEIRUT` is
    /// taken as it is.
    var beirutHere: Bool {
        ProcessInfo.processInfo.environment["BOMBCAD_EXPLORER_BEIRUT"] != nil
            ? FileManager.default.fileExists(atPath: Self.beirutURL.path) : Self.beirutItem.isInPlace
    }

    /// The live wave's refinement, if its weights are still to be fetched: offered under the same prompt.
    var waveWeightsWanted: LearnedFieldDownload.Item? {
        model.liveWaveLearnedWeightsMissing && model.liveWaveLearnedWeightsURL == model.liveWaveLearnedHome
            ? model.liveWaveLearnedReleaseItem : nil
    }

    /// Asking whether to download Beirut (and the wave's weights); the download under way; why it failed.
    var offersBeirutDownload = false
    private(set) var beirutDownloadInFlight = false
    private(set) var beirutStatus = ""
    @ObservationIgnored private var beirutTask: Task<Void, Never>?

    /// The one prompt's words: what each file is, and their size together.
    var beirutOffer: String {
        var text = ExplorerScene.Beirut.Release.offer
        if let weights = waveWeightsWanted {
            text +=
                " With it, the live wave's learned refinement, "
                + LearnedField.Release.megabytes(weights.bytes)
                + ", which sharpens the wave within about 1 km of the charge."
        }
        return text
    }

    var beirutDownloadTitle: String {
        let bytes = ExplorerScene.Beirut.Release.asset.bytes + (waveWeightsWanted?.bytes ?? 0)
        return "Download " + LearnedField.Release.megabytes(bytes)
    }

    /// The user clicked Download: Beirut's file and, if wanted, the wave's weights, each checked
    /// against its pinned hash; then the scene opens.
    func downloadBeirut() {
        offersBeirutDownload = false
        guard !beirutDownloadInFlight else { return }
        let items = [Self.beirutItem] + (waveWeightsWanted.map { [$0] } ?? [])
        beirutDownloadInFlight = true
        beirutStatus = "Downloading Beirut's port…"
        beirutTask = Task { [weak self] in
            let result: Result<[URL], Error>
            do {
                result = .success(try await LearnedFieldDownload.install(items))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.beirutDownloadInFlight = false
            self.beirutTask = nil
            switch result {
            case .success:
                self.beirutStatus = ""
                if items.count > 1 { self.model.setLiveWaveLearned(true) }
                await self.open(.beirut)
            case .failure(let error):
                self.beirutStatus = "Beirut's port could not be downloaded: \(error)"
            }
        }
    }

    func cancelBeirutDownload() { beirutTask?.cancel() }

    /// Opens `scene`: laid out away from the main thread, then the quick estimate and the wave, which
    /// plays by itself.
    func open(_ scene: ExplorerScene) async {
        guard !isOpening else { return }
        // Beirut's comes from a download, asked for first.
        if !scene.isBuiltIn, !beirutHere {
            offersBeirutDownload = true
            return
        }
        isOpening = true
        problem = nil
        pinned = nil
        tried = nil
        showsChange = false
        let memory = AdvisorMachine.thisMac.memory
        let asset = scene.isBuiltIn ? nil : Self.beirutURL
        let result = await Task.detached(priority: .userInitiated) {
            Result { try Self.document(for: scene, memory: memory, asset: asset) }
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
        // Each scene starts as the flow does, with the wave.
        layer = .wave
        // The solver is the referee, not the experience: no close calls run on it here.
        model.refinesCloseCalls = false
        model.quickEstimateWhatIf = LiveResponse.WhatIf()
        model.isPlacingCharge = true
        while model.isLoadingInputs { try? await Task.sleep(for: .milliseconds(20)) }
        let charge = model.settings.chargePosition
        origin = charge
        let size = model.settings.scenario.domainSize
        // No solver here: the air's starting ball of hot gas is not drawn, and the charge's marker is
        // sized to be seen over a district, in colours apart from the warm scale's and the wave's.
        model.renderSettings.showWave = false
        model.renderSettings.chargeMarkerRadius = max(1.5, 0.004 * max(size.x, size.y))
        model.renderSettings.chargeMarkerOutlined = true
        if let opening = scene.opening { AccessibilityNotification.Announcement(opening).post() }
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
        model.leaveExplorer()
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

    // MARK: Protections (emmettl/bombcad-work#117)

    /// The wall's heights offered, m.
    static let wallHeights: [Float] = [2, 3, 4]
    static let wallLengthM: Float = 30

    /// The every-window glass chosen.
    var glassChoice: GlassChoice {
        get {
            GlassChoice.allCases.first { $0.glass == model.quickEstimateWhatIf.glass } ?? .asBuilt
        }
        set { model.quickEstimateWhatIf.glass = newValue.glass }
    }

    var hasWall: Bool { model.quickEstimateWhatIf.barrier != nil }

    /// A wall put 6 m in front of the scene's protected building, between it and the charge (where a
    /// wall shelters most: within one or two of its heights behind it), or 15 m in front of the charge
    /// where the scene has none; the view's drag then moves it.
    func addWall(height: Float = 3) {
        let charge = SIMD2(model.settings.chargePosition.x, model.settings.chargePosition.y)
        let target: SIMD2<Float>
        if let origin, let standOff = scene?.standOff {
            target = SIMD2(origin.x, origin.y) + standOff.from
        } else if let origin {
            target = SIMD2(origin.x, origin.y) + SIMD2(0, 30)
        } else {
            target = charge + SIMD2(0, 30)
        }
        let distance = simd_length(target - charge)
        let share: Float =
            scene?.standOff == nil
            ? (distance > 1 ? min(15 / distance, 0.5) : 0.5)
            : (distance > 12 ? (distance - 6) / distance : 0.5)
        model.quickEstimateWhatIf.barrier = .across(
            from: charge, to: distance > 1 ? target : charge + SIMD2(0, 30), at: share,
            lengthM: Self.wallLengthM, heightM: height)
        model.dragsBarrier = true
    }

    func removeWall() {
        model.quickEstimateWhatIf.barrier = nil
        model.dragsBarrier = false
    }

    var wallHeight: Float {
        get { model.quickEstimateWhatIf.barrier?.heightM ?? 3 }
        set { model.quickEstimateWhatIf.barrier?.heightM = newValue }
    }

    /// A drag in the view moves the wall, not the charge.
    var dragsWall: Bool {
        get { model.dragsBarrier }
        set { model.dragsBarrier = newValue && hasWall }
    }

    /// The wall moved `east` and `north` metres, for the keyboard.
    func nudgeWall(east: Float, north: Float) {
        guard let barrier = model.quickEstimateWhatIf.barrier else { return }
        model.moveBarrier(to: barrier.centre + SIMD2(east, north))
    }

    /// The wall turned a quarter.
    func turnWall() { model.quickEstimateWhatIf.barrier?.alongX.toggle() }

    /// Whether the quick estimate credits the shelter close behind a wall (the proposed term).
    var countsShelter: Bool {
        get { model.quickEstimateBarrierShielding }
        set { model.quickEstimateBarrierShielding = newValue }
    }

    /// Whether the people are hurt by the glass thrown into their rooms (proposed), not by the panes broken.
    var countsThrownGlass: Bool {
        get { model.occupancy.glass == .thrownGlass }
        set { model.occupancy.glass = newValue ? .thrownGlass : .panesBroken }
    }

    /// How far the charge stands from the protected building along the scene's stand-off line, m; nil
    /// where the scene has none.
    var standOff: Float? {
        guard let origin, let line = scene?.standOff else { return nil }
        let at = SIMD2(model.settings.chargePosition.x, model.settings.chargePosition.y)
        let start = SIMD2(origin.x, origin.y) + line.from
        return min(max(simd_dot(at - start, line.along), line.range.lowerBound), line.range.upperBound)
    }

    /// The charge put `metres` from the protected building along the stand-off line (as a slider moves
    /// it: the preview follows, the full estimate on let-go).
    func setStandOff(_ metres: Float) {
        guard let origin, let line = scene?.standOff else { return }
        let point = SIMD2(origin.x, origin.y) + line.from + metres * line.along
        model.settings.chargePosition.x = point.x
        model.settings.chargePosition.y = point.y
        model.settingsChanged()
        model.explorerLines = ringLines + standOffLines
    }

    /// The stand-off line across the charge's path, drawn while the scene has one: square to the line,
    /// 40 m long, through the charge.
    var standOffLines: [SIMD4<Float>] {
        guard scene?.standOff != nil, let line = scene?.standOff, showsStandOff else { return [] }
        let at = model.settings.chargePosition
        let across = SIMD2(-line.along.y, line.along.x) * 20
        let z = (model.settings.scenario.terrain?.height(at: at) ?? 0) + 0.3
        return [SIMD4(at.x - across.x, at.y - across.y, z, 2), SIMD4(at.x + across.x, at.y + across.y, z, 0)]
    }
    var showsStandOff = false {
        didSet { model.explorerLines = ringLines + standOffLines }
    }

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
        // The wave drawn on its own layer alone, so that its paint does not tint the others' colours.
        model.explorerHidesLiveWave = layer != .wave
        model.explorerLines = ringLines + standOffLines
        model.explorerWarmRamp = true
        // A drag keeps up: no preview where the layer shows none, and over a large plan the wave on
        // cells four times its own, unrefined, until the charge is let go.
        model.previewsWhileDragging = layer != .wave
        model.liveWaveDragCoarsening = Self.dragCoarsening
        model.liveWaveDragRefines = false
        switch layer {
        case .wave:
            model.explorerColouring = nil
            model.showsEnvelopeDamage = false
        case .glass:
            model.showsEnvelopeDamage = true
            model.envelopeColouring = .blownOut
            model.explorerColouring =
                change.map { .change($0, tried?.isGlass == true ? .thrown : .glass) } ?? .glass
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

    /// The pinned picture's reach: how far windows broke then, or were blown in where they broke right
    /// across the scene; nil without one.
    var pinnedReach: Double? {
        guard let reach = pinned?.snapshot.reach else { return nil }
        if let windows = reach.windowsBreakM, !reach.beyondScene { return windows }
        return reach.blownInM
    }

    /// The faint ring at the pinned picture's reach, round where its charge stood.
    var ringLines: [SIMD4<Float>] {
        guard let pinned, let radius = pinnedReach, layer == .glass || layer == .wave else { return [] }
        let terrain = model.settings.scenario.terrain
        let centre = SIMD2(pinned.charge.x, pinned.charge.y)
        let pieces = max(64, min(Int(2 * Double.pi * radius / 2), 1_024))
        var lines: [SIMD4<Float>] = []
        func at(_ n: Int) -> SIMD3<Float> {
            let angle = 2 * Float.pi * Float(n) / Float(pieces)
            let p = centre + Float(radius) * SIMD2(cos(angle), sin(angle))
            return SIMD3(p.x, p.y, (terrain?.height(at: SIMD3(p.x, p.y, 0)) ?? 0) + 0.5)
        }
        // Kind 1, the pale thin line the cloud's outlines take.
        for n in 0..<pieces {
            let (p, q) = (at(n), at(n + 1))
            lines += [SIMD4(p, 1), SIMD4(q, 0)]
        }
        return lines
    }

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
            guard let place = scene.behindABuilding else { return }
            put(at: place)
        case .glassWithFilm:
            model.quickEstimateWhatIf.glass = Self.film
        case .laminatedGlass:
            model.quickEstimateWhatIf.glass = Self.laminated
        case .aWallInFront:
            addWall()
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
        if pinned.whatIf.barrier == nil { model.dragsBarrier = false }
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
        if tried?.isGlass == true {
            lines.append(pinned.snapshot.change(to: now, measure: .thrown).sentence)
            // Film holds the pieces. Counting the glass thrown, the people show it; counting the panes
            // broken, which film does not change, they cannot.
            if countsThrownGlass {
                lines.append(ExplorerWords.filmAndPeopleThrown)
                if let people = model.peopleComparison { lines.append(explorerPeopleChange(people)) }
            } else {
                lines.append(ExplorerWords.filmAndPeople)
            }
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
