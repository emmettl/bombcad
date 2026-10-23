import BlastCore
import Foundation

/// `BombCAD field-model check [--cells N] [--ground file.bcfw] [--levels file.bcfw]`: whether the
/// learned field model runs on this Mac (`LearnedFieldCheck`). It loads the downloaded weights (or
/// those named), runs each network twice on a built-in district of N × N 4 m cells (1,250 unless
/// given) and prints the GPU, its recommended working set, the times and the peak memory, and
/// whether it fits. Exits 0 if it fits, 1 if it does not or cannot run, 2 without the weights.
/// The app's **Check on this Mac** runs this in a process of its own.
enum HeadlessFieldModel {
    static let usage =
        "usage: BombCAD field-model check [--cells N] [--ground field-unet-fp-strict.bcfw] [--levels field-unet-l4-strict.bcfw]"

    @MainActor static func main(_ arguments: [String]) -> Int32 {
        guard arguments.first == "check" else {
            print(usage)
            return 2
        }
        var cells = LearnedFieldCheck.defaultCells
        var ground = LearnedField.weightsURL(
            setting: UserDefaults.standard.string(forKey: SimulationModel.learnedWeightsKey))
        var levels: URL?
        var rest = arguments.dropFirst()
        while let flag = rest.popFirst() {
            guard let value = rest.popFirst() else {
                print(usage)
                return 2
            }
            switch flag {
            case "--cells":
                guard let n = Int(value), (16...4096).contains(n) else {
                    print("--cells takes 16 to 4096")
                    return 2
                }
                cells = n
            case "--ground": ground = URL(filePath: (value as NSString).expandingTildeInPath)
            case "--levels": levels = URL(filePath: (value as NSString).expandingTildeInPath)
            default:
                print(usage)
                return 2
            }
        }
        guard FileManager.default.fileExists(atPath: ground.path) else {
            print(
                "No learned field model's weights at \(ground.path): turn the option on in the app to download them, or give --ground."
            )
            return 2
        }
        if levels == nil {
            let beside = LearnedField.levelsWeightsURL(ground: ground)
            levels = FileManager.default.fileExists(atPath: beside.path) ? beside : nil
        }
        print(
            levels == nil
                ? "Field model 1: \(ground.path) (no levels network beside it)."
                : "Field model 2: \(ground.path) and \(levels!.path).")
        let report = LearnedFieldCheck.run(ground: ground, levels: levels, cells: cells)
        for line in report.lines { print(line) }
        return report.fits ? 0 : 1
    }
}
