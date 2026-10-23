import BlastCore
import BlastModel
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

/// What a kept timeline weighs for the spatial viewer (emmettl/bombcad-work#43): a scene run with
/// its thermal radiation and its cloud, kept with its recording and saved as a project, then each
/// frame's bytes taken apart by what they carry. The made-up district is the scale in question;
/// the buildings across a street are a small scene with every layer, to try the viewer on. Set
/// `BOMBCAD_VIEWER_STUDY` to a folder for the projects and the reports; long, so not part of the
/// suite. The saved projects are what `BombCAD serve --share` hands a viewer.
@MainActor @Suite("What a kept timeline weighs", .serialized)
struct SpatialViewerStudyTests {
    nonisolated static let output = ProcessInfo.processInfo.environment["BOMBCAD_VIEWER_STUDY"]

    /// The made-up district (uniform air, as the timeline cost study ran it).
    @Test(.enabled(if: output != nil))
    func district() async throws {
        try await study("district", run: "District, 1 t", receiverSpacing: nil) {
            let district = try NewDistrictTests().model()
            district.airChoice = .uniform
            await district.lay()
            return try #require(district.preview).document
        }
    }

    /// Three buildings across a street, to 50 ms.
    @Test(.enabled(if: output != nil))
    func street() async throws {
        try await study("street", run: "Street, 50 ms") {
            var document = ProjectDocument(scenario: ScenarioPreset.buildingsAcrossStreet.scenario)
            document.runSettings?.duration = 0.05
            return document
        }
    }

    /// Keeps a run of the scene `make` lays out, once, and reports what its recording weighs.
    private func study(
        _ name: String, run: String, receiverSpacing: Float? = 4, _ make: () async throws -> ProjectDocument
    ) async throws {
        let folder = URL(filePath: try #require(Self.output), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package = folder.appending(path: "\(name).bombcad", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: package.path) {
            try await keep(try await make(), named: run, receiverSpacing: receiverSpacing, at: package)
        }
        let report = try TimelineWeights.measure(package: package)
        print(report)
        try (report + "\n").write(
            to: folder.appending(path: "\(name)-timeline.txt"), atomically: true, encoding: .utf8)
    }

    /// Runs `document` with thermal receivers `receiverSpacing` apart (none for nil) and the cloud
    /// followed, keeps the run and saves the project with its recording.
    private func keep(
        _ document: ProjectDocument, named name: String, receiverSpacing: Float?, at package: URL
    ) async throws {
        var document = document
        if let receiverSpacing {
            var thermal = ThermalSpec()
            thermal.surfaceSpacing = receiverSpacing
            thermal.groundSpacing = 2 * receiverSpacing
            document.thermal = thermal
        }
        document.cloud = CloudSpec()
        let model = SimulationModel(document: document, playbackSpeed: .unlimited)
        model.recordsTimelines = true
        model.catchUpLimits = .unbounded
        while !model.experimentIsReady {
            try #require(model.errorMessage == nil, "\(model.errorMessage ?? "")")
            try await Task.sleep(for: .milliseconds(20))
        }
        model.run()
        while model.isRunning || model.hasPendingGPUWork || model.recentTimeline == nil {
            try #require(model.errorMessage == nil, "\(model.errorMessage ?? "")")
            try await Task.sleep(for: .milliseconds(50))
        }
        while true {
            do {
                try model.keepRun(named: name)
                break
            } catch is ProjectFileError {
                try #require(model.errorMessage == nil, "\(model.errorMessage ?? "")")
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        let wrapper = try ProjectDocument(model: model).packageWrapper(existing: nil)
        try wrapper.write(to: package, options: .atomic, originalContentsURL: nil)
    }
}
