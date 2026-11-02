import Foundation
import simd

/// The explorer's words (emmettl/bombcad-work#114; docs/explorer.md): what each layer shows, for
/// someone who knows nothing about blast, and how sure the model is, from each layer's standing.
/// The figures are the standing table's (`ValidationTables`), so the words move with the record.
public enum ExplorerWords {
    /// The explorer's layers, in the order its strip steps through them.
    public enum Layer: String, CaseIterable, Sendable, Identifiable {
        case wave, glass, walls, people, fire

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .wave: "The wave"
            case .glass: "The glass"
            case .walls: "The walls"
            case .people: "The people"
            case .fire: "The fire"
            }
        }

        /// The layer's standing (docs/standing.md): the quick estimate's glass an approximation
        /// against BombCAD's own runs, the rest illustrative.
        public var level: EvidenceLevel {
            switch self {
            case .glass: .approximation
            case .wave, .walls, .people, .fire: .illustrative
            }
        }
    }

    /// The opening line, under the scenes' cards.
    public static let intro =
        "Everything here is a quick estimate that answers as you move things. Each layer says how sure it is."

    /// The prompt before the charge is placed.
    public static let placePrompt = "Click where the charge goes, or choose a place."

    /// What the explorer leaves out, and why.
    public static let leftOut =
        "Not shown: the fireball, buildings coming down and their dust. These need the full simulation."

    /// While the full estimate follows a preview.
    public static let refining = "Refining… the full estimate takes a few seconds."
    public static let refined = "Refined."

    /// Why film shows no change in the people hurt.
    public static let filmAndPeople =
        "Film cracks as plain glass does but holds the pieces together. The people estimate counts broken "
        + "panes, not where the glass goes, so it cannot show film helping the people inside."

    /// A standing level in plain words.
    public static func standing(_ level: EvidenceLevel) -> String {
        switch level {
        case .compared: "Checked against measurements from real tests."
        case .verified: "Checked against textbook solutions, not real events."
        case .approximation: "A recognised method; how close it comes here is not known exactly."
        case .illustrative: "A sketch to show the idea, not a prediction."
        }
    }

    /// What the layer shows, in a sentence or two.
    public static func what(_ layer: Layer) -> String {
        switch layer {
        case .wave:
            "The charge pushes the air outwards in a thin wall of high pressure, faster than sound. "
                + "Colours show how hard it pushes: yellow is strongest. Buildings in the way cast a shadow, "
                + "and behind them the push is weaker."
        case .glass:
            "Windows are the first thing to go, and the furthest out. Near the charge most are blown in. "
                + "Further away some crack and some hold."
        case .walls:
            "Most walls stand. Close to the charge, weaker walls can crack or be pushed in. Brick suffers "
                + "more than reinforced concrete."
        case .people:
            "Most people hurt by a blast are indoors, hurt by flying glass. Colours show where people are "
                + "most likely to be hurt."
        case .fire:
            "A blast can start fires, and broken windows let them spread from one building to the next. "
                + "Here fires start in the buildings nearest the charge, to show how far they could travel "
                + "over the next 12 hours. Concrete and stone rarely carry a fire. Wood does, and wind "
                + "carries sparks."
        }
    }

    /// How sure the model is, its standing first. `refinedWave`: the wave carries its learned
    /// refinement.
    public static func howSure(_ layer: Layer, refinedWave: Bool = true) -> String {
        let lead = standing(layer.level)
        switch layer {
        case .wave:
            let sight = ValidationTables.figure(
                refinedWave ? "liveWaveLearnedPeakSight" : "liveWavePeakSight")
            let shielded = ValidationTables.figure(
                refinedWave ? "liveWaveLearnedPeakShielded" : "liveWavePeakShielded")
            return lead + " Against our detailed simulations of Beirut, it was within a quarter of their "
                + "strength at about \(places(sight.low)) in the open and \(places(shielded.low)) behind buildings."
        case .glass:
            let sides = ValidationTables.figure("surrogateGlassSides")
            return lead + " This quick look matches our detailed simulation for "
                + "\(inTen(sides.low)) to \(inTen(sides.high)) building sides in 10. At Beirut, that "
                + "simulation broke glass about as far out as observers reported."
        case .walls:
            let concrete = ValidationTables.figure("surrogateConcrete")
            let stone = ValidationTables.figure("surrogateStone")
            let low = min(concrete.low, stone.low)
            let high = max(concrete.high, stone.high)
            return lead + " It agrees with our detailed simulation for only \(share(low)) to "
                + "\(share(high)) of the damaged walls. To know a particular building, run the "
                + "full simulation."
        case .people:
            return lead
                + " At Beirut, this kind of estimate put the people hurt at about the right distances "
                + "from the port, but counted four to twelve times too many. So it shows where, and how much a "
                + "change helps, never how many."
        case .fire:
            return lead + " It is built from a fire-spread model made for New Zealand's fire service. Nobody "
                + "knows which buildings catch first. At Beirut no fire spread through the city, and the model "
                + "agrees."
        }
    }

    /// The layer's legend, from its lowest colour to its highest.
    public static func legend(_ layer: Layer) -> [String] {
        switch layer {
        case .wave: ["Weaker push", "Stronger push"]
        case .glass: ["Windows hold", "Some break", "Blown in"]
        case .walls: ["Walls stand", "Damage possible", "Damage likely"]
        case .people: ["Fewer hurt", "More hurt"]
        case .fire: ["Fire unlikely", "Fire likely"]
        }
    }

    /// The safety rings, and how sure.
    public static let rings =
        "The blue rings show how far safety rules keep the public back from a charge of this size. They are "
        + "rules, not predictions of damage. In the open, eardrums can be hurt inside the amber ring."
    public static let ringsHowSure =
        standing(.approximation) + " Its injury curves come largely from tests on animals."

    // MARK: Sizes

    /// The charge's sizes offered as steps, kg of TNT; the slider takes any between.
    public static let steps: [Float] = [50, 500, 5_000, 500_000]
    public static let massRange: ClosedRange<Float> = 50...500_000

    /// A step's label, short for its button: "500 kg", "5 t".
    public static func stepText(_ kg: Float) -> String {
        kg < 1_000 ? massText(kg) : String(format: "%.0f t", kg / 1_000)
    }

    /// A mass in plain words: "500 kg", "5 tonnes", "500 tonnes".
    public static func massText(_ kg: Float) -> String {
        func figure(_ x: Float) -> String { x >= 10 ? String(format: "%.0f", x) : String(format: "%.2g", x) }
        if kg < 1_000 { return "\(figure(kg)) kg" }
        let t = kg / 1_000
        return t == 1 ? "1 tonne" : "\(figure(t)) tonnes"
    }

    /// The same, to be spoken: "500 kilograms".
    public static func massSpoken(_ kg: Float) -> String {
        massText(kg).replacingOccurrences(of: " kg", with: " kilograms")
    }

    // MARK: Plain numbers

    /// A share as N in 10.
    static func inTen(_ x: Double) -> String { "\(min(10, max(0, Int((x * 10).rounded()))))" }

    /// A share of places: "about 9 places in 10", "19 places in 20".
    static func places(_ x: Double) -> String {
        if x >= 0.945 && x < 0.995 { return "19 places in 20" }
        return "\(inTen(x)) places in 10"
    }

    /// A share in words: "a quarter", "three fifths"; the nearest of the common fractions.
    static func share(_ x: Double) -> String {
        let fractions: [(Double, String)] = [
            (0.1, "a tenth"), (0.2, "a fifth"), (0.25, "a quarter"), (1.0 / 3, "a third"),
            (0.4, "two fifths"),
            (0.5, "a half"), (0.6, "three fifths"), (2.0 / 3, "two thirds"), (0.75, "three quarters"),
            (0.8, "four fifths"), (0.9, "nine tenths"),
        ]
        return fractions.min { abs($0.0 - x) < abs($1.0 - x) }!.1
    }

    /// A distance in plain words, rounded: "about 180 m".
    public static func distanceText(_ m: Double) -> String {
        let step: Double = m >= 1_000 ? 100 : m >= 100 ? 10 : 5
        let rounded = max(step, (m / step).rounded() * step)
        return rounded >= 1_000
            ? String(format: "%.1f km", rounded / 1_000) : String(format: "%.0f m", rounded)
    }

    /// A time in plain words: "300 milliseconds", "1.2 seconds".
    public static func timeText(_ s: Double) -> String {
        s < 1
            ? String(format: "%.0f milliseconds", (s * 1000 / 10).rounded() * 10)
            : String(format: "%.1f seconds", s)
    }
}

