import BlastCore
import BlastRender
import DocumentKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let bombCADProject = UTType(exportedAs: "dev.bombcad.project", conformingTo: .package)
}

/// Explicit persisted settings; independent of transient run-loop and selection state.
struct ProjectRunSettings: Codable, Equatable, Sendable {
    var resolution: String
    var detailedCharge: Bool
    var sharpShocks: Bool
    /// Levels of the shocks' refinement when more than one; nil, and left out of the file (and of
    /// a saved run's fingerprint, so that runs saved before it existed still match theirs), for one.
    var shockLevels: Int?
    /// The jump that refines the air, as a share of the pressure, when it is not the usual 0.1;
    /// nil, and left out of the file and the fingerprint, when it is.
    var shockThreshold: Float?
    /// True when each refined level takes only the substeps its own waves need; nil, and left out
    /// of the file and the fingerprint, when every level takes all of them.
    var adaptiveSubsteps: Bool?
    /// Gravity in the air when on; nil, and left out of the file and the fingerprint, when off.
    var gravity: Bool?
    /// True when the scene's terrain is cut through the cells (where the air is not refined); nil,
    /// and left out of the file and the fingerprint, for a staircase of whole cells, as every run
    /// over terrain was before cut cells, or for a scene without terrain.
    var terrainCutCells: Bool?
    /// Soft ground under the structures' debris, the soil's subgrade modulus in Pa/m; nil, and left
    /// out of the file and the fingerprint, for the hard ground.
    var groundStiffness: Float?
    /// What the ground is made of, for the crater and the share of the charge's energy the air
    /// keeps; nil, and left out of the file and the fingerprint, for the rigid ground.
    var ground: GroundType?
    /// How far below the surface the water table is, metres, where it cuts the crater's depth;
    /// nil, and left out of the file and the fingerprint, where it is deep or the ground rigid.
    /// The crater's alone: the air does not see it.
    var waterTable: Float?
    /// False when the structures' outline in the air counted each element at its centre, as every
    /// run did before 16 October 2026; true when by overlap; nil, and left out of the file and the
    /// fingerprint, where the scene has no structure, or for a run saved before then.
    var outlineByOverlap: Bool?
    /// True when envelopes' glazing breaks in the air and the blast fills their rooms, as new
    /// projects do since 17 October 2026; nil, and left out of the file and the fingerprint, for the
    /// one-way fill (so every run saved before then keeps its fill), or where no envelope is glazed.
    var ventsGlazing: Bool?
    /// True when the structures were brought to rest under their own weight before the blast
    /// (`SolverConfiguration.settlesStructures`), as since 17 October 2026; false when they took
    /// it as the run started; nil, and left out of the file and the fingerprint, where the scene
    /// has no structure, or for a run saved before then.
    var settlesStructures: Bool?
    var solidElementSize: Float
    var duration: Double

    init(settings: SimulationSettings, duration: Double) {
        resolution = settings.resolution.rawValue
        detailedCharge = settings.detailedCharge
        sharpShocks = settings.sharpShocks
        shockLevels = settings.shockLevels > 1 ? settings.shockLevels : nil
        shockThreshold = settings.shockThreshold != 0.1 ? settings.shockThreshold : nil
        adaptiveSubsteps = settings.sharpShocks && settings.adaptiveSubsteps ? true : nil
        gravity = settings.gravity ? true : nil
        terrainCutCells =
            settings.terrainCutCells && settings.scenario.terrain.map { !$0.isFlat } == true ? true : nil
        groundStiffness = settings.softGround ? settings.groundStiffness : nil
        ground = settings.ground == .rigid ? nil : settings.ground
        waterTable = settings.ground == .rigid ? nil : settings.waterTable
        outlineByOverlap = settings.scenario.structuralObjects.isEmpty ? nil : settings.outlineByOverlap
        // With gravity the run takes the fill, and says so.
        ventsGlazing = settings.ventsGlazing && settings.scenario.hasEnvelopePanes ? true : nil
        settlesStructures = settings.scenario.structuralObjects.isEmpty ? nil : settings.settlesStructures
        solidElementSize = settings.solidElementSize
        self.duration = duration
    }

    @MainActor
    init(model: SimulationModel) {
        self.init(settings: model.settings, duration: model.duration)
    }

    /// Whether runs of `scenario` under these settings vent its glazing: as recorded where it is
    /// glazed, where no key is the fill of every run saved before venting was the default; by
    /// default without glazing, so that glazing added later vents.
    func ventsGlazing(over scenario: Scenario) -> Bool { ventsGlazing ?? !scenario.hasEnvelopePanes }

