import Foundation
import simd

/// Glass falling from a roof meshed as shells onto the floor below, pane by pane (each glass
/// solid), by the rules the envelope's `OverheadGlassHazard` grades a roof pane by: a laminated
/// pane that cracks and keeps its elements is held; its elements removed (the interlayer torn)
/// fall together, as one piece, hazardous past 79 J; other glass removed falls as shards, hazardous
/// when the shard of its thickness that would strike with 79 J fits in the pane. Each falls from
/// where it was, its speed downward now and what gravity gives it over the drop.
public enum RoofGlassHazard {
    public struct Summary: Sendable {
        public var panes = 0
        /// Panes cracked or fragmented and held; with glass fallen; graded hazardous.
        public var held = 0
        public var fallen = 0
        public var hazardous = 0
        /// Glass fallen, kg, and its energy striking the floor, J.
        public var fallenKg = 0.0
        public var energyJ = 0.0
    }

    /// Grades the glass solids of `shells` (those of a glass material: transparent) over a floor
    /// at height `floor`.
    public static func assess(_ shells: ShellSolver, floor: Float = 0) -> Summary {
        let model = shells.model
        let mesh = shells.mesh
        var summary = Summary()
        var nodes: [ShellNode] = []
        shells.mutateNodes { nodes = Array($0) }
        let damage = shells.displayBuffer.contents().bindMemory(
            to: Float.self, capacity: max(mesh.elements.count, 1))
        var bySolid: [Int: [Int]] = [:]
        for (e, element) in mesh.elements.enumerated() where model.material(of: element.solid).isTransparent {
            bySolid[element.solid, default: []].append(e)
        }
        for (solid, elements) in bySolid.sorted(by: { $0.key < $1.key }) {
            let material = model.material(of: solid)
            let laminated = material.interlayerThickness != nil
            summary.panes += 1
            var mass = 0.0
            var energy = 0.0
            var cracked = laminated && shells.hasFragmented(solid)
            for e in elements {
                let element = mesh.elements[e]
                if !laminated && damage[e] > 0 { cracked = true }
                guard shells.flag(e) != .active else { continue }
                let corners = (0..<4).map { Int(element.nodes[$0]) }
                let height =
                    corners.reduce(Float(0)) { $0 + mesh.positions[$1].z + nodes[$1].displacement.z } / 4
                let down = corners.reduce(Float(0)) { $0 + max(-nodes[$1].velocity.z, 0) } / 4
                let impact = (Double(down * down) + 2 * 9.81 * Double(max(height - floor, 0)))
                let piece = Double(material.density * element.thickness * element.size.x * element.size.y)
                mass += piece
                energy += 0.5 * piece * impact
            }
            guard mass > 0 else {
                if cracked { summary.held += 1 }
                continue
            }
            summary.fallen += 1
            summary.fallenKg += mass
            summary.energyJ += energy
            let hazardEnergy = Double(HazardCriteria.hazardousEnergyJ)
            if laminated {
                if energy >= hazardEnergy { summary.hazardous += 1 }
            } else {
                // The shard of the glass's thickness that would strike with 79 J, against the pane.
                let perMass = energy / mass
                let glass = Double(material.density) * Double(mesh.elements[elements[0]].thickness)
                let shard = (hazardEnergy / perMass / glass).squareRoot()
                let size = elements.reduce(0.0) {
                    $0 + Double(mesh.elements[$1].size.x * mesh.elements[$1].size.y)
                }.squareRoot()
                if shard <= size { summary.hazardous += 1 }
            }
        }
        return summary
    }
}