// MARK: How far the windows break

/// How far out from the charge windows break, from the quick estimate's glass chances: the
/// furthest distance at which, over the sides from four fifths of it to it, a side is more likely
/// than not to have some glass broken (and blown in).
public struct ExplorerReach: Sendable, Equatable {
    /// Out to here, sides are more likely than not to have some glass broken; nil where none is.
    public var windowsBreakM: Double?
    /// Out to here, more likely than not blown in; nil where none is.
    public var blownInM: Double?
    /// The furthest side judged, m.
    public var furthestM: Double

    public init(sides: [FacadeLoadSurrogate.SideGlass]) {
        let sorted = sides.sorted { $0.distanceM < $1.distanceM }
        furthestM = sorted.last?.distanceM ?? 0
        windowsBreakM = Self.reach(sorted, \.someBroken)
        blownInM = Self.reach(sorted, \.blownOut)
    }

    public init(windowsBreakM: Double?, blownInM: Double?, furthestM: Double) {
        self.windowsBreakM = windowsBreakM
        self.blownInM = blownInM
        self.furthestM = furthestM
    }

    /// The furthest side's distance d at which the mean chance over the sides in [0.8 d, d] is at
    /// least a half.
    static func reach(
        _ sorted: [FacadeLoadSurrogate.SideGlass], _ chance: KeyPath<FacadeLoadSurrogate.SideGlass, Double>
    )
        -> Double?
    {
        var sums = [0.0]
        for side in sorted { sums.append(sums.last! + side[keyPath: chance]) }
        var low = 0
        var best: Double?
        for (k, side) in sorted.enumerated() {
            while sorted[low].distanceM < 0.8 * side.distanceM { low += 1 }
            let mean = (sums[k + 1] - sums[low]) / Double(k + 1 - low)
            if mean >= 0.5 { best = side.distanceM }
        }
        return best
    }

