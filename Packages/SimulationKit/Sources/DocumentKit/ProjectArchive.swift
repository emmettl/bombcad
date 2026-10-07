import CryptoKit
import Foundation

public enum ProjectFileError: LocalizedError {
    case invalid(String)
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .unsupportedVersion(let version):
            "This project uses format version \(version). This app supports version 1."
        }
    }
}

/// Container metadata, independent of either application's solver or release number.
public struct ProjectManifest: Codable, Equatable, Sendable {
    public static let formatIdentifier = "dev.simulationkit.project"
    public static let currentVersion = 1

    public struct Asset: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var path: String
        public var sha256: String

        public init(id: UUID = UUID(), path: String, data: Data) {
            self.id = id
            self.path = path
            sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    public var format: String
    public var schemaVersion: Int
    public var documentID: UUID
    public var documentType: String
    public var producer: String
    public var assets: [Asset]

    public init(documentType: String, producer: String, documentID: UUID = UUID(), assets: [Asset] = []) {
        format = Self.formatIdentifier
        schemaVersion = Self.currentVersion
        self.documentID = documentID
        self.documentType = documentType
        self.producer = producer
        self.assets = assets
    }
}

/// A self-contained package. Payload schemas belong to the consuming application.
/// `files` contains paths relative to the package, excluding manifest.json.
public struct ProjectArchive: Sendable, Equatable {
    public static let maximumFileBytes = 64 * 1024 * 1024
    public static let maximumTotalBytes = 256 * 1024 * 1024
    public static let maximumFileCount = 4096

    public var manifest: ProjectManifest
    public var files: [String: Data]

    public init(manifest: ProjectManifest, files: [String: Data]) throws {
        self.manifest = manifest
        self.files = files
        try validate()
    }

    public static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public func validate() throws {
        guard manifest.format == ProjectManifest.formatIdentifier else {
            throw ProjectFileError.invalid("This is not a SimulationKit project.")
        }
        guard manifest.schemaVersion == ProjectManifest.currentVersion else {
            throw ProjectFileError.unsupportedVersion(manifest.schemaVersion)
        }
        guard !manifest.documentType.isEmpty, !manifest.producer.isEmpty else {
            throw ProjectFileError.invalid("The project manifest is incomplete.")
        }
        guard files["manifest.json"] == nil, files["scene.json"] != nil, files["settings.json"] != nil else {
            throw ProjectFileError.invalid("A project needs scene.json and settings.json payloads.")
        }
        try Self.validateFiles(files)
        // Require parseable JSON objects; application codecs validate their own semantics.
        for path in ["scene.json", "settings.json", "view.json"] where files[path] != nil {
            guard let data = files[path], (try JSONSerialization.jsonObject(with: data)) is [String: Any]
            else {
                throw ProjectFileError.invalid("\(path) must contain a JSON object.")
            }
        }
        guard Set(manifest.assets.map(\.id)).count == manifest.assets.count,
            Set(manifest.assets.map(\.path)).count == manifest.assets.count
        else { throw ProjectFileError.invalid("Asset IDs and paths must be unique.") }
        for asset in manifest.assets {
            guard asset.path.hasPrefix("assets/"), let data = files[asset.path],
                ProjectManifest.Asset(id: asset.id, path: asset.path, data: data).sha256 == asset.sha256
            else { throw ProjectFileError.invalid("Missing or corrupt asset: \(asset.path).") }
        }
        let registered = Set(manifest.assets.map(\.path))
        guard files.keys.filter({ $0.hasPrefix("assets/") }).allSatisfy(registered.contains) else {
            throw ProjectFileError.invalid("Every embedded asset must be registered in the manifest.")
        }
    }

    /// Called by FileDocument; SwiftUI owns the coordinated save and replacement.
    public func fileWrapper() throws -> FileWrapper {
        try validate()
        var allFiles = files
        allFiles["manifest.json"] = try Self.encodeJSON(manifest)
        try Self.validateFiles(allFiles)
        let root = FileWrapper(directoryWithFileWrappers: [:])
        for path in allFiles.keys.sorted() {
            let components = path.split(separator: "/").map(String.init)
            var parent = root
            for name in components.dropLast() {
                if let child = parent.fileWrappers?[name] {
                    guard child.isDirectory else {
                        throw ProjectFileError.invalid("Conflicting path: \(path).")
                    }
                    parent = child
                } else {
                    let child = FileWrapper(directoryWithFileWrappers: [:])
                    child.preferredFilename = name
                    parent.addFileWrapper(child)
                    parent = child
                }
            }
            let child = FileWrapper(regularFileWithContents: allFiles[path]!)
            child.preferredFilename = components.last!
            parent.addFileWrapper(child)
        }
        return root
    }

