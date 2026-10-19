import Foundation
import Testing

/// The renderer draws the shell solver's own buffers through copies of its structs
/// (`ShellMeshNode` and `ShellMeshElement` in Render.metal). A field added to the solver's alone
/// changes the stride the renderer reads at, and every shell is drawn from the wrong bytes: from
/// 18 October 2026, when `ShellElement` gained its shields, until this test, the office's
/// façades were drawn as streaks hundreds of metres long while the run itself was sound.
@Suite("The renderer's copies of the solver's structs")
struct RenderLayoutTests {
    /// The members of `struct name { ... };` in a shader source, comments and spacing removed.
    static func members(of name: String, in source: String) throws -> [String] {
        let start = try #require(source.range(of: "struct \(name) {"), "no struct \(name)")
        let end = try #require(source.range(of: "};", range: start.upperBound..<source.endIndex))
        return source[start.upperBound..<end.lowerBound].split(separator: "\n").compactMap { line in
            let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let words = code.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            return words.isEmpty ? nil : words
        }
    }

    static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("Shell nodes and elements are drawn with the solver's layout")
    func shellLayouts() throws {
        let solver = try Self.source("Sources/BlastCore/Shaders/Shell.metal")
        let renderer = try Self.source("Sources/BlastRender/Shaders/Render.metal")
        #expect(
            try Self.members(of: "ShellMeshNode", in: renderer) == Self.members(of: "ShellNode", in: solver))
        #expect(
            try Self.members(of: "ShellMeshElement", in: renderer)
                == Self.members(of: "ShellElement", in: solver))
    }
}