    /// Whether windows still break at the scene's far edge.
    public var beyondScene: Bool { (windowsBreakM ?? 0) >= 0.95 * furthestM && furthestM > 0 }

    /// "Windows break out to about 180 m from the charge; most are blown in to about 60 m."
    public var sentence: String {
        guard let windows = windowsBreakM else { return "Few windows are likely to break." }
        var line =
            beyondScene
            ? "Windows break even at the far edge of the scene, \(ExplorerWords.distanceText(furthestM)) away"
            : "Windows break out to about \(ExplorerWords.distanceText(windows)) from the charge"
        if let blown = blownInM {
            line += "; most are blown in to about \(ExplorerWords.distanceText(blown))."
        } else {
            line += "; few are blown right in."
        }
        return line
    }

    /// The charge made `ratio` times larger: how much further the windows break, and why it is not
    /// `ratio` times as far (distances grow with the charge's cube root).
    public static func scaled(from before: ExplorerReach, to after: ExplorerReach, ratio: Double) -> String {
        let cube = pow(ratio, 1.0 / 3)
        let rule = String(
            format:
                "Blast distances grow with the cube root of the charge, so %@ the charge reaches about %.2f times as far.",
            ratio == 2 ? "twice" : ratio == 0.5 ? "half" : String(format: "%.3g times", ratio), cube)
        // How far windows break, or, where that reaches the scene's edge, how far they are blown in.
        func within(_ m: Double?, _ reach: ExplorerReach) -> Double? {
            m.flatMap { $0 < 0.95 * reach.furthestM ? $0 : nil }
        }
        let distances: (a: Double, b: Double, what: String)
        if let a = within(before.windowsBreakM, before), let b = within(after.windowsBreakM, after) {
            distances = (a, b, "Windows now break out to about")
        } else if let a = within(before.blownInM, before), let b = within(after.blownInM, after) {
            distances = (a, b, "Windows break right across the scene; they are now blown in out to about")
        } else {
            return
                "Windows break right across the scene either way, so the scene is too small to show the change. "
                + rule
        }
        let change = distances.b / distances.a - 1
        let how: String
        if abs(change) < 0.05 {
            how = "about the same distance"
        } else if change > 0 {
            how = "about \(ExplorerWords.share(change)) further"
        } else {
            how = "about \(ExplorerWords.share(-change)) less far"
        }
        var line =
            "\(distances.what) \(ExplorerWords.distanceText(distances.b)), against "
            + "\(ExplorerWords.distanceText(distances.a)) before: \(how)"
        if ratio == 2 && change > 0 { line += ", not twice as far" }
        return line + ". " + rule
    }
}

// MARK: Pinned and compared

