import AcousticCore
import DocumentKit
import Foundation
import ImpulseResponseKit
import Testing
import simd

@testable import RoomDocument

@Suite("RoomCAD documents")
struct RoomDocumentTests {
    /// A small, quick room.
    static var settings: RoomResponseSettings {
        RoomResponseSettings(
            room: ShoeboxRoom(size: [5, 4, 3], material: .uniform(0.4, name: "Test")),
            source: RoomPoint(name: "Source", position: [1.3, 1.1, 1.2]),
            receivers: [
                RoomPoint(name: "Left", position: [3.7, 2.9, 1.6]),
                RoomPoint(name: "Right", position: [3.9, 2.1, 1.6]),
            ],
            duration: 0.15, maximumReflectionOrder: 30)
    }

    private func reopened(_ project: RoomProject) throws -> RoomProject {
        try RoomProject(archive: ProjectArchive(fileWrapper: project.makeArchive().fileWrapper()))
    }

    @Test("A new project saves its room, settings and identity and reopens unchanged")
    func roundTrip() throws {
        var project = RoomProject(settings: Self.settings)
        project.settings.room.ceiling = SurfaceMaterial(
            name: "Banded", absorption: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8], reference: "Test")
        project.settings.content = .reflectionsOnly
        project.export = ExportSettings(peak: nil, fadeOut: 0.02, removeLeadingDelay: true)
        let archive = try project.makeArchive()
        #expect(archive.manifest.documentType == "roomcad")
        #expect(archive.manifest.producer == "RoomCAD")
        #expect(Set(archive.files.keys) == ["scene.json", "settings.json"])
        let loaded = try reopened(project)
        #expect(loaded == project)
        #expect(loaded.documentID == project.documentID)
        #expect(loaded.result == nil)
    }

    @Test("The starter room is valid and complete within its order limit")
    func starter() throws {
        let starter = RoomProject.starter
        try starter.validate()
        #expect(starter.receivers.count == 2)
        #expect(starter.estimatedImageCount < 3_000_000)
    }

    @Test("A preview is current but not final, and stays a preview when the document reopens")
    func preview() throws {
        var project = RoomProject(settings: Self.settings)
        project.result = try RoomResponseGenerator.generate(project.settings, quality: .preview)
        #expect(project.isResultCurrent && !project.isResultFinal)
        let loaded = try reopened(project)
        #expect(loaded.isResultCurrent && !loaded.isResultFinal)
        project.result = try RoomResponseGenerator.generate(project.settings)
        #expect(project.isResultFinal)
        // A response saved before previews existed has no quality and was made in full.
        project.result?.diagnostics.quality = nil
        #expect(project.isResultFinal)
    }

    @Test("A retained response reopens, and only changes to its inputs make it stale")
    func retainedResult() throws {
        var project = RoomProject(settings: Self.settings)
        project.result = try RoomResponseGenerator.generate(project.settings)
        #expect(project.isResultCurrent)
        let loaded = try reopened(project)
        #expect(loaded.isResultCurrent)
        #expect(loaded.result?.response == project.result?.response)
        #expect(loaded.result?.diagnostics == project.result?.diagnostics)

        var exportChanged = loaded
        exportChanged.export.fadeOut = 0.1
        #expect(exportChanged.isResultCurrent)
        var moved = loaded
        moved.settings.receivers[0].position.x += 0.1
        #expect(!moved.isResultCurrent)
        // A stale response is still kept, so it can be compared until it is regenerated.
        #expect(try reopened(moved).result != nil)
    }

    @Test("Files this version does not interpret are kept when the project is saved again")
    func preservesUnknownFiles() throws {
        var archive = try RoomProject(settings: Self.settings).makeArchive()
        archive.files["view.json"] = Data(#"{"zoom":2}"#.utf8)
        archive.files["results/notes.txt"] = Data("kept".utf8)
        var project = try RoomProject(archive: archive)
        project.settings.duration = 0.2
        let saved = try project.makeArchive()
        #expect(saved.files["view.json"] == archive.files["view.json"])
        #expect(saved.files["results/notes.txt"] == Data("kept".utf8))
        #expect(saved.manifest.documentID == archive.manifest.documentID)
    }

    @Test("Other apps' projects, newer encodings and invalid rooms are rejected")
    func rejectsInvalid() throws {
        let good = try RoomProject(settings: Self.settings).makeArchive()

        var bombcad = good
        bombcad.manifest.documentType = "bombcad"
        #expect(throws: ProjectFileError.self) { try RoomProject(archive: bombcad) }

        var newer = good
        newer.files["scene.json"] = try replacing(
            in: good.files["scene.json"]!, key: "encodingVersion", with: 2)
        let error = #expect(throws: ProjectFileError.self) { try RoomProject(archive: newer) }
        guard case .unsupportedVersion(2) = error else {
            Issue.record("Expected an unsupported-version error, got \(String(describing: error))")
            return
        }

        var outside = RoomProject(settings: Self.settings)
        outside.settings.receivers[0].position.x = 9
        var invalid = good
        invalid.files["scene.json"] = try ProjectArchive.encodeJSON(
            RoomProject.Scene(
                room: outside.settings.room, source: outside.settings.source,
                receivers: outside.settings.receivers))
        #expect(throws: ProjectFileError.self) { try RoomProject(archive: invalid) }

        var duplicate = good
        let s = Self.settings
        duplicate.files["scene.json"] = try ProjectArchive.encodeJSON(
            RoomProject.Scene(room: s.room, source: s.source, receivers: [s.receivers[0], s.receivers[0]]))
        #expect(throws: ProjectFileError.self) { try RoomProject(archive: duplicate) }

        var halfResult = good
        halfResult.files["results/response.wav"] = try WAVFile.encode(channels: [[0]], sampleRate: 48_000)
        #expect(throws: ProjectFileError.self) { try RoomProject(archive: halfResult) }
    }

    @Test("Responses too large for the document are not retained")
    func oversizedResult() throws {
        var project = RoomProject(settings: Self.settings)
        let generated = try RoomResponseGenerator.generate(project.settings)
        let frames = RoomProject.maximumRetainedBytes / 8 + 1
        var metadata = generated.response.metadata
        metadata.frameCount = frames
        let huge = try ImpulseResponse(
            channels: Array(repeating: Array(repeating: 0, count: frames), count: 2), metadata: metadata)
        project.result = RoomResponse(
            response: huge, settings: generated.settings, diagnostics: generated.diagnostics)
        #expect(!project.retainsResult)
        #expect(try project.makeArchive().files["results/response.wav"] == nil)
    }

    @Test("Export conditioning works on a copy and keeps channels in proportion")
    func exportConditioning() throws {
        let result = try RoomResponseGenerator.generate(Self.settings)
        let export = ExportSettings(peak: 0.8, fadeOut: 0.01, removeLeadingDelay: true)
        let output = try export.conditioned(result)
        #expect(abs(output.response.peak - 0.8) < 1e-6)
        #expect(output.response.channels.allSatisfy { $0.last == 0 })
        #expect(output.response.metadata.emissionFrame < 0)
        let removed = -output.response.metadata.emissionFrame
        let ratio = Double(output.response.peak / result.response.peak)
        #expect(abs(output.response.metadata.commonGain - ratio) < 1e-6)
        // Same sample, both channels, before and after: one common gain and one common shift.
        let i = 400
        for c in 0..<2 {
            let before = Double(result.response.channels[c][i + removed])
            #expect(abs(Double(output.response.channels[c][i]) - before * ratio) < 1e-6)
        }
        // The direct sound is not clipped by removing the delay.
        let direct = Int(result.diagnostics.directDelay.min()! * 48_000)
        #expect(direct - removed >= 32)
        #expect(result.response.metadata.processing.isEmpty)
    }

    @Test("The summary's envelope peaks at 0 dB and every band's decay is measured")
    func summary() throws {
        var settings = Self.settings
        settings.duration = 0.25
        settings.maximumReflectionOrder = 60
        let summary = ResponseSummary(try RoomResponseGenerator.generate(settings), buckets: 100)
        #expect(summary.channels.map(\.name) == ["Left", "Right"])
        #expect(summary.channels.allSatisfy { $0.envelope.count == 100 })
        // Levels are relative to the loudest channel.
        #expect(summary.channels.compactMap { $0.envelope.max() }.max() == 0)
        #expect(
            summary.channels.allSatisfy { $0.envelope.allSatisfy { $0 <= 0 && $0 >= ResponseSummary.floor } })
        #expect(summary.channels.allSatisfy { $0.reverberationTime[3...].allSatisfy { $0 != nil } })
    }

    @Test("The summary's spectrum is flat for the direct sound alone and peaks at 0 dB")
    func spectrum() throws {
        var settings = Self.settings
        settings.room = ShoeboxRoom(size: settings.room.size, material: .anechoic)
        settings.airAbsorption = false
        settings.duration = 0.1
        let summary = ResponseSummary(try RoomResponseGenerator.generate(settings))
        #expect(
            summary.channels.allSatisfy { $0.spectrum.count == ResponseSummary.spectrumFrequencies.count })
        #expect(summary.channels.flatMap(\.spectrum).max() == 0)
        // Clear of the ripple from the 20 Hz high-pass's tail, cut by the short response, and below the
        // renderer's 0.9 × Nyquist cutoff.
        let band = ResponseSummary.spectrumFrequencies.indices.filter {
            (300...10_000).contains(ResponseSummary.spectrumFrequencies[$0])
        }
        for channel in summary.channels {
            let levels = band.map { channel.spectrum[$0] }
            #expect(levels.max()! - levels.min()! < 0.2, "\(channel.name): \(levels)")
        }
    }

    @Test("The early view shows the direct sound and a floor reflection at their path lengths' times")
    func early() throws {
        var settings = Self.settings
        settings.room = ShoeboxRoom(size: settings.room.size, material: .anechoic)
        settings.room.floor = .rigid
        settings.airAbsorption = false
        settings.maximumReflectionOrder = 1
        settings.duration = 0.1
        let summary = ResponseSummary(try RoomResponseGenerator.generate(settings))
        let c = settings.atmosphere.soundSpeed
        let source = settings.source.position
        let receiver = settings.receivers[0].position
        let direct = simd_distance(source, receiver) / c
        let floor = simd_distance(SIMD3(source.x, source.y, -source.z), receiver) / c
        let early = summary.channels[0].early
        func bin(_ t: Double) -> Int { Int(t / ResponseSummary.earlyBin) }
        // The loudest bin is the direct sound's; the reflection, from a rigid floor along a longer path,
        // is a little quieter; between them there is nothing.
        #expect(early.indices.max { early[$0] < early[$1] }.map { abs($0 - bin(direct)) <= 1 } == true)
        let reflection = early[(bin(floor) - 1)...(bin(floor) + 1)].max()!
        #expect(reflection > -6 && reflection < 0)
        #expect(early[(bin(direct) + 3)..<(bin(floor) - 2)].allSatisfy { $0 < -30 })
    }

    @Test("A saved document reopens from disk after being moved")
    func onDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = RoomProject(settings: Self.settings)
        project.result = try RoomResponseGenerator.generate(project.settings)
        let first = folder.appendingPathComponent("Room.roomcad")
        try project.makeArchive().fileWrapper().write(to: first, options: .atomic, originalContentsURL: nil)
        let moved = folder.appendingPathComponent("Moved.roomcad")
        try FileManager.default.moveItem(at: first, to: moved)
        let loaded = try RoomProject(archive: ProjectArchive.read(from: moved))
        #expect(loaded == project)
        let wav = moved.appendingPathComponent("results/response.wav")
        #expect(try WAVFile.decode(Data(contentsOf: wav)).channels.count == 2)
    }

    private func replacing(in json: Data, key: String, with value: Int) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        object[key] = value
        return try JSONSerialization.data(withJSONObject: object)
    }
}