    /// Whether a run of `scenario` under these settings cuts its terrain through the cells (where
    /// the air is not refined): as recorded over terrain, where nil is the staircase; by default
    /// without, so that terrain added later is cut.
    func cutsTerrain(over scenario: Scenario) -> Bool {
        terrainCutCells ?? !(scenario.terrain.map { !$0.isFlat } ?? false)
    }

    /// Whether a run of `scenario` under these settings counts the structures' outline by overlap:
    /// as recorded over structures, where nil (a run saved before 16 October 2026) is each element
    /// at its centre; by default without, so that structures added later are counted by overlap.
    func countsByOverlap(over scenario: Scenario) -> Bool {
        outlineByOverlap ?? scenario.structuralObjects.isEmpty
    }

    /// Whether a run of `scenario` under these settings settles its structures under their own
    /// weight first: as recorded over structures, where nil (a run saved before 17 October 2026)
    /// is not; by default it does, so that structures added later are settled.
    func settlesStructures(over scenario: Scenario) -> Bool {
        settlesStructures ?? scenario.structuralObjects.isEmpty
    }

    /// The craters the charges of `scenario` dig in the ground these settings name; none on the
    /// rigid ground. They form after the blast, so they are worked out from the scene, not the run.
    func craters(over scenario: Scenario) -> [CraterEstimate] {
        guard let ground else { return [] }
        return CraterEstimate.craters(of: scenario, ground: ground, waterTable: waterTable)
    }

    /// The grid as people say it: a preset's name ("medium") or its cells ("4 m").
    var gridName: String {
        guard let grid = Resolution(rawValue: resolution), !grid.isPreset else { return resolution }
        return Resolution.metres(grid.cellSize)
    }

    func validate() throws {
        guard Resolution(rawValue: resolution) != nil, solidElementSize.isFinite, solidElementSize > 0,
            duration.isFinite, duration > 0, shockLevels.map({ $0 == 2 }) ?? true,
            shockThreshold.map({ $0.isFinite && $0 > 0 && $0 <= 1 }) ?? true,
            groundStiffness.map({ $0.isFinite && $0 > 0 }) ?? true,
            waterTable.map({ $0.isFinite && $0 >= 0 && $0 <= 1000 }) ?? true
        else { throw ProjectFileError.invalid("Project simulation settings are invalid.") }
    }
}

struct ProjectViewSettings: Codable, Equatable, Sendable {
    var target: SIMD3<Float>
    var distance: Float
    var azimuth: Float
    var elevation: Float
    var fieldOfView: Float
    var displayMode: Int
    var pressureScale: Float
    var impulseScale: Float
    var waveScale: Float
    var decades: Float
    var showWave: Bool
    var waveOpacity: Float
    var showCharge: Bool

    init(camera: OrbitCamera, rendering: RenderSettings) {
        target = camera.target
        distance = camera.distance
        azimuth = camera.azimuth
        elevation = camera.elevation
        fieldOfView = camera.fieldOfView
        let view = rendering
        displayMode = view.mode.rawValue
        pressureScale = view.pressureScale
        impulseScale = view.impulseScale
        waveScale = view.waveScale
        decades = view.decades
        showWave = view.showWave
        waveOpacity = view.waveOpacity
        showCharge = view.showCharge
    }

    @MainActor
    init(model: SimulationModel) {
        self.init(camera: model.camera, rendering: model.renderSettings)
    }

    func validate() throws {
        let numbers = [
            target.x, target.y, target.z, distance, azimuth, elevation, fieldOfView,
            pressureScale, impulseScale, waveScale, decades, waveOpacity,
        ]
        guard numbers.allSatisfy(\.isFinite), distance > 0, fieldOfView > 0, fieldOfView < .pi,
            abs(elevation) < .pi / 2, pressureScale > 0, impulseScale > 0, waveScale > 0,
            decades > 0, decades <= 10, (0...1).contains(waveOpacity),
            DisplayMode(rawValue: displayMode) != nil
        else { throw ProjectFileError.invalid("Project camera or display settings are invalid.") }
    }

    var camera: OrbitCamera {
        var camera = OrbitCamera(target: target, distance: distance, azimuth: azimuth, elevation: elevation)
        camera.fieldOfView = fieldOfView
        return camera
    }

    var rendering: RenderSettings {
        var rendering = RenderSettings()
        rendering.mode = DisplayMode(rawValue: displayMode)!
        rendering.pressureScale = pressureScale
        rendering.impulseScale = impulseScale
        rendering.waveScale = waveScale
        rendering.decades = decades
        rendering.showWave = showWave
        rendering.waveOpacity = waveOpacity
        rendering.showCharge = showCharge
        return rendering
    }
}

