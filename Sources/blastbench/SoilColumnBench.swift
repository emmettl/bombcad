import BlastModel
import Foundation

// `blastbench soilcolumn`.
// Split from main.swift (emmettl/bombcad-work#51).

/// The layered soil column under ground points against its closed form, and its cost: the study is
/// `GroundStudies.soilColumn` in BlastModel, which `blastmodel soil-column` runs too.
func runSoilColumn() throws {
    try GroundStudies.soilColumn(CommandLine.arguments)
}
