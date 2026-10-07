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
    var solidElementSize: Float
    var duration: Double

    init(settings: SimulationSettings, duration: Double) {
        resolution = settings.resolution.rawValue
        detailedCharge = settings.detailedCharge
        sharpShocks = settings.sharpShocks
        solidElementSize = settings.solidElementSize
        self.duration = duration
    }

    @MainActor
    init(model: SimulationModel) {
        self.init(settings: model.settings, duration: model.duration)
    }

    func validate() throws {
        guard Resolution(rawValue: resolution) != nil, solidElementSize.isFinite, solidElementSize > 0,
            duration.isFinite, duration > 0
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
    var runSettings: ProjectRunSettings?
    var viewSettings: ProjectViewSettings?
    var archive: ProjectArchive?
    var documentID: UUID

    /// New documents have complete inputs without allocating a GPU simulation.
    init(scenario: Scenario = SimulationSettings().scenario, preferences: AppPreferences = AppPreferences()) {
        self.scenario = scenario
        var settings = SimulationSettings()
        settings.scenario = scenario
        settings.resolution = preferences.resolution
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
        scenario = model.settings.scenario
        runSettings = ProjectRunSettings(model: model)
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
        self.init(scenario: try JSONDecoder().decode(Scenario.self, from: legacyJSON))
        try Self.validate(scenario)
    }

    init(archive: ProjectArchive) throws {
        try archive.validate()
        guard archive.manifest.documentType == "bombcad" else {
            throw ProjectFileError.invalid(
                "This project belongs to \(archive.manifest.documentType), not BombCAD.")
        }
        scenario = try ImportedSceneCodec.decode(archive)
        let run = try JSONDecoder().decode(ProjectRunSettings.self, from: archive.files["settings.json"]!)
        try Self.validate(scenario)
        try run.validate()
        try Self.validateGrid(scenario, resolution: Resolution(rawValue: run.resolution)!)
        runSettings = run
        if let data = archive.files["view.json"] {
            let view = try JSONDecoder().decode(ProjectViewSettings.self, from: data)
            try view.validate()
            viewSettings = view
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
        }
        // Preserve embedded assets and unknown optional files when a project is re-saved.
        return try ProjectArchive(manifest: manifest, files: files)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try makeArchive().fileWrapper()
    }

    private static func validate(_ scenario: Scenario) throws {
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
            scenario.structure.map({ $0.elementSize.isFinite && $0.elementSize > 0 }) ?? true
        else { throw ProjectFileError.invalid("Project geometry or atmosphere is invalid.") }
        try validateGrid(scenario, resolution: .coarse)
    }

    /// Check before Grid performs Float-to-Int conversion and allocation-size arithmetic.
    private static func validateGrid(_ scenario: Scenario, resolution: Resolution) throws {
        let maximumCells = 128_000_000
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
