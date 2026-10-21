import BlastModel
import Foundation

/// `blastmodel`: BombCAD's CPU studies, headless, with no Metal: what `scenebench` and
/// `blastbench` run on the CPU, on this Mac or on Linux (docs/linux.md).
@main
enum BlastModelTool {
    /// Each subcommand: what it runs, in a line, and the study that runs it.
    static let commands: [(name: String, summary: String, run: @Sendable ([String]) throws -> Void)] = [
        (
            "receiver-fixtures", "declared receiver peak/impulse pairs on uniform component fixtures",
            ReceiverLoadStudy.run
        ),
        (
            "surrogate-judge", "the façade load surrogate against a district run's saved loads",
            SurrogateBench.judge
        ),
        (
            "surrogate-extract", "the surrogate's features and a run's loads, for fitting",
            SurrogateBench.extract
        ),
        ("district-glass", "a district run's saved strips' glass, against GEER's survey", DistrictGlass.run),
        ("glass-calibrate", "the glass chances' reliability against runs and GEER", GlassCalibration.run),
        ("protect", "protective design on the surrogate, confirmed on a run's saved loads", Protect.run),
        ("infer-charge", "the charge's yield and place from arrivals (and glass)", InferCharge.run),
        (
            "soil-column", "the layered soil column against its closed form, and its cost",
            GroundStudies.soilColumn
        ),
        (
            "halfspace-calibrate", "the half-space's direct source against UFC's peak particle velocity",
            GroundStudies.halfSpaceCalibration
        ),
        (
            "craters-cooper", "the crater against H. F. Cooper's 1976 HE craters by height and ground",
            CraterStudies.cooper1976
        ),
    ]

    static func main() {
        StudyOutput.lineBuffered()
        let args = Array(CommandLine.arguments.dropFirst())
        guard let name = args.first, let command = commands.first(where: { $0.name == name }) else {
            print(
                "Usage: blastmodel <command> [options]\n\nCommands, each as scenebench or blastbench runs it:"
            )
            for command in commands { print("  \(command.name): \(command.summary)") }
            exit(args.isEmpty || args.first == "--help" ? 0 : 2)
        }
        do {
            try command.run(Array(args.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("blastmodel \(name): \(error)\n".utf8))
            exit(1)
        }
    }
}
