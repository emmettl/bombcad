import DocumentKit
import RoomDocument
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let roomCADProject = UTType(exportedAs: "dev.roomcad.project", conformingTo: .package)
}

/// The SwiftUI document wrapper; `RoomProject` owns the format.
struct RoomCADFile: FileDocument {
    static let readableContentTypes: [UTType] = [.roomCADProject]
    static let writableContentTypes: [UTType] = [.roomCADProject]

    var project: RoomProject

    init(project: RoomProject = RoomProject()) {
        self.project = project
    }

    init(configuration: ReadConfiguration) throws {
        project = try RoomProject(archive: ProjectArchive(fileWrapper: configuration.file))
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try project.makeArchive().fileWrapper()
    }
}
