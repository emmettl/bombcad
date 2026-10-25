import BlastCore
import Foundation

/// `scenebench surrogate-coefficients [--terms clear-top|fitted] [--in-sight-close-in] --out terms.json`:
/// the façade surrogate's terms as JSON (the adopted ones without `--terms`), for the benches'
/// `--coefficients`; with
/// `--in-sight-close-in`, the candidate whose close-in branch is taken only in sight of the charge
/// (emmettl/bombcad-work#56).
enum SurrogateCoefficients {
    static func run(_ args: [String]) throws {
        guard let out = SurrogateBench.value(args, "out") else {
            throw BlastError.allocationFailed("--out file.json")
        }
        var coefficients = try SurrogateBench.termSet(args).coefficients
        if args.contains("--in-sight-close-in") { coefficients.closeIn?.inSightOnly = true }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(coefficients).write(to: URL(filePath: out))
        print("Wrote \(out)")
    }
}
