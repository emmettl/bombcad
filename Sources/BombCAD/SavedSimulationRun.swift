import BlastCore
import CryptoKit
import DocumentKit
import Foundation

struct SavedSimulationRun: Codable, Equatable, Identifiable, Sendable {
    static let solverVersion = "blast-solver-2"
    static let multiBodySolverVersion = "blast-solver-3"
    static let maximumRuns = 16
    static let maximumSamples = 500_000

    struct Point: Codable, Equatable, Sendable {
        var time: Double  // Seconds since detonation.
        var value: Double  // kPa for gauges; mm for structural deflection.
    }

    struct Gauge: Codable, Equatable, Identifiable, Sendable {
        struct Key: Codable, Hashable, Sendable {
            var name: String
            var position: SIMD3<Float>
            var occurrence: Int
        }
        var key: Key
        var points: [Point]
        var id: Key { key }
        var peak: Double { points.reduce(0) { max($0, $1.value) } }

        static func keys(_ gauges: [BlastCore.Gauge]) -> [Key] {
            gauges.enumerated().map { index, gauge in
                Key(
                    name: gauge.name, position: gauge.position,
                    occurrence:
                        gauges.prefix(index).filter { $0.name == gauge.name && $0.position == gauge.position }
                        .count)
            }
        }
    }

    struct Structure: Codable, Equatable, Sendable {
        var points: [Point]
        var sampleInterval = 0.001
        var failedFraction: Double
        var maximumDamage: Double
        var peak: Double { points.reduce(0) { max($0, $1.value) } }
    }

