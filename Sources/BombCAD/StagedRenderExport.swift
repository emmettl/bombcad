import Darwin
import DocumentKit
import Foundation

/// Keeps an existing scene intact until its replacement and optional companion folder are ready.
/// Both outputs retain their final basenames so relative asset paths survive publication.
@MainActor
struct StagedRenderExport {
    let scene: URL
    let volumes: URL?
    private let destination: URL
    private let destinationVolumes: URL?
    private let staging: URL

    init(destination: URL, includesVolumes: Bool) throws {
        self.destination = destination
        destinationVolumes = includesVolumes ? RenderExport.volumes(for: destination) : nil
        if let destinationVolumes, try Self.attributes(destinationVolumes) != nil {
            throw ProjectFileError.invalid(
                "\(destinationVolumes.lastPathComponent) already exists beside the scene; choose another name."
            )
        }
        try Self.checkSceneDestination(destination)
        let staging = destination.deletingLastPathComponent().appending(
            path: ".bombcad-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        self.staging = staging
        scene = staging.appending(path: destination.lastPathComponent)
        volumes = destinationVolumes.map { staging.appending(path: $0.lastPathComponent) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    }

    func discard() { try? FileManager.default.removeItem(at: staging) }

    func publish() throws {
        try Self.checkSceneDestination(destination)
        var movedVolumes = false
        do {
            if let volumes, let destinationVolumes {
                // moveItem refuses a competing destination, including one created during the export.
                try FileManager.default.moveItem(at: volumes, to: destinationVolumes)
                movedVolumes = true
            }
            // Staging is on the same filesystem. rename replaces a regular scene atomically;
            // a failed rename leaves the previous scene untouched.
            guard rename(scene.path, destination.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            if movedVolumes, let destinationVolumes {
                try? FileManager.default.removeItem(at: destinationVolumes)
            }
            throw error
        }
    }

    private static func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
        {
            return nil
        }
    }

    private static func checkSceneDestination(_ url: URL) throws {
        guard let attributes = try attributes(url) else { return }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ProjectFileError.invalid("Choose a regular scene file to replace.")
        }
    }
}