@Suite("RoomCAD documents and scattering")
struct RoomDocumentScatteringTests {
    @Test("Ray count, seed and scattering coefficients survive saving")
    func roundTrip() throws {
        var project = RoomProject(settings: RoomDocumentTests.settings)
        project.settings.room.north.scattering = [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7]
        project.settings.diffuseRays = 12_345
        project.settings.randomSeed = 77
        project.settings.openings = [Opening(name: "Door", surface: .north, centre: [2, 1], size: [0.9, 2])]
        project.settings.lowFrequencyModel = true
        project.settings.crossoverFrequency = 120
        project.settings.receivers[0].microphone = Microphone(pattern: .cardioid, azimuth: 30, elevation: -5)
        let loaded = try RoomProject(
            archive: ProjectArchive(fileWrapper: project.makeArchive().fileWrapper()))
        #expect(loaded.settings == project.settings)
    }

    @Test("Documents saved before scattering open with defaults, and their responses become out of date")
    func olderDocuments() throws {
        var project = RoomProject(settings: RoomDocumentTests.settings)
        project.result = try RoomResponseGenerator.generate(project.settings)
        var archive = try project.makeArchive()
        func strip(_ path: String, keys: [String]) throws {
            var object = try #require(
                try JSONSerialization.jsonObject(with: archive.files[path]!) as? [String: Any])
            for key in keys { object[key] = nil }
            archive.files[path] = try JSONSerialization.data(withJSONObject: object)
        }
        try strip("settings.json", keys: ["diffuseRays", "randomSeed"])
        // A response from the previous, specular-only generator.
        var description = try #require(
            try JSONSerialization.jsonObject(with: archive.files["results/response.json"]!) as? [String: Any])
        description["generator"] = "RoomCAD image-source model 1"
        archive.files["results/response.json"] = try JSONSerialization.data(withJSONObject: description)
        let loaded = try RoomProject(archive: archive)
        #expect(loaded.settings.diffuseRays == 40_000 && loaded.settings.randomSeed == 1)
        #expect(loaded.result != nil)
        #expect(!loaded.isResultCurrent)
    }

    @Test("A floor plan and openings in its walls survive saving")
    func floorPlan() throws {
        let preset = try #require(RoomPresets.all.first { $0.id == "l-shaped-living-room" })
        var project = RoomProject(settings: preset.applied(to: RoomDocumentTests.settings))
        project.settings.openings = [
            Opening(name: "Door", surface: .north, wall: 5, centre: [2, 1], size: [0.9, 2])
        ]
        try project.settings.validate()
        let loaded = try RoomProject(
            archive: ProjectArchive(fileWrapper: project.makeArchive().fileWrapper()))
        #expect(loaded.settings == project.settings)
        #expect(loaded.settings.room.plan?.corners.count == 6)
    }

    @Test("A hall built from solids keeps its mesh, materials and labels when saved")
    func meshRoom() throws {
        let preset = try #require(RoomPresets.all.first { $0.id == "raked-auditorium" })
        let project = RoomProject(settings: preset.applied(to: RoomDocumentTests.settings))
        try project.settings.validate()
        let loaded = try RoomProject(
            archive: ProjectArchive(fileWrapper: project.makeArchive().fileWrapper()))
        #expect(loaded.settings == project.settings)
        let mesh = try #require(loaded.settings.room.mesh)
        #expect(mesh.labels == HallShapes.labels)
        #expect(abs(loaded.settings.room.volume - project.settings.room.volume) < 1e-9)
    }
}
