import Foundation
import simd

/// The damage to each house of the terraced row (`ScenarioPreset.terracedRow`), by the
/// categories the Ministry of Home Security's surveyors gave bombed British houses in the
/// Second World War, as Jarrett (1968) used them and Gilbert (Loughborough, 1994, Table 5.1)
/// sets them out:
/// - **A:** demolished, more than 75% of the external brickwork destroyed;
/// - **B:** so badly damaged as to need pulling down, 50 to 75% of it destroyed, or the rest of
///   the walls unsafe;
/// - **Cb:** uninhabitable until repaired, with the roof partly or wholly collapsed, up to 25% of
///   one or two external walls demolished, load-bearing partitions badly damaged;
/// - **Ca:** uninhabitable until repaired, with relatively minor structural damage;
/// - **D:** habitable, with ceilings, tiles, battens and roof coverings damaged, minor cracks in
///   the walls, some glass broken.
///
/// The model's measures, and the thresholds that turn them into a category (the surveyors'
/// words are not numbers, so the thresholds are this model's reading of them):
/// - **Destroyed brickwork:** the share of the external walls' elements (both leaves of the
///   front, back and gables) removed, or moved since the row came to rest by more than a leaf's
///   thickness, past which a cracked leaf can no longer stand. A from 75%, B from 25% (the
///   surveyors' "unsafe" for more than Cb's quarter).
/// - **Collapse of a floor or the roof:** a quarter of its joists' seats lost or more, or the
///   plate fallen more than 0.3 m: Cb, as is any destroyed brickwork from 2%.
/// - **Structural damage:** 5% or more of the external walls cracked through (damage 1), or a
///   joist off its seat: Ca.
/// - **Roof covering and cracks:** 1% or more of the covering over the house lifted or moved
///   more than 0.1 m, or any external wall cracked through: D.
public struct TerracedRowDamage: Sendable {
    public enum Category: String, Sendable, Comparable, CaseIterable {
        case none
        case d = "D"
        case ca = "Ca"
        case cb = "Cb"
        case b = "B"
        case a = "A"

        public static func < (a: Self, b: Self) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    public struct House: Sendable {
        /// Shares of the external walls' elements destroyed and cracked through (damage 1).
        public var destroyed = 0.0
        public var cracked = 0.0
        /// Share of the front wall's elements destroyed (both leaves; those facing the charge).
        public var frontDestroyed = 0.0
        /// Per floor and the roof, ground up: the share of its joists off their seats, and how
        /// far its plate has fallen on average, m.
        public var seatsLost: [Double] = []
        public var fallen: [Float] = []
        /// Share of the covering over the house lifted or moved.
        public var coveringMoved = 0.0

        public var category: Category {
            if destroyed >= 0.75 { return .a }
            if destroyed >= 0.25 { return .b }
            let collapsed = zip(seatsLost, fallen).contains { $0 >= 0.25 || $1 > 0.3 }
            if collapsed || destroyed >= 0.02 { return .cb }
            if cracked >= 0.05 || seatsLost.contains(where: { $0 > 0 }) { return .ca }
            if coveringMoved >= 0.01 || cracked > 0 { return .d }
            return .none
        }
    }

    public var houses: [House]

    /// Solids, in the order `terracedRow` builds them: the eight leaves of the external walls,
    /// the two party walls, two plates (floor and roof) per house, then the covering.
    static let externalLeaves = 0..<8
    static let frontLeaves = 0..<2
    static let partyWalls = 8..<10
    static let platesPerHouse = 2

    /// Judges `shells`, the row's body, against `rest`, each node's displacement once the row had
    /// settled.
    public init(shells: ShellSolver, rest: [SIMD3<Float>]) {
        let model = shells.model
        let mesh = shells.mesh
        let party = Self.partyWalls.map { 0.5 * (model.solids[$0].min.y + model.solids[$0].max.y) }
        let edges = [-Float.infinity] + party + [Float.infinity]
        func house(_ y: Float) -> Int { (0..<3).first { y >= edges[$0] && y < edges[$0 + 1] } ?? 0 }
        var moved = [SIMD3<Float>](repeating: .zero, count: rest.count)
        shells.mutateNodes { nodes in
            for n in nodes.indices where n < rest.count { moved[n] = nodes[n].displacement - rest[n] }
        }
        let damage = shells.displayBuffer.contents().bindMemory(
            to: Float.self, capacity: max(mesh.elements.count, 1))
        let coveringSolid =
            model.solids.count > Self.partyWalls.upperBound + 3 * Self.platesPerHouse
            ? Self.partyWalls.upperBound + 3 * Self.platesPerHouse : nil
        var walls = [(total: Int, destroyed: Int, cracked: Int)](repeating: (0, 0, 0), count: 3)
        var fronts = [(total: Int, destroyed: Int)](repeating: (0, 0), count: 3)
        var covering = [(total: Int, moved: Int)](repeating: (0, 0), count: 3)
        var plateDrop = [[(sum: Float, count: Int)]](
            repeating: [(0, 0), (0, 0)], count: 3)
        for (e, element) in mesh.elements.enumerated() {
            let corners = (0..<4).map { Int(element.nodes[$0]) }
            let centre = corners.reduce(SIMD3<Float>.zero) { $0 + mesh.positions[$1] } / 4
            let shift = corners.reduce(SIMD3<Float>.zero) { $0 + moved[$1] } / 4
            let h = house(centre.y)
            let removed = shells.flag(e) != .active
            if Self.externalLeaves.contains(element.solid) {
                walls[h].total += 1
                let front = Self.frontLeaves.contains(element.solid)
                if front { fronts[h].total += 1 }
                if removed || simd_length(shift) > element.thickness {
                    walls[h].destroyed += 1
                    if front { fronts[h].destroyed += 1 }
                } else if damage[e] >= 1 {
                    walls[h].cracked += 1
                }
            } else if element.solid == coveringSolid {
                covering[h].total += 1
                if removed || simd_length(shift) > 0.1 { covering[h].moved += 1 }
            } else if element.solid >= Self.partyWalls.upperBound {
                let plate = element.solid - Self.partyWalls.upperBound
                let level = plate % Self.platesPerHouse
                // A removed element counts as fallen a metre.
                plateDrop[plate / Self.platesPerHouse][level].sum += removed ? 1 : -shift.z
                plateDrop[plate / Self.platesPerHouse][level].count += 1
            }
        }
        // Seats: after the four walls' ties, two per plate in the plates' order.
        houses = (0..<3).map { h in
            var result = House()
            let wall = walls[h]
            result.destroyed = wall.total > 0 ? Double(wall.destroyed) / Double(wall.total) : 0
            result.cracked = wall.total > 0 ? Double(wall.cracked) / Double(wall.total) : 0
            let front = fronts[h]
            result.frontDestroyed = front.total > 0 ? Double(front.destroyed) / Double(front.total) : 0
            for level in 0..<Self.platesPerHouse {
                let plate = h * Self.platesPerHouse + level
                var pairs = 0
                var lost = 0
                for side in 0..<2 {
                    guard let part = shells.pairSummary(support: 4 + 2 * plate + side) else { continue }
                    pairs += part.pairs
                    lost += part.unseated
                }
                result.seatsLost.append(pairs > 0 ? Double(lost) / Double(pairs) : 0)
                let drop = plateDrop[h][level]
                result.fallen.append(drop.count > 0 ? drop.sum / Float(drop.count) : 0)
            }
            let roofing = covering[h]
            result.coveringMoved = roofing.total > 0 ? Double(roofing.moved) / Double(roofing.total) : 0
            return result
        }
    }
}
