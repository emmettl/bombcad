import Foundation
import simd

extension FacadeLoadSurrogate {
    /// A district laid out once for many charges: its geometry's raster, and each envelope
    /// building's components with a face on the air and its glazing. What depends on the charge
    /// (each component's sight line, distance and facing) is redone by `estimate(charge:mass:)`,
    /// which gives what `estimate(scene:)` and `glassSides(scene:)` give for that charge, to the
    /// bit, without building the raster or the components again (roadmap Horizons 6, dragging
    /// the charge: emmettl/bombcad-work#34).
    public struct Prepared: Sendable {
        public private(set) var raster: Raster
        public let cellSize: Float
        let objects: [SceneObject]
        let components: [[EnvelopeComponent]]
        private(set) var mixes: [GlazingMix?]
        /// Each object's construction, as `Scenario.envelopeConstruction(for:)` gives it.
        private(set) var constructions: [EnvelopeConstruction]
        /// Each component's group for a preview (`preview(charge:mass:)`), as `components`: its
        /// kind and side, and for a façade strip facing as its building's outline, which way that
        /// is (`previewGroups(_:owner:raster:)`).
        let previewGroups: [[Int]]
        /// Each component's facing for its cosine of incidence (`Raster.outlineNormal` where its
        /// building's outline gives one, else its face's own normal), as `components`: worked out
        /// once, for the live drag (`livePreview`).
        let facings: [[SIMD3<Float>]]
        /// This layout's own identity, for what a GPU keeps of it between frames, and its
        /// constructions' (new with each set, `withConstructions`).
        public let identity = UUID()
        public private(set) var constructionsKey = UUID()
        /// Its raster's own identity, new with each set of fixed blocks (`withBlocks`), for the GPU's
        /// copy of the raster.
        public private(set) var rasterKey = UUID()

        /// The same layout with the scene's fixed blocks `blocks` (barrier walls, as a barrier dragged
        /// moves them; emmettl/bombcad-work#117): its raster laid out again, nothing else. The
        /// buildings' components keep the faces they had on the air.
        public func withBlocks(_ blocks: [Box]) -> Prepared {
            var copy = self
            copy.raster = Raster(
                objects: objects, blocks: blocks, terrain: raster.terrain, cell: cellSize,
                incidence: raster.incidence)
            copy.rasterKey = UUID()
            return copy
        }

        /// The same layout with each object built as `scene` says (its geometry the same, only what
        /// its envelopes are built of changed, as a what-if changes it): nothing laid out again.
        public func withConstructions(of scene: Scenario) -> Prepared {
            var copy = self
            let recorded = Dictionary(
                (scene.envelopeConstructions ?? []).map { ($0.objectID, $0) },
                uniquingKeysWith: { _, last in last })
            copy.constructions = objects.map { recorded[$0.id] ?? .assumed(objectID: $0.id) }
            copy.mixes = copy.constructions.map(\.glazing)
            copy.constructionsKey = UUID()
            return copy
        }
        /// Each object's preview groups laid out once (`choices`): each component's group (in the
        /// groups' keys' order), its outer face's centre, and each group's area and side.
        let groupLayout: [GroupLayout]

        struct GroupLayout: Sendable {
            var group: [Int32] = []
            var centres: [SIMD3<Float>] = []
            var areas: [Double] = []
            var sides: [Int32] = []
            var sideCount = 0
            /// Whether each component is a façade strip.
            var facades: [Bool] = []
            /// Each component's area, m².
            var componentAreas: [Double] = []
        }