struct ProjectDocument: FileDocument, Equatable, Sendable {
    static let readableContentTypes: [UTType] = [.bombCADProject]
    static let writableContentTypes: [UTType] = [.bombCADProject]

    var scenario: Scenario
    var savedRuns: [SavedSimulationRun] = []
    /// A cased charge's fragments to fly alongside each run, saved as `fragments.json`.
    var fragments: FragmentSpec?
    /// Ground points whose shaking to estimate alongside each run, saved as `groundShock.json`.
    var groundShock: GroundShockSpec?
    /// The fireball's thermal radiation to reckon alongside each run, saved as `thermal.json`.
    var thermal: ThermalSpec?
    /// The fireball's rise and cloud to follow after each run, saved as `cloud.json`.
    var cloud: CloudSpec?
    var runSettings: ProjectRunSettings?
    var viewSettings: ProjectViewSettings?
    var archive: ProjectArchive?
    var documentID: UUID

    /// New documents have complete inputs without allocating a GPU simulation.
    init(scenario: Scenario = SimulationSettings().scenario, preferences: AppPreferences = AppPreferences()) {
        self.scenario = scenario
        var settings = SimulationSettings()
        settings.scenario = scenario
        settings.resolution = Self.openingResolution(scenario, preferred: preferences.resolution)
        settings.detailedCharge = preferences.detailedCharge
        settings.sharpShocks = preferences.sharpShocks
        let crossing = (scenario.acousticCrossingTime * 100).rounded(.up) / 100
        runSettings = ProjectRunSettings(
            settings: settings, duration: scenario.structure == nil ? crossing : max(crossing, 0.25))
        var rendering = RenderSettings()
        if scenario.structure != nil {
            rendering.waveOpacity = 0.06
            rendering.pressureScale = 1000
        }
        viewSettings = ProjectViewSettings(camera: .framing(scenario), rendering: rendering)
        archive = nil
        documentID = UUID()
    }

    static func newProject(preferences: AppPreferences = .load()) -> Self {
        Self(preferences: preferences)
    }

    @MainActor
    init(model: SimulationModel) {
        savedRuns = model.savedRuns
        fragments = model.fragmentSpec
        groundShock = model.groundShockSpec
        thermal = model.thermalSpec
        cloud = model.cloudSpec
        scenario = model.sweep.baseline?.scenario ?? model.settings.scenario
        runSettings = model.sweep.baseline?.settings ?? ProjectRunSettings(model: model)
        viewSettings = ProjectViewSettings(model: model)
        archive = model.projectArchive
        documentID = model.projectDocumentID
    }

    init(configuration: ReadConfiguration) throws {
        try self.init(fileWrapper: configuration.file)
    }

    init(fileWrapper: FileWrapper) throws {
        if fileWrapper.isRegularFile, let data = fileWrapper.regularFileContents {
            try self.init(legacyJSON: data)
        } else {
            try self.init(archive: ProjectArchive(fileWrapper: fileWrapper))
        }
    }

    init(legacyJSON: Data) throws {
        guard legacyJSON.count <= ProjectArchive.maximumFileBytes else {
            throw ProjectFileError.invalid("Layout file is too large.")
        }
        let scenario: Scenario
        do {
            scenario = try JSONDecoder().decode(Scenario.self, from: legacyJSON)
        } catch let error as DecodingError {
            throw ProjectFileError.invalid(Self.jsonDecodingMessage(error))
        }
        self.init(scenario: scenario)
        try Self.validate(scenario)
    }

    private static func jsonDecodingMessage(_ error: DecodingError, file: String? = nil) -> String {
        func path(_ keys: [any CodingKey]) -> String {
            var result = ""
            for key in keys {
                if let index = key.intValue {
                    result += "[\(index)]"
                } else {
                    result += (result.isEmpty ? "" : ".") + key.stringValue
                }
            }
            return result.isEmpty ? "layout" : result
        }
        let label = file.map { "Project file \"\($0)\"" } ?? "Layout JSON"
        switch error {
        case .keyNotFound(let key, let context):
            return "\(label) is missing the required field \"\(path(context.codingPath + [key]))\"."
        case .typeMismatch(_, let context):
            return "\(label) has the wrong value type at \"\(path(context.codingPath))\"."
        case .valueNotFound(_, let context):
            return "\(label) requires a non-null value at \"\(path(context.codingPath))\"."
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty
                ? file.map { "Project file \"\($0)\" is not valid JSON." }
                    ?? "The layout file is not valid JSON."
                : "\(label) contains an invalid value at \"\(path(context.codingPath))\"."
        @unknown default:
            return file.map { "Project file \"\($0)\" could not be decoded. Check its format." }
                ?? "The layout JSON could not be decoded. Check its format."
        }
    }

