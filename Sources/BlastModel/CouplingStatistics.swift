import Foundation

/// Storage and timing observations for the coarse body/air boundary, not physical outputs.
public struct CouplingStatistics: Codable, Sendable {
    public var layout: String
    public var denseCells: Int
    public var capacityCells: Int
    public var activeTiles: Int
    public var tileCapacity: Int
    public var bytes: Int

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        layout: String,
        denseCells: Int,
        capacityCells: Int,
        activeTiles: Int,
        tileCapacity: Int,
        bytes: Int
    ) {
        self.layout = layout
        self.denseCells = denseCells
        self.capacityCells = capacityCells
        self.activeTiles = activeTiles
        self.tileCapacity = tileCapacity
        self.bytes = bytes
    }
}
