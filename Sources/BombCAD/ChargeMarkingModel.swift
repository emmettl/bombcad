import BlastCore
import BlastRender
import Foundation
import Observation
import simd

/// Simulation ▸ Read the Charge from the Damage's state (emmettl/bombcad-work#116, stage 2;
/// docs/charge-inference.md, "Marking the damage in the app"): the buildings marked in the view, the
/// learned posterior they make (`ChargeFromDamage.Marking`), kept up to date with each mark, and what
/// the view draws of it: the chance of the charge on the ground, the regions holding half and nine
/// tenths of it outlined, and each marked building outlined in its mark's colour.
@MainActor @Observable
final class ChargeMarkingModel {
    /// What a click on a building marks it.
    enum Brush: String, CaseIterable, Identifiable {
        case glassBroken, glassWhole, wallsUndamaged, wallsDamaged, wallsHeavy, clear
        var id: Self { self }

        var title: String {
            switch self {
            case .glassBroken: "Glass broken"
            case .glassWhole: "Glass whole"
            case .wallsUndamaged: "Walls undamaged"
            case .wallsDamaged: "Walls damaged"
            case .wallsHeavy: "Walls heavily damaged"
            case .clear: "Clear the mark"
            }
        }

        var help: String {
            switch self {
            case .glassBroken: "Some pane of the building broken (GEER's W1 or worse)"
            case .glassWhole: "No pane of the building broken"
            case .wallsUndamaged: "Walls less than moderately damaged"
            case .wallsDamaged: "Walls moderately damaged or worse (for stone, GEER's D3 or worse)"
            case .wallsHeavy: "Walls heavily damaged or worse"
            case .clear: "Take the building's marks away"
            }
        }

        /// The building's mark with this brush laid on it: the glass or the walls set, the other
        /// kept; the same again takes it away.
        func applied(to mark: ChargeFromDamage.Mark) -> ChargeFromDamage.Mark {
            var mark = mark
            func toggle<T: Equatable>(_ value: inout T?, _ new: T) { value = value == new ? nil : new }
            switch self {
            case .glassBroken: toggle(&mark.glass, .broken)
            case .glassWhole: toggle(&mark.glass, .whole)
            case .wallsUndamaged: toggle(&mark.walls, .undamaged)
            case .wallsDamaged: toggle(&mark.walls, .damaged)
            case .wallsHeavy: toggle(&mark.walls, .heavy)
            case .clear:
                mark.glass = nil
                mark.walls = nil
            }
            return mark
        }
    }

    var brush = Brush.glassBroken
    /// Past this many marks the panel says the answer is likely surer than it should be: weighed as
    /// erring together the regions held the truth as often as they say up to 30 marks on the
    /// districts held out, not with every building marked.
    static let manyMarks = 100
    /// The marks and their posterior; nil until the scene's buildings are read.
    private(set) var marking: ChargeFromDamage.Marking?
    /// The scene's envelope buildings as the network sees them, by id, and the scene they were read
    /// from (`sceneVersion`): the far field's too, where the scene has one (New District's near and
    /// far), with each one's blocks' plan, for a survey to be put on and the outlines drawn over.
    @ObservationIgnored private var buildings: [UUID: ChargeFromDamage.Building] = [:]
    @ObservationIgnored private var plans:
        [UUID: (rects: [(low: SIMD2<Double>, high: SIMD2<Double>)], top: Float)] =
            [:]
    @ObservationIgnored private var readFor: Int?
    @ObservationIgnored private var readFar: FarFieldSet?
    /// How many of the buildings read are the far field's.
    private(set) var farBuildings = 0
    /// Marks kept with the project, waiting for the scene's buildings to be read (`restore`).
    @ObservationIgnored private var pending: ChargeFromDamage.SavedMarks?
    /// Buildings whose walls a survey said are stone, weighed as masonry whatever the scene says.
    @ObservationIgnored private var wallsAs: [UUID: ChargeFromDamage.Walls] = [:]
    /// How the marks are weighed together (stage 3: `ChargeFromDamage.Weighing.adopted`; stage 2's
    /// `independent` by choice).
    var weighing = ChargeFromDamage.Weighing.adopted
    /// The scene's corner (0, 0) in longitude and latitude, for a survey placed by it.
    var cornerLongitude = ""
    var cornerLatitude = ""
    /// What the last survey loaded came to, in words; empty before one.
    private(set) var surveyReport = ""
    /// Reading the buildings, or weighing many marks at once.
    private(set) var isWorking = false
    private(set) var error: String?
    /// What the view draws: the chance on the ground, and the regions' and marks' outlines.
    private(set) var paint: SurfacePaint?
    private(set) var lines: [SIMD4<Float>] = []
    /// The posterior in words, from the scene's charge; empty without marks.
    private(set) var words = ""
    /// How long the last change took to weigh (mark to posterior) and to lay out for the view, s.
    private(set) var weighSeconds = 0.0
    private(set) var drawSeconds = 0.0
    /// Whether the search is about the scene's charge, rather than a place moved to.
    private(set) var aboutCharge = true

