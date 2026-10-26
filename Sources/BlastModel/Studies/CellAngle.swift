import Foundation

/// The judges' split by the line's angle to the solver's cells (`--by-angle`;
/// emmettl/bombcad-work#107, docs/surrogate-first-look.md).
///
/// The solver's grid makes its own reference runs read peaks high on lines from the charge near a
/// cell axis, and its glass with them: at 1.1 kt, 1.75–2 km from Beirut's charge, the clear-top
/// reference blows out 0.49 of the sides on lines within 15° of an axis and 0.97 on the diagonals
/// (emmettl/bombcad-work#106). A judge over every side mixes that into the truth. With
/// `--by-angle` the judges also give each figure on the diagonal lines alone (30–45°, where the
/// grid reads closest to a free burst's diagonals) and balanced, each angle class weighted alike.
package enum CellAngle: Int, CaseIterable, Codable, Sendable {
    /// 0–15° from the nearer cell axis.
    case axis
    /// 15–30°.
    case between
    /// 30–45°: the diagonal lines.
    case diagonal

    /// The class of the line from the charge to a point `dx`, `dy` away in plan, the cells' axes
    /// being the scene's x and y.
    package init(dx: Double, dy: Double) {
        let angle = Self.degrees(dx: dx, dy: dy)
        self = angle < 15 ? .axis : angle < 30 ? .between : .diagonal
    }

    /// The angle between the line and the nearer cell axis, 0–45°.
    package static func degrees(dx: Double, dy: Double) -> Double {
        let theta = atan2(abs(dy), abs(dx)) * 180 / .pi
        return min(theta, 90 - theta)
    }

    package var label: String {
        switch self {
        case .axis: "axis (0–15°)"
        case .between: "between (15–30°)"
        case .diagonal: "diagonal (30–45°)"
        }
    }

    /// The fewest members a class needs to be given on its own or weighted in the balance (as
    /// emmettl/bombcad-work#106's tables).
    package static let fewest = 30

    /// A figure over every member, on the diagonal ones alone, and balanced: each class with
    /// `fewest` members or more weighted alike (nil where none qualifies).
    package struct Figure: Codable, Equatable, Sendable {
        package var all: Double
        package var diagonal: Double?
        package var balanced: Double?
        /// Members in each class: axis, between, diagonal.
        package var counts: [Int]
    }

    /// Each member's weight in the balance: one over its class's count, over the classes that
    /// qualify; nothing for a class with fewer than `fewest`.
    package static func weights(_ classes: [CellAngle]) -> [Double] {
        var counts = [Int](repeating: 0, count: allCases.count)
        for c in classes { counts[c.rawValue] += 1 }
        let qualifying = counts.filter { $0 >= fewest }.count
        return classes.map {
            let n = counts[$0.rawValue]
            return n >= fewest ? 1 / (Double(n) * Double(qualifying)) : 0
        }
    }

    static func counts(_ classes: [CellAngle]) -> [Int] {
        var counts = [Int](repeating: 0, count: allCases.count)
        for c in classes { counts[c.rawValue] += 1 }
        return counts
    }

    /// The mean of `values` (a share, where they are 0 or 1) over all, the diagonal and balanced.
    package static func mean(_ values: [Double], _ classes: [CellAngle]) -> Figure {
        let counts = counts(classes)
        let all = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let diagonal = values.indices.filter { classes[$0] == .diagonal }
        let w = weights(classes)
        let total = w.reduce(0, +)
        return Figure(
            all: all,
            diagonal: diagonal.count >= fewest
                ? diagonal.reduce(0) { $0 + values[$1] } / Double(diagonal.count) : nil,
            balanced: total > 0 ? zip(values, w).reduce(0) { $0 + $1.0 * $1.1 } / total : nil,
            counts: counts)
    }

    /// The median ratio of `logs` (logarithms of a ratio) over all (as the judges take it: the
    /// middle of the sorted list), the diagonal and balanced (the weighted median), as ratios.
    package static func median(_ logs: [Double], _ classes: [CellAngle]) -> Figure {
        func middle(_ l: [Double]) -> Double { exp(l.sorted()[l.count / 2]) }
        let counts = counts(classes)
        let diagonal = logs.indices.filter { classes[$0] == .diagonal }.map { logs[$0] }
        let w = weights(classes)
        let total = w.reduce(0, +)
        var balanced: Double?
        if total > 0 {
            var sum = 0.0
            for i in logs.indices.sorted(by: { logs[$0] < logs[$1] }) where w[i] > 0 {
                sum += w[i]
                if sum >= 0.5 * total * (1 - 1e-12) {
                    balanced = exp(logs[i])
                    break
                }
            }
        }
        return Figure(
            all: logs.isEmpty ? 0 : middle(logs),
            diagonal: diagonal.count >= fewest ? middle(diagonal) : nil, balanced: balanced, counts: counts)
    }

    /// A figure as "all / diagonal / balanced", with "–" where a class is too thin.
    package static func show(_ f: Figure, _ format: String = "%.2f") -> String {
        [f.all, f.diagonal, f.balanced].map { $0.map { String(format: format, $0) } ?? "–" }
            .joined(separator: " / ")
    }
}
