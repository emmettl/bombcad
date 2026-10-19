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

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            panes: Int = 0,
            held: Int = 0,
            fallen: Int = 0,
            hazardous: Int = 0,
            fallenKg: Double = 0.0,
            energyJ: Double = 0.0
        ) {
            self.panes = panes
            self.held = held
            self.fallen = fallen
            self.hazardous = hazardous
            self.fallenKg = fallenKg
            self.energyJ = energyJ
        }
    }
}