    /// Marks of each kind, for the panel.
    struct Counts: Equatable {
        var buildings = 0, glassBroken = 0, glassWhole = 0, undamaged = 0, damaged = 0, heavy = 0
    }
    private(set) var counts = Counts()

    var posterior: ChargeFromDamage.Posterior? { marking?.posterior }
    var hasMarks: Bool { !(marking?.marks.isEmpty ?? true) }

    /// The mark of building `id`, if it has one.
    func mark(of id: UUID) -> ChargeFromDamage.Mark? { marking?.marks[id] }

    /// Reads the scene's buildings, if not read for this scene, and starts the search about its
    /// charge. Marks of buildings still in the scene are kept, at their buildings' new places.
    func open(_ model: SimulationModel) async {
        guard readFor != model.sceneVersion || readFar != model.farFieldSet, !isWorking else { return }
        guard let network = ChargeFromDamage.Network.builtIn else {
            error = "No charge-from-damage network is built into this copy of BombCAD."
            return
        }
        isWorking = true
        defer { isWorking = false }
        let near = model.settings.scenario
        let far = model.farFieldSet
        let version = model.sceneVersion
        let (read, plans, farCount) = await Task.detached(priority: .userInitiated) {
            // The far buildings beside the near ones, as the far field judges them.
            let scene = far.flatMap { try? $0.combined(with: near) } ?? near
            let list = ChargeFromDamage.buildings(scene: scene)
            let read = Dictionary(
                zip(scene.envelopeObjects.map(\.id), list).filter { $0.1.footprintM2 > 0 },
                uniquingKeysWith: { a, _ in a })
            var plans: [UUID: (rects: [(low: SIMD2<Double>, high: SIMD2<Double>)], top: Float)] = [:]
            for object in scene.envelopeObjects {
                let blocks = object.envelope?.blocks ?? []
                guard !blocks.isEmpty else { continue }
                plans[object.id] = (
                    blocks.map {
                        (SIMD2(Double($0.min.x), Double($0.min.y)), SIMD2(Double($0.max.x), Double($0.max.y)))
                    }, blocks.map(\.max.z).max() ?? 0
                )
            }
            let farIDs = Set(far?.buildings.map(\.id) ?? [])
            return (read, plans, read.keys.filter { farIDs.contains($0) }.count)
        }.value
        buildings = read
        self.plans = plans
        farBuildings = farCount
        readFor = version
        readFar = far
        let charge = model.settings.chargePosition
        let saved = pending
        pending = nil
        if let saved {
            weighing = saved.weighing.flatMap(ChargeFromDamage.Weighing.named) ?? weighing
            if let corner = saved.corner, corner.count == 2 {
                cornerLongitude = String(corner[0])
                cornerLatitude = String(corner[1])
            }
            wallsAs = Dictionary(
                saved.marks.compactMap { m in m.wallsAs.map { (m.id, $0) } }, uniquingKeysWith: { a, _ in a })
        }
        let reference =
            saved.map { s in
                s.reference.flatMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil }
                    ?? SIMD2(Double(charge.x), Double(charge.y))
            }
            ?? marking?.reference ?? SIMD2(Double(charge.x), Double(charge.y))
        let previous: [(id: UUID, glass: ChargeFromDamage.GlassSeen?, walls: ChargeFromDamage.WallsSeen?)] =
            saved.map { $0.marks.map { ($0.id, $0.glass, $0.walls) } }
            ?? (marking?.order ?? []).compactMap { id in marking?.marks[id].map { (id, $0.glass, $0.walls) } }
        let kept = previous.compactMap { m -> (id: UUID, mark: ChargeFromDamage.Mark)? in
            guard let building = self.building(m.id, in: read) else { return nil }
            return (m.id, ChargeFromDamage.Mark(building: building, glass: m.glass, walls: m.walls))
        }
        if saved != nil { aboutCharge = reference == SIMD2(Double(charge.x), Double(charge.y)) }
        var fresh = ChargeFromDamage.Marking(network: network, reference: reference, weighing: weighing)
        if !kept.isEmpty { fresh = await Self.weighed(fresh, replacing: kept) }
        marking = fresh
        error = nil
        refresh(model)
    }

    /// Building `id` as the network sees it, its walls as a survey said they are if it did.
    private func building(
        _ id: UUID, in read: [UUID: ChargeFromDamage.Building]? = nil
    ) -> ChargeFromDamage.Building? {
        guard var building = (read ?? buildings)[id] else { return nil }
        if let walls = wallsAs[id] { building.walls = walls }
        return building
    }

    /// Whether `id` is a building the network can be told of.
    func canMark(_ id: UUID) -> Bool { buildings[id] != nil && marking != nil && !isWorking }

    /// Lays the brush on building `id`, as a click in the view does.
    func apply(to id: UUID, _ model: SimulationModel) {
        guard canMark(id), let building = building(id) else { return }
        let mark = brush.applied(to: marking?.marks[id] ?? ChargeFromDamage.Mark(building: building))
        marking?.set(mark, for: id)
        refresh(model)
    }

    /// Gives building `id` this mark (nil, or nothing seen, clears it).
    func set(_ mark: ChargeFromDamage.Mark?, for id: UUID, _ model: SimulationModel) {
        guard canMark(id) else { return }
        marking?.set(mark, for: id)
        refresh(model)
    }

    func clearAll(_ model: SimulationModel) {
        guard let marking, !isWorking else { return }
        self.marking = ChargeFromDamage.Marking(
            network: marking.network, reference: marking.reference, weighing: weighing)
        wallsAs = [:]
        surveyReport = ""
        refresh(model)
    }

    /// Weighs the marks as `weighing` does (the default, or stage 2's as independent).
    func weigh(as weighing: ChargeFromDamage.Weighing, _ model: SimulationModel) async {
        self.weighing = weighing
        guard let marking, !isWorking, marking.weighing != weighing else { return }
        isWorking = true
        self.marking = await Task.detached(priority: .userInitiated) {
            var moved = marking
            moved.weigh(as: weighing)
            return moved
        }.value
        isWorking = false
        refresh(model)
    }

    /// The scene's corner (0, 0), if both are given.
    var corner: SIMD2<Double>? {
        guard let lon = Double(cornerLongitude), let lat = Double(cornerLatitude), abs(lat) < 90,
            abs(lon) <= 180
        else { return nil }
        return SIMD2(lon, lat)
    }

    /// Loads a survey (`ChargeFromDamage.readSurvey`: a marks CSV, GEER's façade shapefile or
    /// structural .dbf, a CSV of façades, or a folder of them), puts it on the scene's buildings, near
    /// and far (`ChargeFromDamage.match`), and marks them with it in place of the marks given; says
    /// how many of its entries found a building and how many did not.
    func loadSurvey(_ url: URL, _ model: SimulationModel) async {
        guard let marking, !isWorking else { return }
        let charge = model.settings.chargePosition
        let corner = corner
        let ids = Array(plans.keys.filter { buildings[$0] != nil })
        let footprints = ids.map { plans[$0]!.rects }
        isWorking = true
        defer { isWorking = false }
        let read = await Task.detached(priority: .userInitiated) {
            Result {
                let survey = try ChargeFromDamage.readSurvey(
                    url, corner: corner, charge: SIMD2(Double(charge.x), Double(charge.y)))
                return (survey, ChargeFromDamage.match(survey, footprints: footprints))
            }
        }.value
        switch read {
        case .failure(let failure):
            error = failure.localizedDescription
            surveyReport = ""
        case .success(let (survey, match)):
            error = nil
            wallsAs = [:]
            var list: [(id: UUID, mark: ChargeFromDamage.Mark)] = []
            for (n, seen) in match.marks.sorted(by: { $0.key < $1.key }) {
                let id = ids[n]
                if seen.masonry { wallsAs[id] = .masonry }
                guard let building = building(id) else { continue }
                list.append(
                    (id, ChargeFromDamage.Mark(building: building, glass: seen.glass, walls: seen.walls)))
            }
            let farIDs = Set(model.farFieldSet?.buildings.map(\.id) ?? [])
            let onFar = list.filter { farIDs.contains($0.id) }.count
            surveyReport = Self.surveyWords(
                file: url.lastPathComponent, survey: survey, match: match, buildings: list.count, far: onFar)
            self.marking = await Self.weighed(marking, replacing: list)
        }
        refresh(model)
    }

    /// A survey's matching in words: "Facade_damage.shp: 8,227 façades. 7,901 entries put on 1,402
    /// buildings (310 of them the far field's); 326 found no building within 15 m; 12 records left
    /// out."
    static func surveyWords(
        file: String, survey: ChargeFromDamage.Survey, match: ChargeFromDamage.SurveyMatch, buildings: Int,
        far: Int
    ) -> String {
        func n(_ v: Int) -> String { v.formatted(.number) }
        var words = "\(file): \(survey.parts.joined(separator: ", ")). "
        words +=
            "\(n(match.matched)) of \(n(survey.entries.count)) entries matched, on \(n(buildings)) building\(buildings == 1 ? "" : "s")"
        if far > 0 { words += " (\(n(far)) of them the far field's)" }
        words += "; \(n(match.unmatched)) unmatched, with no building within 15 m"
        if survey.skipped > 0 {
            words += "; \(n(survey.skipped)) records left out, their class not one the network weighs"
        }
        if match.repeated > 0 {
            words += "; \(n(match.repeated)) walls repeated on a building already marked"
        }
        return words + "."
    }

    // MARK: - Kept with the project

    /// The marks as the project keeps them (`chargeMarks.json`); nil without any. Before the
    /// buildings are read, the marks the project was opened with.
    var saved: ChargeFromDamage.SavedMarks? {
        if let pending { return pending }
        guard let marking, !marking.marks.isEmpty else { return nil }
        return ChargeFromDamage.SavedMarks(
            marks: marking.order.compactMap { id in
                marking.marks[id].map {
                    ChargeFromDamage.SavedMarks.Saved(
                        id: id, glass: $0.glass, walls: $0.walls, wallsAs: wallsAs[id])
                }
            },
            reference: aboutCharge ? nil : [marking.reference.x, marking.reference.y],
            weighing: weighing == .adopted ? nil : weighing.name,
            corner: corner.map { [$0.x, $0.y] })
    }

    /// Takes the marks a project was saved with, weighed once the scene's buildings are read
    /// (`open`); nil clears them.
    func restore(_ saved: ChargeFromDamage.SavedMarks?) {
        pending = saved
        marking = nil
        readFor = nil
        wallsAs = [:]
        surveyReport = ""
        counts = Counts()
        paint = nil
        lines = []
        words = ""
    }

    /// Marks every building the last run or quick estimate judged, as its damage would be marked
    /// (`ChargeFromDamage.seen`), in place of the marks given.
    func markFromDamage(_ model: SimulationModel) async {
        guard let marking, !isWorking else { return }
        // The far field's buildings too, where the run judged them.
        let list = (model.envelopeDamage + model.farFieldDamage).compactMap {
            damage -> (id: UUID, mark: ChargeFromDamage.Mark)? in
            guard let building = building(damage.id) else { return nil }
            let (glass, walls) = ChargeFromDamage.seen(damage)
            guard glass != nil || walls != nil else { return nil }
            return (damage.id, ChargeFromDamage.Mark(building: building, glass: glass, walls: walls))
        }
        isWorking = true
        self.marking = await Self.weighed(marking, replacing: list)
        isWorking = false
        refresh(model)
    }

    /// Searches about the likeliest place, or about the scene's charge.
    func centre(onCharge: Bool, _ model: SimulationModel) async {
        guard let marking, !isWorking else { return }
        let charge = model.settings.chargePosition
        let place =
            onCharge
            ? SIMD2(Double(charge.x), Double(charge.y))
            : (marking.posterior?.mostProbablePlace ?? marking.reference)
        await search(about: place, model)
        aboutCharge = onCharge
        refresh(model)
    }

    /// Searches within the network's reach of `place` (the scene's metres), the marks weighed again.
    func search(about place: SIMD2<Double>, _ model: SimulationModel) async {
        guard let marking, !isWorking else { return }
        let charge = model.settings.chargePosition
        aboutCharge = place == SIMD2(Double(charge.x), Double(charge.y))
        isWorking = true
        self.marking = await Task.detached(priority: .userInitiated) {
            var moved = marking
            moved.recentre(on: place)
            return moved
        }.value
        isWorking = false
        refresh(model)
    }

    /// Moves the scene's charge to the likeliest place, at the yield's median, its height above the
    /// ground kept.
    func moveChargeThere(_ model: SimulationModel) {
        guard let posterior else { return }
        let place = posterior.mostProbablePlace
        let size = model.settings.scenario.domainSize
        let terrain = model.settings.scenario.terrain
        var charge = model.settings.chargePosition
        let above = charge.z - (terrain?.height(at: charge) ?? 0)
        charge.x = min(max(Float(place.x), 1), size.x - 1)
        charge.y = min(max(Float(place.y), 1), size.y - 1)
        charge.z = (terrain?.height(at: charge) ?? 0) + above
        model.settings.chargePosition = charge
        model.settings.chargeMass = SimulationSettings.roundedMass(posterior.yieldQuantile(0.5))
        refresh(model)
    }

    private static func weighed(
        _ marking: ChargeFromDamage.Marking, replacing list: [(id: UUID, mark: ChargeFromDamage.Mark)]
    ) async -> ChargeFromDamage.Marking {
        await Task.detached(priority: .userInitiated) {
            var marking = marking
            marking.replaceAll(list)
            return marking
        }.value
    }

    // MARK: - What the view draws

    /// The line kinds the marks and regions are drawn in (Render.metal's `lineVertex`): the regions
    /// in the cloud's white, half thick and nine tenths thin; glass broken crimson and whole cyan, as
    /// the hazards' rings are; walls undamaged blue, damaged amber and heavily damaged dark red.
    enum LineKind {
        static let half: Float = 0
        static let ninety: Float = 1
        static let glassWhole: Float = 4
        static let glassBroken: Float = 5
        static let wallsUndamaged: Float = 7
        static let wallsDamaged: Float = 8
        static let wallsHeavy: Float = 9
    }

    /// The chance shown on the ground over two decades: 1% of the likeliest cell's and below
    /// unpainted.
    static let decades = 2.0

    /// Lays out the paint, the outlines and the words from the marks as they are now.
    func refresh(_ model: SimulationModel) {
        let clock = ContinuousClock.now
        weighSeconds = marking?.lastSeconds ?? 0
        var counts = Counts()
        for mark in (marking?.marks ?? [:]).values {
            counts.buildings += 1
            switch mark.glass {
            case .broken: counts.glassBroken += 1
            case .whole: counts.glassWhole += 1
            case nil: break
            }
            switch mark.walls {
            case .undamaged: counts.undamaged += 1
            case .damaged: counts.damaged += 1
            case .heavy: counts.heavy += 1
            case nil: break
            }
        }
        self.counts = counts
        let scenario = model.settings.scenario
        let ground = { (p: SIMD2<Double>) -> Float in
            scenario.terrain?.height(at: SIMD2(Float(p.x), Float(p.y))) ?? 0
        }
        var lines: [SIMD4<Float>] = []
        // Each marked building outlined over its roof: its glass, and its walls above that.
        for id in marking?.order ?? [] {
            guard let mark = marking?.marks[id], let plan = plans[id] else { continue }
            let low = plan.rects.reduce(SIMD2(Double.infinity, .infinity)) { simd_min($0, $1.low) }
            let high = plan.rects.reduce(SIMD2(-Double.infinity, -.infinity)) { simd_max($0, $1.high) }
            let box = (min: SIMD2<Float>(low), max: SIMD3(Float(high.x), Float(high.y), plan.top))
            var kinds: [Float] = []
            if let glass = mark.glass {
                kinds.append(glass == .broken ? LineKind.glassBroken : LineKind.glassWhole)
            }
            if let walls = mark.walls {
                kinds.append(
                    walls == .undamaged
                        ? LineKind.wallsUndamaged
                        : walls == .damaged ? LineKind.wallsDamaged : LineKind.wallsHeavy)
            }
            for (n, kind) in kinds.enumerated() {
                let z = box.max.z + 0.6 + 1.2 * Float(n)
                let corners = [
                    SIMD3(box.min.x, box.min.y, z), SIMD3(box.max.x, box.min.y, z),
                    SIMD3(box.max.x, box.max.y, z),
                    SIMD3(box.min.x, box.max.y, z),
                ]
                for k in 0..<4 { lines += [SIMD4(corners[k], kind), SIMD4(corners[(k + 1) % 4], 0)] }
            }
        }
        if let posterior {
            for (mass, kind) in [(0.5, LineKind.half), (0.9, LineKind.ninety)] {
                for (a, b) in posterior.outline(mass) {
                    lines += [
                        SIMD4(Float(a.x), Float(a.y), ground(a) + 1, kind),
                        SIMD4(Float(b.x), Float(b.y), ground(b) + 1, 0),
                    ]
                }
            }
            paint = Self.paint(posterior)
            let charge = model.settings.chargePosition
            words = posterior.spoken(
                about: SIMD2(Double(charge.x), Double(charge.y)), aboutName: "the scene's charge")
        } else {
            paint = nil
            words = ""
        }
        self.lines = lines
        drawSeconds = clock.duration(to: .now) / .seconds(1)
    }

    /// The cells' shades as a patch on the ground, with a ring of unpainted cells round it so that
    /// a terrain wearing it is left bare beyond the square.
    static func paint(_ posterior: ChargeFromDamage.Posterior) -> SurfacePaint {
        let g = posterior.grid
        let shades = posterior.shades(decades: decades)
        let size = Float(posterior.cellSizeM)
        let side = Float(2 * posterior.halfWidthM) + 2 * size
        var values = [Float](repeating: 0, count: (g + 2) * (g + 2))
        for j in 0..<g { for i in 0..<g { values[(j + 1) * (g + 2) + i + 1] = shades[j * g + i] } }
        var paint = SurfacePaint()
        let corner =
            SIMD2<Float>(
                Float(posterior.reference.x - posterior.halfWidthM),
                Float(posterior.reference.y - posterior.halfWidthM)) - size
        paint.patches = [
            SurfacePaint.Patch(
                origin: SIMD3(corner, 0), u: SIMD3(side, 0, 0), v: SIMD3(0, side, 0), normal: SIMD3(0, 0, 1),
                columns: g + 2, rows: g + 2, ground: true, first: 0)
        ]
        paint.values = values
        return paint
    }
}
