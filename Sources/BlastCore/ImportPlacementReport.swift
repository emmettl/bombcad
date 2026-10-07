import Foundation
import simd

/// Advisory checks of the sampled volumes. Contact is geometric, not a support validation.
public struct ImportPlacementReport: Sendable, Hashable {
    public struct Issue: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable { case overlap, blockedCharge, floating, disconnected }
        public var kind: Kind
        public var bounds: Box
        public var detail: String
        public var id: Self { self }
        public var title: String {
            switch kind {
            case .overlap: "Overlapping geometry"
            case .blockedCharge: "Charge inside imported geometry"
            case .floating: "No ground or geometry contact"
            case .disconnected: "Disconnected sampled component"
            }
        }
        public var isCritical: Bool { kind == .blockedCharge }
    }
    public var issues: [Issue]
    public var componentCount: Int
    public var contextVolumes: [Box]
    public var checksIncomplete: Bool
    public var warnings: [String] {
        var result = [
            "Placement checks use sampled volumes. Geometric contact does not establish a structural connection or validate supports. Separate components and overlaps can be intentional."
        ]
        if checksIncomplete {
            result.append(
                "Placement checks or their highlights reached the work limit. Some contacts or overlaps may be absent from this report."
            )
        }
        return result
    }
    struct Subtraction {
        var boxes: [Box]
        var complete: Bool
    }
    static func subtracting(_ openings: [Box], from solid: Box, limit: Int) -> Subtraction {
        var parts = [solid]
        for opening in openings {
            var next: [Box] = []
            for part in parts {
                guard let cut = intersection(part, opening) else {
                    next.append(part)
                    continue
                }
                var middle = part
                for axis in 0..<3 {
                    if middle.min[axis] < cut.min[axis] {
                        var slab = middle
                        slab.max[axis] = cut.min[axis]
                        next.append(slab)
                        middle.min[axis] = cut.min[axis]
                    }
                    if middle.max[axis] > cut.max[axis] {
                        var slab = middle
                        slab.min[axis] = cut.max[axis]
                        next.append(slab)
                        middle.max[axis] = cut.max[axis]
                    }
                }
                if next.count > limit {
                    return Subtraction(boxes: Array(next.prefix(limit)), complete: false)
                }
            }
            if next.count > limit { return Subtraction(boxes: Array(next.prefix(limit)), complete: false) }
            parts = next
        }
        return Subtraction(boxes: parts, complete: true)
    }
    private static func intersection(_ a: Box, _ b: Box) -> Box? {
        let lo = simd_max(a.min, b.min)
        let hi = simd_min(a.max, b.max)
        return all(lo .< hi) ? Box(min: lo, max: hi) : nil
    }
    /// A face contact joins sampled components; edge/corner contact alone is insufficient.
    private static func contact(_ a: Box, _ b: Box, tolerance: Float) -> Bool {
        let span = simd_min(a.max, b.max) - simd_max(a.min, b.min)
        var wide = 0
        for axis in 0..<3 {
            if span[axis] < -tolerance { return false }
            if span[axis] > tolerance { wide += 1 }
        }
        return wide >= 2
    }
    public static func analyze(
        boxes: [Box], scenario: Scenario, editingID: UUID? = nil, cellSize: Float, fixedBase: Bool? = nil
    ) throws -> Self {
        guard cellSize.isFinite, cellSize > 0, boxes.count <= 2048 else {
            throw ImportedMesh.ImportError.invalid("Placement check exceeds geometry limits.")
        }
        try Task.checkCancellation()
        let tolerance = cellSize * 1e-4
        var incomplete = false
        var environment: [Box] = []
        func addEnvironment(_ boxes: [Box]) {
            let remaining = max(0, 4096 - environment.count)
            if boxes.count > remaining { incomplete = true }
            environment += boxes.prefix(remaining)
        }
        addEnvironment(scenario.boxes)
        for model in scenario.importedModels ?? []
        where model.isAttached && model.behavior == .rigid && model.id != editingID {
            addEnvironment(model.preview.boxes)
        }
        let editing = scenario.importedModels?.first { $0.id == editingID && $0.isAttached }
        if editing?.behavior != .deformable, let body = scenario.structure {
            for solid in body.solids {
                try Task.checkCancellation()
                let fragments = subtracting(body.openings, from: solid, limit: 4096)
                incomplete = incomplete || !fragments.complete
                addEnvironment(fragments.boxes)
                if environment.count >= 4096 {
                    incomplete = true
                    break
                }
            }
        }
        var issues: [Issue] = []
        func add(_ kind: Issue.Kind, _ bounds: Box, _ detail: String) {
            var issue = Issue(kind: kind, bounds: bounds, detail: detail)
            if kind == .overlap {
                var n = 0
                while n < issues.count {
                    let old = issues[n]
                    if old.kind == kind
                        && all(old.bounds.min .<= issue.bounds.max + SIMD3(repeating: tolerance))
                        && all(issue.bounds.min .<= old.bounds.max + SIMD3(repeating: tolerance))
                    {
                        issue.bounds = Box(
                            min: simd_min(old.bounds.min, issue.bounds.min),
                            max: simd_max(old.bounds.max, issue.bounds.max))
                        issues.remove(at: n)
                        n = 0
                    } else {
                        n += 1
                    }
                }
            }
            if issues.count < 128 { issues.append(issue) } else { incomplete = true }
        }
        for (index, charge) in ([scenario.charge] + (scenario.additionalCharges ?? [])).enumerated() {
            if boxes.contains(where: { $0.contains(charge.position) }) {
                let radius = SIMD3<Float>(repeating: cellSize * 0.5)
                add(
                    .blockedCharge, Box(min: charge.position - radius, max: charge.position + radius),
                    "Charge \(index+1) lies inside an occupied imported volume. Move the charge or the model before running; the charge may release no energy into the air."
                )
            }
        }
        for (n, box) in boxes.enumerated() {
            if n % 16 == 0 { try Task.checkCancellation() }
            for other in environment {
                if let overlap = intersection(box, other) {
                    add(
                        .overlap, overlap,
                        "The imported volume intersects existing rigid or structural geometry. Review double geometry or intentional joints; this highlight is an approximate union of overlap regions."
                    )
                }
            }
        }
        var parent = Array(boxes.indices)
        func root(_ index: Int) -> Int {
            var n = index
            while parent[n] != n {
                parent[n] = parent[parent[n]]
                n = parent[n]
            }
            return n
        }
        for i in boxes.indices {
            if i % 16 == 0 { try Task.checkCancellation() }
            for j in 0..<i where contact(boxes[i], boxes[j], tolerance: tolerance) {
                let a = root(i)
                let b = root(j)
                if a != b { parent[a] = b }
            }
        }
        var components: [Int: [Box]] = [:]
        for i in boxes.indices { components[root(i), default: []].append(boxes[i]) }
        let ordered = components.values.sorted {
            func volume(_ list: [Box]) -> Float { list.reduce(0) { $0 + $1.size.x * $1.size.y * $1.size.z } }
            let a = volume($0)
            let b = volume($1)
            if a != b { return a > b }
            let first = $0[0].min
            let second = $1[0].min
            for axis in 0..<3 where first[axis] != second[axis] { return first[axis] < second[axis] }
            return false
        }
        let lowest = boxes.map { $0.min.z }.min() ?? 0
        for (index, component) in ordered.enumerated() {
            try Task.checkCancellation()
            let bounds = component.dropFirst().reduce(component[0]) {
                Box(min: simd_min($0.min, $1.min), max: simd_max($0.max, $1.max))
            }
            if index > 0 {
                add(
                    .disconnected, bounds,
                    "Component \(index+1) of \(ordered.count) does not share an occupied face with the largest sampled component. Separate buildings can be intentional; check for lost connecting features."
                )
            }
            let grounded = component.contains { $0.min.z <= tolerance }
            let touching = component.contains { box in
                environment.contains { contact(box, $0, tolerance: tolerance) }
            }
            if !grounded && !touching {
                var detail =
                    "This sampled component has no ground or surrounding-geometry contact in the checked volumes. Review its placement and support assumptions."
                if let fixedBase {
                    if fixedBase && abs(bounds.min.z - lowest) <= tolerance {
                        detail +=
                            " Fixed base holds the model's lowest nodes here; verify that this is intended."
                    } else if fixedBase {
                        detail +=
                            " Fixed base acts at the model's lowest plane and may not hold this elevated component."
                    } else {
                        detail += " Fixed base is off."
                    }
                } else {
                    detail += " Rigid obstacles remain fixed at their imported position."
                }
                add(.floating, bounds, detail)
            }
        }
        return Self(
            issues: issues, componentCount: ordered.count, contextVolumes: environment,
            checksIncomplete: incomplete)
    }
}