/// The colours the explorer adds: better, the same or worse than the pinned picture, from codes the
/// renderer already draws (`EnvelopeDamageColour`'s blue, `EnvelopeDoubtColour`'s grey and orange).
public enum ExplorerColours {
    public static let better = 2
    /// A warm grey of the explorer's own (code 11 in Render.metal), apart from the blue for better in
    /// either appearance; the doubt palette's cool grey read as lilac beside it under the wave.
    public static let same = 11
    public static let worse = EnvelopeDoubtColour.first + 1
    public static var betterColour: SIMD3<Float> { EnvelopeDamageColour.palette[better - 1] }
    public static let sameColour = SIMD3<Float>(0.600, 0.580, 0.540)
    public static var worseColour: SIMD3<Float> { EnvelopeDoubtColour.palette[1] }

    /// The explorer's scale for chances, from a pale neutral for none to a loud red for the most, so
    /// that the worst reads as the worst; the workbench's ramp ends dark (`EnvelopeChanceColour.ramp`),
    /// which someone new reads as nothing happening. Codes on it are the ramp's plus `warmOffset`
    /// (Render.metal; a test keeps the two the same).
    public static let warmRamp: [SIMD3<Float>] = [
        SIMD3(0.930, 0.925, 0.900), SIMD3(0.996, 0.894, 0.596), SIMD3(0.996, 0.800, 0.400),
        SIMD3(0.992, 0.682, 0.263), SIMD3(0.969, 0.529, 0.169), SIMD3(0.918, 0.373, 0.122),
        SIMD3(0.812, 0.208, 0.098), SIMD3(0.659, 0.055, 0.106),
    ]
    public static let warmOffset = 4096

    /// A chance code (`EnvelopeChanceColour.code`) on the warm scale; any other code as it is.
    public static func warm(_ code: Int) -> Int {
        code >= EnvelopeChanceColour.first && code < EnvelopeChanceColour.first + warmOffset
            ? code + warmOffset : code
    }

    /// A side's glass as one number: none broken 0, some broken ½, blown in 1, over the draws.
    public static func glassScore(_ side: FacadeLoadSurrogate.SideGlass) -> Double {
        0.5 * side.someBroken + 0.5 * side.blownOut
    }

    /// Each building's colour code by its sides' glass scores, on the chances' ramp.
    public static func glassCodes(_ sides: [FacadeLoadSurrogate.SideGlass]) -> [UUID: Int] {
        Dictionary(grouping: sides, by: \.owner).mapValues { sides in
            EnvelopeChanceColour.code(sides.map { ($0.axis, $0.outward, glassScore($0)) })
        }
    }
}

/// What the view showed when it was pinned, to compare the next with.
public struct ExplorerSnapshot: Sendable, Equatable {
    /// Each building's glass, its sides' mean score (`ExplorerColours.glassScore`).
    public var glass: [UUID: Double]
    /// Each building's chance of walls damaged moderately or worse.
    public var walls: [UUID: Double]
    /// Each building's glass thrown into its rooms: its sides' mean chance of glass past 3 m (GSA 3b),
    /// what film and laminated glass change (they crack as plain glass does, and hold the pieces).
    public var thrown: [UUID: Double]
    public var reach: ExplorerReach
    public var charge: SIMD3<Float>
    public var massKg: Float

    public init(
        sides: [FacadeLoadSurrogate.SideGlass], structure: [FacadeLoadSurrogate.StructureChance],
        charge: SIMD3<Float>, massKg: Float
    ) {
        glass = Dictionary(grouping: sides, by: \.owner).mapValues { sides in
            sides.map(ExplorerColours.glassScore).reduce(0, +) / Double(sides.count)
        }
        walls = Dictionary(uniqueKeysWithValues: structure.map { ($0.owner, $0.wallsModerate) })
        thrown = Dictionary(grouping: sides, by: \.owner).mapValues { sides in
            sides.map(\.thrownPast3b).reduce(0, +) / Double(sides.count)
        }
        reach = ExplorerReach(sides: sides)
        self.charge = charge
        self.massKg = massKg
    }

    /// What is compared: the glass broken, the walls, or the glass thrown into the rooms.
    public enum Measure: Sendable { case glass, walls, thrown }

    /// Each building now against the pinned picture: better, the same (within a tenth) or worse.
    public struct Change: Sendable, Equatable {
        public var better = 0
        public var same = 0
        public var worse = 0
        public var codes: [UUID: Int] = [:]
        public var measure: Measure = .glass

