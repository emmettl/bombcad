import Foundation

/// Storage and timing observations for the coarse body/air boundary, not physical outputs.
public struct CouplingStatistics: Codable, Sendable {
    public var layout: String
    public var denseCells: Int
    public var capacityCells: Int
    public var activeTiles: Int
    public var tileCapacity: Int
    public var bytes: Int
}