        /// How many strips stand for each façade group in a preview, by their distance from the charge
        /// (`choices`): the nearest for the nearest band of equal area, and each further band's middle
        /// strip for its own (emmettl/bombcad-work#117; docs/protective-design.md, "A charge kept back,
        /// read by the preview"). One, the nearest standing for the whole group, the preview as the
        /// learned response was trained on it, by default. Three follows the full estimate as a charge
        /// is kept back, but the networks were not trained on sides read so; it waits for the user's
        /// decision on a retrain.
        public var facadeBands = Prepared.defaultFacadeBands
        public static let defaultFacadeBands = 1
        /// The same layout with `bands` strips for each façade group.
        public func withFacadeBands(_ bands: Int) -> Prepared {
            var copy = self
            copy.facadeBands = max(1, bands)
            return copy
        }
        /// How long laying it out took, s.
        public let seconds: Double
        /// The SDOF responses and the panes' responses met so far by previews, kept between them.
        /// A full look keeps its own only while it lasts (on Beirut they would hold several GB).
        /// The panes' are a coarser table than a full look's (`previewQuantum`,
        /// `previewStrengthSteps`), so that a charge moved a few metres finds most of them
        /// already worked out.
        public let memo = SDOFResponseMemo()
        public var glassResponses = GlassResponses(
            quantum: Prepared.previewQuantum, strengthSteps: Prepared.previewStrengthSteps)

        /// A preview's pulses rounded to 10% of their peak and impulse (a full look's, 3%), and a
        /// cracked pane's strength to a fifth of a unit of its log (a full look's, a twentieth):
        /// far finer than the surrogate's scatter (0.2–0.3 in the log) and the strength's (0.25).
        /// On Beirut (0.5 kt, 10 draws) the glass agrees with the full look as closely as the
        /// finer table's (some broken within 0.1 on 92.8% of sides against 92.9%), its frames a
        /// half to two-thirds of the time (emmettl/bombcad-work#34; docs/surrogate-first-look.md).
        public static let previewQuantum = 0.10
        public static let previewStrengthSteps = 5.0