    struct BodyResponse: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var name: String
        var response: Structure
    }

    /// A cased charge's fragments, flown alongside the run: what was flown and where it landed.
    /// They do not act on the air, so they are no part of the inputs' fingerprint.
    struct Fragments: Codable, Equatable, Sendable {
        var spec: FragmentSpec
        /// Metres a second.
        var launchSpeed: Double
        var impacts: [FragmentImpact]
        /// Fragments still in flight when the run ended.
        var airborne: Int
        /// Joules.
        var hardest: Double { Double(impacts.map(\.energy).max() ?? 0) }

        var summary: String {
            let count = spec.count.formatted()
            let speed = Int(launchSpeed.rounded()).formatted()
            var text = "Fragments: \(count) at \(speed) m/s; \(impacts.count.formatted()) landed"
            if hardest > 0 {
                text +=
                    hardest >= 1e6
                    ? String(format: ", hardest %.1f MJ", hardest / 1e6)
                    : String(format: ", hardest %.0f kJ", hardest / 1e3)
            }
            return text
        }
    }

    var id = UUID()
    var name: String
    var capturedAt = Date()
    var solverVersion = Self.solverVersion
    var appVersion: String
    var deviceName: String
    var operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    var scenario: Scenario
    var settings: ProjectRunSettings
    var inputSHA256: String
    var elapsedTime: Double
    var stepCount: Int
    var gauges: [Gauge]
    var structure: Structure?
    var bodyResponses: [BodyResponse]? = nil
    var fragments: Fragments? = nil

    static func fingerprint(_ scenario: Scenario, settings: ProjectRunSettings) throws -> String {
        struct Inputs: Encodable {
            var scenario: Scenario
            var settings: ProjectRunSettings
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.userInfo[Scenario.physicsInputEncoding] = true
        return SHA256.hash(data: try encoder.encode(Inputs(scenario: scenario, settings: settings)))
            .map { String(format: "%02x", $0) }.joined()
    }

    func validate() throws {
        try ProjectDocument.validate(scenario)
        try settings.validate()
        try ProjectDocument.validateGrid(scenario, resolution: Resolution(rawValue: settings.resolution)!)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120,
            !solverVersion.isEmpty, appVersion.count <= 256, deviceName.count <= 256,
            operatingSystem.count <= 512,
            capturedAt.timeIntervalSince1970.isFinite, elapsedTime.isFinite,
            elapsedTime > 0, elapsedTime >= settings.duration - 1e-9, stepCount > 0,
            inputSHA256 == (try Self.fingerprint(scenario, settings: settings)),
            gauges.map(\.key) == Gauge.keys(Array(scenario.gauges.prefix(BlastSolver.maxGauges))),
            gauges.reduce(0, { $0 + $1.points.count }) + (structure?.points.count ?? 0)
                + (bodyResponses ?? []).reduce(0, { $0 + $1.response.points.count })
                <= Self.maximumSamples,
            gauges.allSatisfy({ valid($0.points) }),
            (structure == nil) == (scenario.structure == nil)
        else { throw ProjectFileError.invalid("Invalid saved run inputs, identity or measurement history.") }
        if scenario.structuralObjects.count > 1 || bodyResponses != nil {
            let responses = bodyResponses ?? []
            let objects = scenario.structuralObjects
            guard responses.count == objects.count, Set(responses.map(\.id)).count == responses.count,
                Set(responses.map(\.id)) == Set(objects.map(\.id)),
                responses.allSatisfy({ entry in
                    !entry.name.isEmpty && entry.name == scenario.object(id: entry.id)?.name
                        && valid(entry.response.points) && entry.response.points.allSatisfy({ $0.value >= 0 })
                        && entry.response.sampleInterval.isFinite && entry.response.sampleInterval > 0
                        && entry.response.failedFraction.isFinite
                        && (0...1).contains(entry.response.failedFraction)
                        && entry.response.maximumDamage.isFinite && entry.response.maximumDamage >= 0
                }), scenario.structuralObjects.count <= 1 || solverVersion == Self.multiBodySolverVersion
            else { throw ProjectFileError.invalid("Invalid per-object response ownership or history.") }
        }
        if let fragments {
            let spec = fragments.spec
            guard (try? spec.validate()) != nil, fragments.launchSpeed.isFinite, fragments.launchSpeed >= 0,
                fragments.airborne >= 0, fragments.impacts.count + fragments.airborne <= spec.count,
                Set(fragments.impacts.map(\.fragment)).count == fragments.impacts.count,
                fragments.impacts.allSatisfy({ impact in
                    (0..<spec.count).contains(impact.fragment) && impact.time.isFinite && impact.time >= 0
                        && impact.time <= elapsedTime + 1e-6 && impact.position.x.isFinite
                        && impact.position.y.isFinite && impact.position.z.isFinite
                        && impact.speed.isFinite && impact.speed >= 0 && impact.energy.isFinite
                        && impact.energy >= 0 && !impact.surface.isEmpty && impact.surface.count <= 64
                })
            else { throw ProjectFileError.invalid("Invalid saved fragments.") }
        }
        if let structure {
            guard structure.sampleInterval.isFinite, structure.sampleInterval > 0,
                valid(structure.points), structure.points.allSatisfy({ $0.value >= 0 }),
                structure.failedFraction.isFinite, (0...1).contains(structure.failedFraction),
                structure.maximumDamage.isFinite, structure.maximumDamage >= 0
            else { throw ProjectFileError.invalid("Invalid saved structural response.") }
        }
    }

    private func valid(_ points: [Point]) -> Bool {
        var previous = -Double.infinity
        for point in points {
            guard point.time.isFinite, point.time >= 0, point.time <= elapsedTime + 1e-6,
                point.time > previous, point.value.isFinite
            else { return false }
            previous = point.time
        }
        return true
    }

    /// Chart-only reduction retains both extremes in each bucket; stored and exported data stay full.
    static func plotPoints(_ points: [Point], limit: Int = 600) -> [Point] {
        guard points.count > limit, limit >= 2 else { return points }
        let width = max(1, Int(ceil(Double(points.count) / Double(limit / 2))))
        return stride(from: 0, to: points.count, by: width).flatMap { start -> [Point] in
            let bucket = points[start..<min(start + width, points.count)]
            let low = bucket.min { $0.value < $1.value }!
            let high = bucket.max { $0.value < $1.value }!
            return low.time == high.time ? [low] : [low, high].sorted { $0.time < $1.time }
        }
    }

    func csv() -> String {
        func field(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = ["run,series,time (ms),value,unit"]
        for gauge in gauges {
            for point in gauge.points {
                lines.append(
                    "\(field(name)),\(field(gauge.key.name)),\(point.time * 1000),\(point.value),kPa")
            }
        }
        for point in structure?.points ?? [] {
            lines.append("\(field(name)),\"Largest deflection\",\(point.time * 1000),\(point.value),mm")
        }
        for body in bodyResponses ?? [] {
            let label = field("\(body.name) [\(body.id.uuidString)] deflection")
            for point in body.response.points {
                lines.append("\(field(name)),\(label),\(point.time * 1000),\(point.value),mm")
            }
        }
        for impact in fragments?.impacts.sorted(by: { $0.time < $1.time }) ?? [] {
            let label = field("Fragment \(impact.fragment) on \(impact.surface)")
            lines.append("\(field(name)),\(label),\(impact.time * 1000),\(impact.energy),J")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

enum SavedRunStore {
    private static let indexPath = "results/runs.json"
    private struct Index: Codable {
        var format = "dev.bombcad.runs"
        var encodingVersion = 1
        var runs: [UUID]
    }
    private struct Record: Codable {
        var format = "dev.bombcad.run"
        var encodingVersion = 1
        var result: SavedSimulationRun
        var scene: ImportedSceneCodec.ScenePayload
    }
    private static func path(_ id: UUID) -> String { "results/runs/\(id.uuidString.lowercased()).json" }

    static func read(_ archive: ProjectArchive) throws -> [SavedSimulationRun] {
        guard let data = archive.files[indexPath] else { return [] }
        let index = try JSONDecoder().decode(Index.self, from: data)
        guard index.format == "dev.bombcad.runs", index.encodingVersion == 1,
            index.runs.count <= SavedSimulationRun.maximumRuns, Set(index.runs).count == index.runs.count
        else { throw ProjectFileError.invalid("Unsupported or invalid saved-run index.") }
        let runs = try index.runs.map { id in
            guard let data = archive.files[path(id)] else {
                throw ProjectFileError.invalid("Missing saved run \(id).")
            }
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard record.format == "dev.bombcad.run", [1, 2].contains(record.encodingVersion),
                record.result.id == id,
                (record.result.scenario.structuralObjects.count > 1) == (record.encodingVersion == 2),
                record.result.scenario.importedModels == nil, record.result.scenario == record.scene.scenario
            else { throw ProjectFileError.invalid("Unsupported or conflicting saved run payload.") }
            var input = archive
            input.files["scene.json"] = try ProjectArchive.encodeJSON(record.scene)
            var run = record.result
            run.scenario = try ImportedSceneCodec.decode(input)
            try run.validate()
            return run
        }
        guard Set(runs.map { $0.name.lowercased() }).count == runs.count else {
            throw ProjectFileError.invalid("Saved run names must be unique.")
        }
        return runs
    }

    static func write(
        _ runs: [SavedSimulationRun], manifest: inout ProjectManifest, files: inout [String: Data]
    ) throws {
        guard runs.count <= SavedSimulationRun.maximumRuns, Set(runs.map(\.id)).count == runs.count,
            Set(runs.map { $0.name.lowercased() }).count == runs.count
        else {
            throw ProjectFileError.invalid(
                "Keep at most \(SavedSimulationRun.maximumRuns) uniquely identified runs.")
        }
        if let prior = files[indexPath] {
            let index = try JSONDecoder().decode(Index.self, from: prior)
            guard index.format == "dev.bombcad.runs", index.encodingVersion == 1,
                index.runs.count <= SavedSimulationRun.maximumRuns
            else {
                throw ProjectFileError.invalid("Unsupported saved-run index; preserve the original project.")
            }
            for id in index.runs { files.removeValue(forKey: path(id)) }
        }
        files.removeValue(forKey: indexPath)
        guard !runs.isEmpty else { return }
        for run in runs {
            try run.validate()
            let scene = try JSONDecoder().decode(
                ImportedSceneCodec.ScenePayload.self,
                from: ImportedSceneCodec.encode(run.scenario, manifest: &manifest, files: &files))
            var stored = run
            stored.scenario.importedModels = nil
            var record = Record(result: stored, scene: scene)
            record.encodingVersion = run.scenario.structuralObjects.count > 1 ? 2 : 1
            files[path(run.id)] = try ProjectArchive.encodeJSON(record)
        }
        files[indexPath] = try ProjectArchive.encodeJSON(Index(runs: runs.map(\.id)))
    }
}
