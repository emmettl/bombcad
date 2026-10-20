import Foundation

/// What a kept run holds beside its results, in `runs/<run id>/` of the project package: the
/// frames its timeline replays (the view's setup once, then chunks of consecutive frames) and the
/// solver checkpoints a run can continue from, listed in one `run.json` that the timeline's
/// recorder and the checkpoints both write, under one size budget.
///
/// The folder sits beside the project's archive, not in it: the archive holds every file in
/// memory and caps their sizes, where a run's frames and checkpoints can be hundreds of megabytes.
public struct RunTimelineManifest: Codable, Equatable, Sendable {
    public static let format = "dev.bombcad.run-timeline"
    /// The manifest's name in a run's folder, and the folder of every run's in a package.
    public static let fileName = "run.json"
    public static let folder = "runs"

    public struct Entry: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// The view's setup: what the frames are drawn on.
            case setup
            /// Consecutive frames, `count` of them from `time` to `endTime`.
            case frames
            /// A solver checkpoint a run can continue from.
            case checkpoint
        }
        public var kind: Kind
        /// Simulated seconds, and the solver's step.
        public var time: Double
        public var step: Int
        /// Relative to the run's folder.
        public var path: String
        public var bytes: Int
        /// For frames: the last frame's time and how many.
        public var endTime: Double?
        public var count: Int?
        /// For checkpoints: saved by hand ("Save State Here"), so never thinned out.
        public var pinned: Bool?

        public init(
            kind: Kind, time: Double, step: Int, path: String, bytes: Int, endTime: Double? = nil,
            count: Int? = nil, pinned: Bool? = nil
        ) {
            self.kind = kind
            self.time = time
            self.step = step
            self.path = path
            self.bytes = bytes
            self.endTime = endTime
            self.count = count
            self.pinned = pinned
        }
    }

    public var format = Self.format
    public var encodingVersion = 1
    /// The run's scene and settings, as `SavedSimulationRun.fingerprint` gives them, so that
    /// frames and checkpoints are never read against another run.
    public var sceneFingerprint: String
    public var settingsFingerprint: String
    public var budgetBytes: Int
    public private(set) var usedBytes = 0
    /// In time order.
    public private(set) var entries: [Entry] = []

    public init(sceneFingerprint: String, settingsFingerprint: String, budgetBytes: Int) {
        self.sceneFingerprint = sceneFingerprint
        self.settingsFingerprint = settingsFingerprint
        self.budgetBytes = budgetBytes
    }

    public var isOverBudget: Bool { usedBytes > budgetBytes }

    /// Adds `entry` in time order, replacing one at the same path.
    public mutating func add(_ entry: Entry) {
        remove(path: entry.path)
        let index = entries.firstIndex { $0.time > entry.time } ?? entries.endIndex
        entries.insert(entry, at: index)
        usedBytes += entry.bytes
    }

    public mutating func remove(path: String) {
        guard let index = entries.firstIndex(where: { $0.path == path }) else { return }
        usedBytes -= entries[index].bytes
        entries.remove(at: index)
    }

    public func entries(_ kind: Entry.Kind) -> [Entry] { entries.filter { $0.kind == kind } }

    /// The checkpoints to drop when over budget, so that what remains still spans the run: every
    /// other one, keeping the first and the last, and any saved by hand.
    public var checkpointsToThin: [Entry] {
        let checkpoints = entries(.checkpoint)
        guard checkpoints.count > 2 else { return [] }
        return checkpoints.indices.dropFirst().dropLast().filter { $0 % 2 == 1 }.map { checkpoints[$0] }
            .filter { $0.pinned != true }
    }

    /// The bytes the checkpoints take.
    public var checkpointBytes: Int { entries(.checkpoint).reduce(0) { $0 + $1.bytes } }

    /// The latest checkpoint at or before `time`, which a run carried on from there would start at.
    public func checkpoint(atOrBefore time: Double) -> Entry? {
        entries(.checkpoint).last { $0.time <= time + 1e-9 }
    }

    /// Whether `data` is a manifest this version reads.
    public static func decode(_ data: Data) throws -> Self {
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        guard manifest.format == format, manifest.encodingVersion == 1,
            manifest.entries.allSatisfy({ !$0.path.contains("..") && !$0.path.hasPrefix("/") })
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Not a run timeline this version reads."))
        }
        return manifest
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