        /// "Against the pinned picture, windows fare better at 34 buildings and worse at 2; 120 are
        /// about the same."
        public var sentence: String {
            func buildings(_ n: Int) -> String { n == 1 ? "1 building" : "\(n) buildings" }
            if better == 0 && worse == 0 { return "Against the pinned picture, nothing much changes." }
            var parts: [String] = []
            switch measure {
            case .glass, .walls:
                if better > 0 { parts.append("better at \(buildings(better))") }
                if worse > 0 { parts.append("worse at \(buildings(worse))") }
                return "Against the pinned picture, \(measure == .glass ? "windows" : "walls") fare "
                    + parts.joined(separator: " and ")
                    + "; \(same) \(same == 1 ? "is" : "are") about the same."
            case .thrown:
                if better > 0 {
                    parts.append("less broken glass flies into the rooms at \(buildings(better))")
                }
                if worse > 0 { parts.append("more at \(buildings(worse))") }
                return "Against the pinned picture, " + parts.joined(separator: " and ")
                    + "; \(same) \(same == 1 ? "is" : "are") about the same."
            }
        }
    }

    /// `now` against this snapshot, building by building.
    public func change(to now: ExplorerSnapshot, measure: Measure) -> Change {
        let (before, after) =
            switch measure {
            case .glass: (glass, now.glass)
            case .walls: (walls, now.walls)
            case .thrown: (thrown, now.thrown)
            }
        var change = Change(measure: measure)
        for (id, then) in before {
            guard let value = after[id] else { continue }
            let delta = value - then
            if delta < -0.1 {
                change.better += 1
                change.codes[id] = ExplorerColours.better
            } else if delta > 0.1 {
                change.worse += 1
                change.codes[id] = ExplorerColours.worse
            } else {
                change.same += 1
                change.codes[id] = ExplorerColours.same
            }
        }
        return change
    }
}

/// The people hurt now against the pinned picture, in words that give no count or share of people:
/// "About two fifths fewer people hurt than before."
public func explorerPeopleChange(_ comparison: OccupantInjury.Comparison) -> String {
    let change = comparison.hurt
    if abs(change) < 0.05 { return "About as many people hurt as before." }
    let percent = Int((abs(change) * 100).rounded())
    return change < 0
        ? "About \(percent)% fewer people hurt than before."
        : "About \(percent)% more people hurt than before."
}

// MARK: The wave's captions

/// A line for the wave as it plays, from its time on.
public struct ExplorerCaption: Sendable, Equatable {
    public var time: Double
    public var text: String
}

extension ExplorerWords {
    /// The wave's captions from its own times: it goes off, it meets the first building and casts a
    /// shadow, how far it has gone half-way through, and that it has crossed the scene.
    public static func captions(_ field: LiveWave.Field) -> [ExplorerCaption] {
        let last = Double(field.lastArrival)
        var out = [
            ExplorerCaption(
                time: 0,
                text: "The charge goes off. A wall of high pressure spreads out from it, faster than sound.")
        ]
        var firstShadow = Float.infinity
        var near: Float = 0
        var nearCount = 0
        let half = field.lastArrival / 2
        for n in field.arrival.indices where field.arrival[n].isFinite {
            if field.excess(n) > 0.1 { firstShadow = min(firstShadow, field.arrival[n]) }
            if field.arrival[n] >= 0.9 * half && field.arrival[n] <= half {
                near += field.straight[n]
                nearCount += 1
            }
        }
        if firstShadow.isFinite && Double(firstShadow) < 0.9 * last {
            out.append(
                ExplorerCaption(
                    time: Double(firstShadow),
                    text:
                        "It meets the first building. The wave has to go round and over it, and behind it the "
                        + "push is weaker: a shadow."))
        }
        if nearCount > 0 {
            out.append(
                ExplorerCaption(
                    time: Double(half),
                    text: "After \(timeText(Double(half))) the front is about "
                        + "\(distanceText(Double(near) / Double(nearCount))) out, and weakening as it spreads."
                ))
        }
        out.append(
            ExplorerCaption(
                time: last,
                text:
                    "After \(timeText(last)) it has crossed the whole scene. Each place keeps the colour of the "
                    + "strongest push it felt."))
        return out.sorted { $0.time < $1.time }
    }

    /// The caption showing at time `t`.
    public static func caption(_ captions: [ExplorerCaption], at t: Double) -> ExplorerCaption? {
        captions.last { $0.time <= t + 1e-9 }
    }
}
