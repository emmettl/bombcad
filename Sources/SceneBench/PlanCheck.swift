import BlastCore
import Foundation

/// `scenebench plan-check [folder]`: the plan importer's corpus (Fixtures/FloorPlans by default,
/// `FloorPlanCorpus`), each plan read headlessly and checked against the answer expected of it;
/// exits 1 if any differs (a case recording a limitation is listed, not failed); `--verbose` lists
/// what each plan gave.
enum PlanCheck {
    static func run(_ args: [String]) throws {
        let verbose = args.contains("--verbose")
        let folder = URL(filePath: args.first { !$0.hasPrefix("--") } ?? "Fixtures/FloorPlans")
        let results = try FloorPlanCorpus.checkAll(folder: folder)
        var failed = 0
        for result in results {
            let state =
                result.failures.isEmpty ? "pass" : result.limitation != nil ? "limitation" : "FAIL"
            print(
                "\(state.padding(toLength: 10, withPad: " ", startingAt: 0)) \(result.name): \(result.summary)"
            )
            for failure in result.failures { print("             - \(failure)") }
            if verbose { for line in result.detail { print("               \(line)") } }
            if let limitation = result.limitation, !result.failures.isEmpty {
                print("             (\(limitation))")
            }
            if !result.failures.isEmpty && result.limitation == nil { failed += 1 }
        }
        print("\(results.count - failed) of \(results.count) plans as expected")
        if failed > 0 { exit(1) }
    }
}