    public init(fileWrapper: FileWrapper) throws {
        guard fileWrapper.isDirectory else {
            throw ProjectFileError.invalid("A project must be a document package.")
        }
        var files: [String: Data] = [:]
        var totalBytes = 0
        var entryCount = 0
        func visit(_ wrapper: FileWrapper, prefix: String, depth: Int) throws {
            guard depth <= 8, !wrapper.isSymbolicLink else {
                throw ProjectFileError.invalid("Project contains a symbolic link or excessive nesting.")
            }
            for (name, child) in wrapper.fileWrappers ?? [:] {
                entryCount += 1
                guard entryCount <= Self.maximumFileCount else {
                    throw ProjectFileError.invalid("Too many project entries.")
                }
                let path = prefix + name
                try Self.validatePath(path)
                if child.isDirectory {
                    try visit(child, prefix: path + "/", depth: depth + 1)
                } else {
                    guard child.isRegularFile, let data = child.regularFileContents else {
                        throw ProjectFileError.invalid("Project contains an unsupported file: \(path).")
                    }
                    try Self.checkSize(data.count, total: &totalBytes)
                    files[path] = data
                }
            }
        }
        try visit(fileWrapper, prefix: "", depth: 0)
        try self.init(allFiles: files)
    }

    /// Bounded URL reader: reject links and oversized files before loading their contents.
    public static func read(from url: URL) throws -> Self {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        let root = try url.resourceValues(forKeys: keys)
        guard root.isDirectory == true, root.isSymbolicLink != true else {
            throw ProjectFileError.invalid("Choose a project document package.")
        }
        var files: [String: Data] = [:]
        var totalBytes = 0
        var entries = 0
        func visit(_ folder: URL, prefix: String, depth: Int) throws {
            guard depth <= 8 else {
                throw ProjectFileError.invalid("Project directories are nested too deeply.")
            }
            for child in try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(keys))
            {
                entries += 1
                guard entries <= maximumFileCount else {
                    throw ProjectFileError.invalid("Too many project entries.")
                }
                let path = prefix + child.lastPathComponent
                try validatePath(path)
                let values = try child.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else {
                    throw ProjectFileError.invalid("Project symbolic links are not supported.")
                }
                if values.isDirectory == true {
                    try visit(child, prefix: path + "/", depth: depth + 1)
                } else {
                    guard values.isRegularFile == true, let size = values.fileSize else {
                        throw ProjectFileError.invalid("Unsupported project entry: \(path).")
                    }
                    try checkSize(size, total: &totalBytes)
                    let data = try Data(contentsOf: child)
                    guard data.count == size else {
                        throw ProjectFileError.invalid("Project changed while opening. Try again.")
                    }
                    files[path] = data
                }
            }
        }
        try visit(url, prefix: "", depth: 0)
        return try Self(allFiles: files)
    }

    private init(allFiles: [String: Data]) throws {
        guard let data = allFiles["manifest.json"] else {
            throw ProjectFileError.invalid("Missing project manifest.")
        }
        // Inspect version before decoding newer schemas, so failures are actionable.
        struct Header: Decodable {
            var format: String
            var schemaVersion: Int
        }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.format == ProjectManifest.formatIdentifier else {
            throw ProjectFileError.invalid("Unknown project format.")
        }
        guard header.schemaVersion == ProjectManifest.currentVersion else {
            throw ProjectFileError.unsupportedVersion(header.schemaVersion)
        }
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: data)
        var payloads = allFiles
        payloads.removeValue(forKey: "manifest.json")
        try self.init(manifest: manifest, files: payloads)
    }

    private static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 8,
            parts.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains(":")
                    && !$0.contains("\0")
            })
        else { throw ProjectFileError.invalid("Invalid project path: \(path).") }
    }

    private static func validateFiles(_ files: [String: Data]) throws {
        guard files.count <= maximumFileCount else {
            throw ProjectFileError.invalid("Too many project files.")
        }
        var total = 0
        var portablePaths: [String: String] = [:]
        for (path, data) in files {
            try validatePath(path)
            try checkSize(data.count, total: &total)
            let parts = path.split(separator: "/")
            for count in 1...parts.count {
                let prefix = parts.prefix(count).joined(separator: "/")
                let portable = prefix.precomposedStringWithCanonicalMapping.lowercased()
                if let existing = portablePaths[portable], existing != prefix {
                    throw ProjectFileError.invalid(
                        "Project paths differ only by case or Unicode representation: \(prefix).")
                }
                portablePaths[portable] = prefix
            }
            for count in 1..<parts.count {
                guard files[parts.prefix(count).joined(separator: "/")] == nil else {
                    throw ProjectFileError.invalid("A file conflicts with a project directory: \(path).")
                }
            }
        }
    }

    private static func checkSize(_ size: Int, total: inout Int) throws {
        guard size >= 0, size <= maximumFileBytes, size <= maximumTotalBytes - total else {
            throw ProjectFileError.invalid("Project exceeds the supported file or total size.")
        }
        total += size
    }
}
