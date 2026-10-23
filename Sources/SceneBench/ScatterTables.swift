import BlastCore
import Foundation

/// The networks' own peak scatter for the bench's `@own` and `--own-scatter`
/// (emmettl/bombcad-work#69): `LearnedField.Scatter.measured` by the weights' file name, or with
/// `--scatter-tables tables.json` the tables in that file, to judge tables measured otherwise
/// before they are written into the code. The file maps a weights file's name to
/// `{"ground": [front, side, back], "upper": …}`, each facing six log-SDs for the bands to Z 7, 10,
/// 14, 20, 28 and beyond (`scatter2m.py` writes it); a level left out or null keeps the
/// surrogate's scatter there.
enum ScatterTables {
    struct Entry: Decodable {
        var ground: [[Double]]?
        var upper: [[Double]]?
    }

    static func measured(forWeights path: String, _ args: [String]) throws -> LearnedField.Scatter? {
        let name = URL(filePath: path).lastPathComponent
        guard let file = SurrogateBench.value(args, "scatter-tables") else {
            return LearnedField.Scatter.measured(forWeights: name)
        }
        let tables = try JSONDecoder().decode(
            [String: Entry].self, from: Data(contentsOf: URL(filePath: file)))
        guard let entry = tables[name] else { return nil }
        func bands(_ byFacing: [[Double]]?) throws -> [[LearnedField.Scatter.Band]]? {
            try byFacing.map { facings in
                guard facings.count == 3, facings.allSatisfy({ $0.count == 6 }) else {
                    throw BlastError.allocationFailed("\(file): \(name) wants three facings of six bands")
                }
                return facings.map { values in
                    zip([7, 10, 14, 20, 28, Double.infinity], values).map {
                        LearnedField.Scatter.Band(upToZ: $0, peak: $1)
                    }
                }
            }
        }
        return LearnedField.Scatter(ground: try bands(entry.ground), upper: try bands(entry.upper))
    }
}
