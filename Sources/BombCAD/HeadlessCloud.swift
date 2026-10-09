import BlastCore
import DocumentKit
import Foundation

/// `BombCAD cloud`: follows the cloud of a run already made again, from the hand-over its
/// `--cloud-results` kept, in another atmosphere, without running the blast again.
enum HeadlessCloud {
    static let usage = """
        Usage: BombCAD cloud <cloud-results.json> [--cloud <spec.json>] [--sounding <sounding.csv>]
                             [--cloud-results <file.json>]

        Follows the cloud from the hand-over in the results of an earlier `BombCAD run --cloud`,
        with the description given or, without --cloud, the one it was made with, and prints a
        summary. --sounding reads a measured atmosphere, in the University of Wyoming archive's
        comma-separated values, in place of the standard one, as it does for `BombCAD run`.
        --cloud-results writes the new results.
        """

    static func main(_ arguments: [String]) -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        do {
            var positional: [String] = []
            var values: [String: String] = [:]
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                if argument.hasPrefix("--") {
                    let key = String(argument.dropFirst(2))
                    guard ["cloud", "sounding", "cloud-results"].contains(key) else {
                        throw ProjectFileError.invalid("Unknown option \(argument).")
                    }
                    guard index + 1 < arguments.count, values[key] == nil else {
                        throw ProjectFileError.invalid("Give \(argument) one value.")
                    }
                    values[key] = arguments[index + 1]
                    index += 2
                } else {
                    positional.append(argument)
                    index += 1
                }
            }
            guard positional.count == 1 else {
                throw ProjectFileError.invalid("Name one file of cloud results to follow again.")
            }
            let saved = try JSONDecoder().decode(
                CloudResult.self, from: Data(contentsOf: URL(filePath: positional[0])))
            var spec = saved.spec
            if let path = values["cloud"] {
                spec = try JSONDecoder().decode(CloudSpec.self, from: Data(contentsOf: URL(filePath: path)))
            }
            if let path = values["sounding"] {
                spec.sounding = try CloudSounding(
                    wyomingCSV: String(contentsOf: URL(filePath: path), encoding: .utf8))
            }
            try spec.validate()
            let result = CloudResult(spec: spec, handOver: saved.handOver)
            for line in result.summary { print(line) }
            if let path = values["cloud-results"] {
                try JSONEncoder().encode(result).write(to: URL(filePath: path), options: .withoutOverwriting)
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n\n\(usage)\n".utf8))
            return 1
        }
    }
}
