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
        public let raster: Raster
        public let cellSize: Float
        let objects: [SceneObject]
        let components: [[EnvelopeComponent]]
        let mixes: [GlazingMix?]
        /// Each component's group for a preview (`preview(charge:mass:)`), as `components`: its
        /// kind and side, and for a façade strip facing as its building's outline, which way that
        /// is (`previewGroups(_:owner:raster:)`).
        let previewGroups: [[Int]]
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
            groups.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: objects.count) { n in
                    out[n] = Self.previewGroups(components[n], owner: n, raster: raster)
                }
            }
            self.raster = raster
            self.cellSize = cellSize
            self.objects = objects
            self.components = components
            self.previewGroups = groups
            self.mixes = objects.map { scene.envelopeConstruction(for: $0.id).glazing }
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
        /// (`scenebench drag-time`), not assumed.
        public func preview(
            charge: SIMD3<Float>, mass: Double, binS: Double = 0.7e-3, coefficients: Coefficients = .adopted,
            roofCoefficients: Coefficients? = .roofs, learned: LearnedField.PeakMap? = nil
        ) -> (estimate: Estimate, sides: [GlassSideStrips]) {
            let start = ContinuousClock.now
            let open = raster.openReach(around: charge)
            // Each group's nearest component, its features, the group's area, and its prediction and
            // load where it is in the estimate.
            typealias Chosen = (
                component: EnvelopeComponent, features: Features, area: Double,
                judged: (Prediction, EnvelopeComponentLoad)?
            )
            var perObject = [[Chosen]](repeating: [], count: objects.count)
            perObject.withUnsafeMutableBufferPointer { out in
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
                    out[n] = nearest.sorted { $0.key < $1.key }.map { key, chosen -> Chosen in
                        let component = components[n][chosen.index]
                        var f = features(component, owner: n, charge: charge, raster: raster)
                        f.chargeOpenM = open
                        let terms = component.kind == .roof ? roofCoefficients ?? coefficients : coefficients
                        if let learned {
                            f = learned.adjusted(
                                f, of: component, mass: mass, cellSize: Double(cellSize), coefficients: terms)
                        }
                        guard nearestOfSide[key >> 16]?.index == chosen.index else {
                            return (component, f, chosen.area, nil)
                        }
                        let p = predict(f, mass: mass, cellSize: Double(cellSize), coefficients: terms)
                        return (component, f, chosen.area, (p, load(component, p, binS: binS)))
                    }
                }
            }
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
            let took = start.duration(to: .now)
            result.seconds = Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
            return (result, sides)
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
        /// `uncertainty`'s scatter.
        public func look(
            charge: SIMD3<Float>, mass: Double, constructions: (UUID) -> EnvelopeConstruction,
            uncertainty: Uncertainty, preview: Bool = false, parts: Parts = .all,
            learned: LearnedField.Estimator? = nil, terms: TermSet = .adopted
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
                    charge: charge, mass: mass, coefficients: coefficients, learned: peaks)
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

        /// `components`' groups for a preview, `owner` their owner's index in the raster's objects:
        /// by axis, way out and kind (`kindCode`); and a façade strip facing as its
        /// building's outline (`Raster.outlineNormal`) by that facing too, each different facing of
        /// the building a group of its own. Facing as the outline, one side's strips (thin along one
        /// axis, out one way) may lie on edges facing quite different ways: a corner cut at 45° and
        /// the front beside it, or the two slanted fronts of a building turned to the grid. In one
        /// group for them all, the nearest strip, often facing the charge squarely, stood for those
        /// facing away too, and the preview blew out sides the full estimate leaves whole
        /// (emmettl/bombcad-work#110; docs/surrogate-first-look.md).
        static func previewGroups(_ components: [EnvelopeComponent], owner: Int, raster: Raster) -> [Int] {
            var facings: [SIMD2<Int32>] = []
            return components.map { component in
                let key =
                    ((component.axis * 2 + (component.outward > 0 ? 1 : 0)) * 8 + kindCode(component.kind))
                    << 16
                guard component.kind == .facade,
                    let normal = raster.outlineNormal(
                        region: component.region, axis: component.axis, outward: component.outward,
                        owner: owner)
                else { return key }
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