    private static func decodeProjectJSON<T: Decodable>(_ type: T.Type, from data: Data, file: String) throws
        -> T
    {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw ProjectFileError.invalid(jsonDecodingMessage(error, file: file))
        }
    }

    init(archive: ProjectArchive) throws {
        try archive.validate()
        guard archive.manifest.documentType == "bombcad" else {
            throw ProjectFileError.invalid(
                "This project belongs to \(archive.manifest.documentType), not BombCAD.")
        }
        scenario = try ImportedSceneCodec.decode(archive)
        let run = try Self.decodeProjectJSON(
            ProjectRunSettings.self, from: archive.files["settings.json"]!, file: "settings.json")
        try Self.validate(scenario)
        try run.validate()
        try Self.validateGrid(scenario, resolution: Resolution(rawValue: run.resolution)!)
        runSettings = run
        if let data = archive.files["view.json"] {
            let view = try Self.decodeProjectJSON(ProjectViewSettings.self, from: data, file: "view.json")
            try view.validate()
            viewSettings = view
        }
        savedRuns = try SavedRunStore.read(archive)
        if let data = archive.files["fragments.json"] {
            let spec = try JSONDecoder().decode(FragmentSpec.self, from: data)
            try spec.validate()
            fragments = spec
        }
        if let data = archive.files["groundShock.json"] {
            let spec = try JSONDecoder().decode(GroundShockSpec.self, from: data)
            try spec.validate()
            groundShock = spec
        }
        if let data = archive.files["thermal.json"] {
            let spec = try JSONDecoder().decode(ThermalSpec.self, from: data)
            try spec.validate()
            thermal = spec
        }
        if let data = archive.files["cloud.json"] {
            let spec = try JSONDecoder().decode(CloudSpec.self, from: data)
            try spec.validate()
            cloud = spec
        }
        self.archive = archive
        documentID = archive.manifest.documentID
    }

    static func read(from url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else {
            throw ProjectFileError.invalid("Choose the project file itself, not a symbolic link.")
        }
        if values.isDirectory == true { return try Self(archive: ProjectArchive.read(from: url)) }
        guard let size = values.fileSize, size <= ProjectArchive.maximumFileBytes else {
            throw ProjectFileError.invalid("Layout file is too large.")
        }
        return try Self(legacyJSON: Data(contentsOf: url))
    }

    func makeArchive() throws -> ProjectArchive {
        try Self.validate(scenario)
        guard let runSettings else {
            throw ProjectFileError.invalid("Capture simulation settings before saving this project.")
        }
        try runSettings.validate()
        try Self.validateGrid(scenario, resolution: Resolution(rawValue: runSettings.resolution)!)
        var files = archive?.files ?? [:]
        var manifest =
            archive?.manifest
            ?? ProjectManifest(documentType: "bombcad", producer: "BombCAD", documentID: documentID)
        files["scene.json"] = try ImportedSceneCodec.encode(scenario, manifest: &manifest, files: &files)
        files["settings.json"] = try ProjectArchive.encodeJSON(runSettings)
        if let viewSettings {
            try viewSettings.validate()
            files["view.json"] = try ProjectArchive.encodeJSON(viewSettings)
        } else {
            files.removeValue(forKey: "view.json")
        }
        if let fragments {
            try fragments.validate()
            files["fragments.json"] = try ProjectArchive.encodeJSON(fragments)
        } else {
            files.removeValue(forKey: "fragments.json")
        }
        if let groundShock {
            try groundShock.validate()
            files["groundShock.json"] = try ProjectArchive.encodeJSON(groundShock)
        } else {
            files.removeValue(forKey: "groundShock.json")
        }
        if let thermal {
            try thermal.validate()
            files["thermal.json"] = try ProjectArchive.encodeJSON(thermal)
        } else {
            files.removeValue(forKey: "thermal.json")
        }
        if let cloud {
            try cloud.validate()
            files["cloud.json"] = try ProjectArchive.encodeJSON(cloud)
        } else {
            files.removeValue(forKey: "cloud.json")
        }
        try SavedRunStore.write(savedRuns, manifest: &manifest, files: &files)
        // Preserve embedded assets and unknown optional files when a project is re-saved.
        return try ProjectArchive(manifest: manifest, files: files)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try makeArchive().fileWrapper()
    }

    static func validate(_ scenario: Scenario) throws {
        try scenario.validateObjectOwnership()
        let sourceIDs = Set((scenario.importedModels ?? []).filter { $0.behavior == .deformable }.map(\.id))
        guard scenario.objects.compactMap(\.sourceModelID).allSatisfy({ sourceIDs.contains($0) }) else {
            throw ProjectFileError.invalid("A scene object references a missing imported source.")
        }
        guard
            [scenario.domainSize.x, scenario.domainSize.y, scenario.domainSize.z].allSatisfy({
                $0.isFinite && $0 > 0
            }),
            scenario.atmosphere.pressure.isFinite, scenario.atmosphere.pressure > 0,
            scenario.atmosphere.density.isFinite, scenario.atmosphere.density > 0,
            ([scenario.charge] + (scenario.additionalCharges ?? [])).allSatisfy({
                $0.mass.isFinite && $0.mass >= 0
                    && [$0.position.x, $0.position.y, $0.position.z].allSatisfy(\.isFinite)
            }),
            scenario.boxes.allSatisfy({
                [$0.min.x, $0.min.y, $0.min.z, $0.max.x, $0.max.y, $0.max.z].allSatisfy(\.isFinite)
                    && $0.size.x > 0 && $0.size.y > 0 && $0.size.z > 0
            }),
            scenario.structuralObjects.allSatisfy({
                $0.structure!.elementSize.isFinite && $0.structure!.elementSize > 0
            })
        else { throw ProjectFileError.invalid("Project geometry or atmosphere is invalid.") }
        for object in scenario.structuralObjects {
            let body = object.structure!
            guard body.materials.count <= StructureModel.maxMaterials,
                (body.solids + body.openings + body.supports).allSatisfy({ box in
                    [box.min.x, box.min.y, box.min.z, box.max.x, box.max.y, box.max.z].allSatisfy(\.isFinite)
                        && (0..<3).allSatisfy({ box.size[$0] > 0 })
                })
            else { throw ProjectFileError.invalid("Invalid structural geometry or material count.") }
            try body.baseAnchorage?.validate()
            guard body.supportAnchorages.count <= body.supports.count else {
                throw ProjectFileError.invalid("A connection references a missing support region.")
            }
            for law in body.supportAnchorages.compactMap({ $0 }) { try law.validate() }
            let parts = Set(
                (scenario.importedModels ?? []).filter { $0.behavior == .deformable }.flatMap { model in
                    model.source.parts.map { StructureModel.SourcePart(modelID: model.id, partID: $0.id) }
                })
            guard body.solidSourceParts.count <= body.solids.count,
                body.solidSourceParts.compactMap({ $0 }).allSatisfy({ parts.contains($0) })
            else { throw ProjectFileError.invalid("A structural region references a missing source part.") }
        }
        try scenario.validateStructuralSeparation()
        // The domain's sanity at the coarsest cells a run may take: a run's own resolution is
        // checked where its settings are (a district kilometres across is refused at 0.5 m).
        try validateGrid(scenario, resolution: Resolution(cellSize: Resolution.sizes.upperBound)!)
    }

    /// The cells a new project's runs start on: the preferred size, or, for a scene too large for
    /// it (more than `openingCells` cells or 2,048 along a side), the finest whole quarter metre
    /// that keeps within both, as fitting an open scene does.
    static let openingCells = 20_000_000

    static func openingResolution(_ scenario: Scenario, preferred: Resolution) -> Resolution {
        let size = scenario.domainSize
        let needed = max(
            max(size.x, size.y, size.z) / 2048,
            cbrt(size.x * size.y * size.z / Float(openingCells)))
        guard needed > preferred.cellSize else { return preferred }
        return Resolution(cellSize: min((needed * 4).rounded(.up) / 4, Resolution.sizes.upperBound))
            ?? preferred
    }

    /// Check before Grid performs Float-to-Int conversion and allocation-size arithmetic.
    /// The most cells a project's air grid may have.
    static let maximumCells = 128_000_000

    static func validateGrid(_ scenario: Scenario, resolution: Resolution) throws {
        var cells = 1
        for extent in [scenario.domainSize.x, scenario.domainSize.y, scenario.domainSize.z] {
            let dimension = max(1, (Double(extent) / Double(resolution.cellSize)).rounded())
            guard dimension.isFinite, dimension <= Double(maximumCells / cells) else {
                throw ProjectFileError.invalid(
                    "The project air grid is too large. Choose a coarser resolution or smaller domain.")
            }
            cells *= Int(dimension)
        }
    }
}
