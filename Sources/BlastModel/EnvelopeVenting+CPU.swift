import Foundation
import simd

/// Envelope venting's results so far (`BlastSolver.envelopeVentingSnapshot()`).
public struct EnvelopeVentingSnapshot: Codable, Sendable {
    public struct Pane: Codable, Sendable {
        public var component: String
        public var owner: UUID
        /// When its glass broke and its cells opened, s; nil while whole.
        public var brokenAtS: Double?
        /// Its deflection now (at breaking, once broken), m, positive inward.
        public var deflectionM: Double

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            component: String,
            owner: UUID,
            brokenAtS: Double? = nil,
            deflectionM: Double
        ) {
            self.component = component
            self.owner = owner
            self.brokenAtS = brokenAtS
            self.deflectionM = deflectionM
        }
    }

    public struct Room: Codable, Sendable {
        public var owner: UUID
        public var volumeM3: Double
        /// The room's mean overpressure: its peak (Pa) and positive impulse (Pa s).
        public var peakPa: Double
        public var impulsePaS: Double

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            owner: UUID,
            volumeM3: Double,
            peakPa: Double,
            impulsePaS: Double
        ) {
            self.owner = owner
            self.volumeM3 = volumeM3
            self.peakPa = peakPa
            self.impulsePaS = impulsePaS
        }
    }

    /// A wall, roof or slab that can fail, and when it did and its cells opened (nil while it stands).
    public struct Wall: Codable, Sendable {
        public var component: String
        public var owner: UUID
        public var failedAtS: Double?

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            component: String,
            owner: UUID,
            failedAtS: Double? = nil
        ) {
            self.component = component
            self.owner = owner
            self.failedAtS = failedAtS
        }
    }

    public var panes: [Pane]
    public var rooms: [Room]
    public var walls: [Wall] = []
    /// A hole through a wall, roof or slab (a column of its cells), and when it opened; `cause`
    /// "fragments" (perforated) or "breach" (UFC 3-340-02's breach threshold).
    public struct Hole: Codable, Sendable {
        public var component: String
        public var owner: UUID
        public var cells: Int
        public var openedAtS: Double?
        public var cause: String

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            component: String,
            owner: UUID,
            cells: Int,
            openedAtS: Double? = nil,
            cause: String
        ) {
            self.component = component
            self.owner = owner
            self.cells = cells
            self.openedAtS = openedAtS
            self.cause = cause
        }
    }

    public var holes: [Hole] = []
    /// Each concrete component's worst close-in outcome by UFC 3-340-02's threshold curves
    /// ("spalled", "breached"), by id; none listed where neither.
    public var closeIn: [String: String] = [:]

    /// Whether `history` is still the component's load though its faces changed: a pane's, or a
    /// failed wall's, whose faces open with it (its history up to then is its load); or a holed
    /// one's, whose faces round the hole read the air going through.
    public func keeps(_ history: EnvelopeComponentHistory) -> Bool {
        history.component.kind == .pane
            || walls.contains { $0.component == history.component.id && $0.failedAtS != nil }
            || holes.contains { $0.component == history.component.id && $0.openedAtS != nil }
    }

    /// Each building's inside: the worst of its rooms by peak, or nil without rooms.
    public func inside(of owner: UUID) -> Room? {
        rooms.filter { $0.owner == owner }.max { $0.peakPa < $1.peakPa }
    }

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        panes: [Pane],
        rooms: [Room],
        walls: [Wall] = [],
        holes: [Hole] = [],
        closeIn: [String: String] = [:]
    ) {
        self.panes = panes
        self.rooms = rooms
        self.walls = walls
        self.holes = holes
        self.closeIn = closeIn
    }
}