        /// With `incidence`, the façades face as it gives them: the terms' own
        /// (`Coefficients.incidence`), for the looks to take those terms; by default the adopted
        /// terms', each wall as its building's map outline since 28 October 2026
        /// (emmettl/bombcad-work#109), the cells' faces for a building without one.
        public init(scene: Scenario, cellSize: Float, incidence: Incidence = Coefficients.adopted.incidence) {
            let start = ContinuousClock.now
            let objects = scene.envelopeObjects
            let raster = Raster(
                objects: objects, blocks: scene.boxes, terrain: scene.terrain, cell: cellSize,
                incidence: incidence)
            var components = [[EnvelopeComponent]](repeating: [], count: objects.count)
            components.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: objects.count) { n in
                    guard let envelope = objects[n].envelope else { return }
                    out[n] = envelope.components(owner: objects[n].id, cellSize: cellSize)
                        .filter { facesAir($0, raster: raster) }
                }
            }
            var groups = [[Int]](repeating: [], count: objects.count)
            var facings = [[SIMD3<Float>]](repeating: [], count: objects.count)
            groups.withUnsafeMutableBufferPointer { out in
                facings.withUnsafeMutableBufferPointer { facingOut in
                    concurrently(iterations: objects.count) { n in
                        let normals = components[n].map { component -> SIMD3<Float>? in
                            component.kind == .facade
                                ? raster.outlineNormal(
                                    region: component.region, axis: component.axis,
                                    outward: component.outward,
                                    owner: n) : nil
                        }
                        out[n] = Self.previewGroups(components[n], normals: normals)
                        facingOut[n] = zip(components[n], normals).map { component, normal in
                            normal ?? outerFace(component).normal
                        }
                    }
                }
            }
            self.raster = raster
            self.cellSize = cellSize
            self.objects = objects
            self.components = components
            self.previewGroups = groups
            var layouts = [GroupLayout](repeating: GroupLayout(), count: objects.count)
            layouts.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: objects.count) { n in
                    let keys = Array(Set(groups[n])).sorted()
                    let index = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
                    let sideKeys = Array(Set(keys.map { $0 >> 16 })).sorted()
                    let sideIndex = Dictionary(uniqueKeysWithValues: sideKeys.enumerated().map { ($1, $0) })
                    var layout = GroupLayout()
                    layout.group = groups[n].map { Int32(index[$0]!) }
                    layout.centres = components[n].map { outerFace($0).centre }
                    layout.facades = components[n].map { $0.kind == .facade }
                    layout.areas = [Double](repeating: 0, count: keys.count)
                    layout.componentAreas = components[n].map { Double($0.spans.x * $0.spans.y) }
                    for (k, component) in components[n].enumerated() {
                        let spans = component.spans
                        layout.areas[Int(layout.group[k])] += Double(spans.x * spans.y)
                    }
                    layout.sides = keys.map { Int32(sideIndex[$0 >> 16]!) }
                    layout.sideCount = sideKeys.count
                    out[n] = layout
                }
            }
            groupLayout = layouts
            self.facings = facings
            // The recorded constructions by object, the last for each as `envelopeConstruction(for:)`.
            let recorded = Dictionary(
                (scene.envelopeConstructions ?? []).map { ($0.objectID, $0) },
                uniquingKeysWith: { _, last in last })
            constructions = objects.map { recorded[$0.id] ?? .assumed(objectID: $0.id) }
            self.mixes = constructions.map(\.glazing)
            let took = start.duration(to: .now)
            seconds = Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
        }

        /// The number of components with a face on the air.
        public var componentCount: Int { components.reduce(0) { $0 + $1.count } }

        /// As `FacadeLoadSurrogate.estimate(scene:)` for a charge of `mass` kg at `charge`; with
        /// `learned`, the learned field model's peak at the ground-floor façade strips it reads
        /// (`LearnedField.PeakMap.adjusted`), the rest as without it.
        public func estimate(
            charge: SIMD3<Float>, mass: Double, binS: Double = 0.7e-3, coefficients: Coefficients = .adopted,
            roofCoefficients: Coefficients? = .roofs, learned: LearnedField.PeakMap? = nil
        ) -> Estimate {
            let start = ContinuousClock.now
            let open = raster.openReach(around: charge)
            var perObject = [[(Features, Prediction, EnvelopeComponentLoad)]](
                repeating: [], count: objects.count)
            perObject.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: objects.count) { n in
                    out[n] = components[n].map { component in
                        var f = features(component, owner: n, charge: charge, raster: raster)
                        f.chargeOpenM = open
                        let chosen = component.kind == .roof ? roofCoefficients ?? coefficients : coefficients
                        if let learned {
                            f = learned.adjusted(
                                f, of: component, mass: mass, cellSize: Double(cellSize), coefficients: chosen
                            )
                        }
                        let p = predict(f, mass: mass, cellSize: Double(cellSize), coefficients: chosen)
                        return (f, p, load(component, p, binS: binS))
                    }
                }
            }
            var result = Estimate(
                components: [], owners: [], features: [], predictions: [], loads: [], seconds: 0)
            result.ownerKeys = objects.map(\.drawKey)
            let count = componentCount
            result.components.reserveCapacity(count)
            result.owners.reserveCapacity(count)
            result.features.reserveCapacity(count)
            result.predictions.reserveCapacity(count)
            result.loads.reserveCapacity(count)
            for (n, list) in perObject.enumerated() {
                for (component, (f, p, l)) in zip(components[n], list) {
                    result.components.append(component)
                    result.owners.append(n)
                    result.features.append(f)
                    result.predictions.append(p)
                    result.loads.append(l)
                }
            }
            let took = start.duration(to: .now)
            result.seconds = Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
            return result
        }

        /// A preview's standing, worded from the standing table's figures (surrogate-first-look.md,
        /// "Dragging the charge").
        public static let previewStanding: String = {
            let glass = ValidationTables.figure("dragPreviewGlass")
            let walls = ValidationTables.figure("dragPreviewWalls")
            let damage = ValidationTables.figure("dragPreviewDamage")
            // A range as percentages, one figure where its ends agree.
            func percent(_ f: ValidationTables.Figure, _ digits: Int) -> String {
                let low = String(format: "%.\(digits)f", f.low * 100)
                let high = String(format: "%.\(digits)f", f.high * 100)
                return low == high ? "\(low)%" : "\(low)–\(high)%"
            }
            return
                "A preview of the estimate, not the estimate: against the full estimate on Beirut at 0.5 kt, its glass "
                + "chances came within 0.1 on \(percent(glass, 0)) of sides, its walls' and roofs' on "
                + "\(percent(walls, 1)) of buildings, and the damage's colour was the same for \(percent(damage, 1)) of "
                + "buildings."
        }()

        /// A preview for dragging the charge: of each building's components of one kind on one side
        /// (façade strips, walls, slabs or roofs, by axis and way out), only the one nearest the
        /// charge, judged as `estimate` judges it; and the glazed sides, each its nearest strip
        /// standing for the side's whole façade area, or facing as its building's outline, the
        /// nearest strip of each way the outline faces it standing for that facing's area
        /// (`previewGroups`; emmettl/bombcad-work#110). About a tenth of the components, so a tenth
        /// of the sight lines, damage and draws; its error against the full estimate is measured
        /// (`scenebench drag-time`), not assumed. With `only`, the objects of those indices alone (the
        /// buildings the live drag leaves to the CPU: `livePreview`).
        public func preview(
            charge: SIMD3<Float>, mass: Double, binS: Double = 0.7e-3, coefficients: Coefficients = .adopted,
            roofCoefficients: Coefficients? = .roofs, learned: LearnedField.PeakMap? = nil,
            only: Set<Int>? = nil
        ) -> (estimate: Estimate, sides: [GlassSideStrips]) {
            let start = ContinuousClock.now
            var clock = start
            func lap() -> Double {
                let now = ContinuousClock.now
                let took = clock.duration(to: now)
                clock = now
                return Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
            }
            let open = raster.openReach(around: charge)
            let openS = lap()
            // Each group's nearest component, its features, the group's area, and its prediction and
            // load where it is in the estimate; worked out in passes (the choice, the sight lines, the
            // loads), each timed (`Estimate.previewStages`).
            typealias Chosen = (
                component: EnvelopeComponent, features: Features, area: Double,
                judged: (Prediction, EnvelopeComponentLoad)?
            )
            let picked = choices(charge: charge)
            let selectS = lap()
            var perObject = [[Chosen]](repeating: [], count: objects.count)
            perObject.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: objects.count) { n in
                    guard only?.contains(n) ?? true else { return }
                    out[n] = picked[n].map { choice -> Chosen in
                        let component = components[n][choice.index]
                        var f = features(component, owner: n, charge: charge, raster: raster)
                        f.chargeOpenM = open
                        if let learned {
                            let terms =
                                component.kind == .roof ? roofCoefficients ?? coefficients : coefficients
                            f = learned.adjusted(
                                f, of: component, mass: mass, cellSize: Double(cellSize), coefficients: terms)
                        }
                        return (component, f, choice.area, nil)
                    }
                }
            }
            let featuresS = lap()
            perObject.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: objects.count) { n in
                    guard only?.contains(n) ?? true else { return }
                    for (c, choice) in picked[n].enumerated() where choice.judged {
                        let component = out[n][c].component
                        let terms = component.kind == .roof ? roofCoefficients ?? coefficients : coefficients
                        let p = predict(
                            out[n][c].features, mass: mass, cellSize: Double(cellSize), coefficients: terms)
                        out[n][c].judged = (p, load(component, p, binS: binS))
                    }
                }
            }
            let loadsS = lap()
            var result = Estimate(
                components: [], owners: [], features: [], predictions: [], loads: [], seconds: 0)
            result.ownerKeys = objects.map(\.drawKey)
            var sides: [GlassSideStrips] = []
            for (n, list) in perObject.enumerated() {
                // A side's strips, one for each way its outline faces it (one facing as the cells).
                var side: [Int: Int] = [:]
                for chosen in list {
                    let component = chosen.component
                    if let (p, l) = chosen.judged {
                        result.components.append(component)
                        result.owners.append(n)
                        result.features.append(chosen.features)
                        result.predictions.append(p)
                        result.loads.append(l)
                    }
                    guard component.kind == .facade, let mix = mixes[n] else { continue }
                    let key = component.axis * 2 + (component.outward > 0 ? 1 : 0)
                    if let s = side[key] {
                        sides[s].strips.append((chosen.features, chosen.area))
                    } else {
                        side[key] = sides.count
                        sides.append(
                            GlassSideStrips(
                                owner: objects[n].id, ownerKey: objects[n].drawKey, axis: component.axis,
                                outward: component.outward,
                                mix: mix,
                                strips: [(chosen.features, chosen.area)]))
                    }
                }
            }
            let assembleS = lap()
            let took = start.duration(to: .now)
            result.seconds = Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
            result.previewStages = PreviewStages(
                openReach: openS, choice: selectS, sightLines: featuresS, loads: loadsS, assembly: assembleS)
            return (result, sides)
        }

        /// What a preview's passes took, s (`preview(charge:mass:)`): the charge's open reach, the
        /// choice of each group's nearest component, their sight lines and features, their loads
        /// (predictions and pulses), and laying the estimate and the glazed sides out.
        public struct PreviewStages: Sendable, Equatable {
            public var openReach = 0.0
            public var choice = 0.0
            public var sightLines = 0.0
            public var loads = 0.0
            public var assembly = 0.0
        }

        /// Each object's components a preview takes with the charge at `charge`, in its groups' order:
        /// the nearest of each group (`previewGroups`), the group's area, m², and whether it is the
        /// nearest of its kind and side, which the estimate takes (the rest go to the glass alone).
        package func choices(charge: SIMD3<Float>) -> [[(index: Int, area: Double, judged: Bool)]] {
            let bands = facadeBands
            var picked = [[(index: Int, area: Double, judged: Bool)]](repeating: [], count: objects.count)
            picked.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: (objects.count + 63) / 64) { chunk in
                    for n in (chunk * 64)..<min(objects.count, (chunk + 1) * 64) {
                        let layout = groupLayout[n]
                        let groups = layout.areas.count
                        var best = [(index: Int, distance: Float)](repeating: (-1, .infinity), count: groups)
                        for (k, centre) in layout.centres.enumerated() {
                            let g = Int(layout.group[k])
                            let d = simd_distance_squared(centre, charge)
                            if best[g].index < 0 || d < best[g].distance { best[g] = (k, d) }
                        }
                        // The nearest of each kind and side; the lowest index where two are as near.
                        var side = [(index: Int, distance: Float)](
                            repeating: (-1, .infinity), count: layout.sideCount)
                        for g in 0..<groups {
                            let s = Int(layout.sides[g])
                            let chosen = best[g]
                            if side[s].index >= 0,
                                side[s].distance < chosen.distance
                                    || (side[s].distance == chosen.distance && side[s].index < chosen.index)
                            {
                                continue
                            }
                            side[s] = chosen
                        }
                        guard bands > 1 else {
                            out[n] = (0..<groups).map { g in
                                (
                                    best[g].index, layout.areas[g],
                                    side[Int(layout.sides[g])].index == best[g].index
                                )
                            }
                            continue
                        }
                        // A façade group's strips by distance: the nearest for the nearest band's area,
                        // each further band's middle strip for its own (the glass alone).
                        var members = [[(k: Int, d: Float)]](repeating: [], count: groups)
                        for (k, centre) in layout.centres.enumerated() where layout.facades[k] {
                            members[Int(layout.group[k])].append((k, simd_distance_squared(centre, charge)))
                        }
                        var list: [(index: Int, area: Double, judged: Bool)] = []
                        for g in 0..<groups {
                            let judged = side[Int(layout.sides[g])].index == best[g].index
                            guard members[g].count > 1 else {
                                list.append((best[g].index, layout.areas[g], judged))
                                continue
                            }
                            let ordered = members[g].sorted { ($0.d, $0.k) < ($1.d, $1.k) }
                            let total = layout.areas[g]
                            let share = total / Double(bands)
                            var band = 0
                            var bandArea = 0.0
                            var bandStart = 0
                            var entries: [(index: Int, area: Double, judged: Bool)] = []
                            func close(_ end: Int) {
                                guard end > bandStart else { return }
                                if band == 0 {
                                    entries.append((best[g].index, bandArea, judged))
                                } else {
                                    // The strip at the middle of the band's area.
                                    var run = 0.0
                                    var middle = ordered[bandStart].k
                                    for t in bandStart..<end {
                                        run += layout.componentAreas[ordered[t].k]
                                        middle = ordered[t].k
                                        if run >= bandArea / 2 { break }
                                    }
                                    entries.append((middle, bandArea, false))
                                }
                                band += 1
                                bandArea = 0
                                bandStart = end
                            }
                            for (t, member) in ordered.enumerated() {
                                bandArea += layout.componentAreas[member.k]
                                if bandArea >= share * 0.999, band < bands - 1 { close(t + 1) }
                            }
                            close(ordered.count)
                            list += entries
                        }
                        out[n] = list
                    }
                }
            }
            return picked
        }

        /// `choices` as first written, by dictionaries, one strip for each group: the reference its tests
        /// hold it to with `facadeBands` one.
        package func referenceChoices(charge: SIMD3<Float>) -> [[(index: Int, area: Double, judged: Bool)]] {
            var picked = [[(index: Int, area: Double, judged: Bool)]](repeating: [], count: objects.count)
            picked.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: objects.count) { n in
                    // Nearest of each group, and the group's area.
                    var nearest: [Int: (index: Int, distance: Float, area: Double)] = [:]
                    for (k, component) in components[n].enumerated() {
                        let key = previewGroups[n][k]
                        let d = simd_distance_squared(outerFace(component).centre, charge)
                        let spans = component.spans
                        let area = Double(spans.x * spans.y)
                        if let current = nearest[key] {
                            nearest[key] = (
                                d < current.distance ? k : current.index, min(d, current.distance),
                                current.area + area
                            )
                        } else {
                            nearest[key] = (k, d, area)
                        }
                    }
                    // The estimate takes the nearest of each kind and side, whichever way it faces;
                    // a side's other facings' nearest strips go to its glass alone.
                    var nearestOfSide: [Int: (index: Int, distance: Float)] = [:]
                    for (key, chosen) in nearest {
                        let side = key >> 16
                        if let current = nearestOfSide[side],
                            current.distance < chosen.distance
                                || (current.distance == chosen.distance && current.index < chosen.index)
                        {
                            continue
                        }
                        nearestOfSide[side] = (chosen.index, chosen.distance)
                    }
                    out[n] = nearest.sorted { $0.key < $1.key }.map { key, chosen in
                        (chosen.index, chosen.area, nearestOfSide[key >> 16]?.index == chosen.index)
                    }
                }
            }
            return picked
        }

        /// What a look at the district gives: the estimate, each building's damage on it, each
        /// glazed side's chances and each building's walls' and roof's; and what each took, s.
        public struct Look: Sendable {
            public var estimate: Estimate
            public var damage: [EnvelopeBuildingDamage]
            public var glass: [SideGlass]
            public var structure: [StructureChance]
            public var charge: SIMD3<Float>
            public var preview: Bool
            public var seconds: (estimate: Double, damage: Double, glass: Double, structure: Double)
            /// With the learned field model asked for (`look(learned:)`): the ground-floor façade
            /// strips that took its peak, how long it took, s (its inputs and the network), and why
            /// it could not be used, if it could not (the estimate is then the surrogate's alone).
            public var learnedStrips = 0
            public var learnedSeconds = 0.0
            public var learnedError: String?
            /// Judged by the live drag's learned response (`livePreview`), not the SDOF and draws, and
            /// where it ran ("GPU" or "CPU").
            public var learnedResponse: String?
            /// Of a live look's buildings judged, those whose inputs lie outside the learned
            /// response's training, left to the CPU's preview (emmettl/bombcad-work#118), and the
            /// inputs that put them there ("network input": the buildings each did;
            /// `LiveResponse.TrainingRanges.buildingsOutside`); those outside but kept on the networks
            /// where the caller asked (`livePreview(leavesUntrainedToCPU: false)`).
            public var leftToCPU = 0
            public var outsideKept = 0
            public var liveBuildings = 0
            public var outsideTraining: [String: Int] = [:]
            public var totalSeconds: Double {
                seconds.estimate + seconds.damage + seconds.glass + seconds.structure + learnedSeconds
            }
        }

        /// The quick estimate with the charge at `charge`: everything the app's quick estimate
        /// gives, the whole of it, or with `preview` the nearest component of each group
        /// (`preview(charge:mass:)`) for dragging. The responses are kept for the next look.
        /// What a look works out: the damage on the estimate, the glass's chances, the walls' and
        /// roofs'. A preview while dragging works out only what the view shows.
        public struct Parts: OptionSet, Sendable {
            public let rawValue: Int
            public init(rawValue: Int) { self.rawValue = rawValue }
            public static let damage = Parts(rawValue: 1)
            public static let glass = Parts(rawValue: 2)
            public static let structure = Parts(rawValue: 4)
            public static let all: Parts = [.damage, .glass, .structure]
        }

        /// With `learned`, the learned field model's peak at the ground-floor façade strips for the
        /// estimate's damage, glass and walls (emmettl/bombcad-work#67); if it cannot be run, the
        /// look is the surrogate's alone and says why. The components take `terms`' coefficients (the
        /// adopted ones unless an option asks for others: emmettl/bombcad-work#98); the chances draw
        /// `uncertainty`'s scatter. A preview with `only` looks at the objects of those indices alone.
        public func look(
            charge: SIMD3<Float>, mass: Double, constructions: (UUID) -> EnvelopeConstruction,
            uncertainty: Uncertainty, preview: Bool = false, parts: Parts = .all,
            learned: LearnedField.Estimator? = nil, terms: TermSet = .adopted, only: Set<Int>? = nil
        ) -> Look {
            let coefficients = terms.coefficients
            func since(_ start: ContinuousClock.Instant) -> Double {
                let took = start.duration(to: .now)
                return Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
            }
            let memo = preview ? self.memo : SDOFResponseMemo()
            let glassResponses = preview ? self.glassResponses : GlassResponses()
            var clock = ContinuousClock.now
            var peaks: LearnedField.PeakMap?
            var learnedError: String?
            if let learned {
                do {
                    peaks = try learned.peaks(charge: charge, mass: mass)
                } catch {
                    learnedError = "\(error)"
                }
            }
            let learnedS = since(clock)
            clock = .now
            let estimate: Estimate
            let sides: [GlassSideStrips]
            if preview {
                (estimate, sides) = self.preview(
                    charge: charge, mass: mass, coefficients: coefficients, learned: peaks, only: only)
            } else {
                estimate = self.estimate(
                    charge: charge, mass: mass, coefficients: coefficients, learned: peaks)
                sides = glassSides(estimate)
            }
            let estimateS = since(clock)
            clock = .now
            let damage =
                parts.contains(.damage)
                ? SDOFResponseMemo.remembering(in: memo) {
                    EnvelopeDamageAssessment.assess(loads: estimate.loads, constructions: constructions)
                }.0 : []
            let damageS = since(clock)
            clock = .now
            let glass =
                parts.contains(.glass)
                ? glassProbabilities(
                    sides: sides, mass: mass, cellSize: cellSize, uncertainty: uncertainty,
                    coefficients: coefficients, responses: glassResponses
                ).sides : []
            let glassS = since(clock)
            clock = .now
            let structure =
                parts.contains(.structure)
                ? SDOFResponseMemo.remembering(in: memo) {
                    structureProbabilities(
                        estimate, mass: mass, cellSize: cellSize, constructions: constructions,
                        uncertainty: uncertainty, coefficients: coefficients,
                        learnedPeaks: estimate.features.contains { $0.learnedPeakFactor != 1 })
                }.0.chances : []
            var look = Look(
                estimate: estimate, damage: damage, glass: glass, structure: structure, charge: charge,
                preview: preview, seconds: (estimateS, damageS, glassS, since(clock)))
            if learned != nil {
                look.learnedStrips = estimate.features.reduce(0) { $0 + ($1.learnedPeakFactor != 1 ? 1 : 0) }
                look.learnedSeconds = learnedS
                look.learnedError = learnedError
            }
            return look
        }

        /// `components`' groups for a preview, `normals` each one's outline facing where it has one
        /// (`Raster.outlineNormal`): by axis, way out and kind (`kindCode`); and a façade strip facing
        /// as its building's outline by that facing too, each different facing of
        /// the building a group of its own. Facing as the outline, one side's strips (thin along one
        /// axis, out one way) may lie on edges facing quite different ways: a corner cut at 45° and
        /// the front beside it, or the two slanted fronts of a building turned to the grid. In one
        /// group for them all, the nearest strip, often facing the charge squarely, stood for those
        /// facing away too, and the preview blew out sides the full estimate leaves whole
        /// (emmettl/bombcad-work#110; docs/surrogate-first-look.md).
        static func previewGroups(_ components: [EnvelopeComponent], normals: [SIMD3<Float>?]) -> [Int] {
            var facings: [SIMD2<Int32>] = []
            return zip(components, normals).map { component, outline in
                let key =
                    ((component.axis * 2 + (component.outward > 0 ? 1 : 0)) * 8 + kindCode(component.kind))
                    << 16
                guard component.kind == .facade, let normal = outline else { return key }
                // Facings within a thousandth the same (an edge's normal, the same for every strip on it).
                let facing = SIMD2(Int32((normal.x * 1000).rounded()), Int32((normal.y * 1000).rounded()))
                let index = facings.firstIndex(of: facing) ?? facings.count
                if index == facings.count { facings.append(facing) }
                return key + index + 1
            }
        }

        static func kindCode(_ kind: EnvelopeComponent.Kind) -> Int {
            switch kind {
            case .wall: 0
            case .slab: 1
            case .roof: 2
            case .pane: 3
            case .facade: 4
            }
        }

        /// The glazed buildings' façade sides, their strips' features taken from `estimate` (one of
        /// this district's), as `glassSides(scene:)` gives them for the same charge.
        public func glassSides(_ estimate: Estimate) -> [GlassSideStrips] {
            var byObject = [[Int]](repeating: [], count: objects.count)
            for (k, n) in estimate.owners.enumerated() where estimate.components[k].kind == .facade {
                byObject[n].append(k)
            }
            var sides: [GlassSideStrips] = []
            for n in objects.indices {
                guard let mix = mixes[n], !byObject[n].isEmpty else { continue }
                let groups = Dictionary(grouping: byObject[n]) { k in
                    estimate.components[k].axis * 2 + (estimate.components[k].outward > 0 ? 1 : 0)
                }
                for (key, members) in groups.sorted(by: { $0.key < $1.key }) {
                    sides.append(
                        GlassSideStrips(
                            owner: objects[n].id, ownerKey: objects[n].drawKey, axis: key / 2,
                            outward: key % 2 == 1 ? 1 : -1, mix: mix,
                            strips: members.map { k in
                                let spans = estimate.components[k].spans
                                return (estimate.features[k], Double(spans.x * spans.y))
                            }))
                }
            }
            return sides
        }
    }
}
