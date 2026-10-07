import BlastCore
import Foundation

// Generates a self-contained visual replay of the tested Swift mechanics, with no browser physics.
// swift run rigidboxdemo [output.html]
do {
    let destination = URL(
        fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/rigid-box-demo.html")
    let recordings = try RigidObjectDemo.recordings()
    let data = try JSONEncoder().encode(recordings)
    let source = Bundle.module.url(forResource: "viewer", withExtension: "html")!
    let template = try String(contentsOf: source, encoding: .utf8)
    let html = template.replacingOccurrences(
        of: "__RECORDINGS__", with: String(decoding: data, as: UTF8.self))
    try html.write(to: destination, atomically: true, encoding: .utf8)
    print("Wrote \(destination.path) (\(recordings.count) cases, Swift mechanics at 1 ms)")
} catch {
    FileHandle.standardError.write(Data("rigidboxdemo: \(error.localizedDescription)\n".utf8))
    exit(1)
}
