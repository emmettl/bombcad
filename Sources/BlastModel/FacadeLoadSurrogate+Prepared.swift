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

        public init(scene: Scenario, cellSize: Float) {
            let start = ContinuousClock.now
            let objects = scene.envelopeObjects
            let raster = Raster(objects: objects, blocks: scene.boxes, terrain: scene.terrain, cell: cellSize)
            var components = [[EnvelopeComponent]](repeating: [], count: objects.count)
            components.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: objects.count) { n in
                    guard let envelope = objects[n].envelope else { return }
                    out[n] = envelope.components(owner: objects[n].id, cellSize: cellSize)
                        .filter { facesAir($0, raster: raster) }
                }
            }
            self.raster = raster
            self.cellSize = cellSize
            self.objects = objects
            self.components = components
            self.mixes = objects.map { scene.envelopeConstruction(for: $0.id).glazing }
            let took = start.duration(to: .now)
            seconds = Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
        }

        /// The number of components with a face on the air.
        public var componentCount: Int { components.reduce(0) { $0 + $1.count } }

        /// As `FacadeLoadSurrogate.estimate(scene:)` for a charge of `mass` kg at `charge`.
        public func estimate(
            charge: SIMD3<Float>, mass: Double, binS: Double = 0.7e-3, coefficients: Coefficients = .fitted,
            roofCoefficients: Coefficients? = .roofs
        ) -> Estimate {
            let start = ContinuousClock.now
            var perObject = [[(Features, Prediction, EnvelopeComponentLoad)]](
                repeating: [], count: objects.count)
            perObject.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: objects.count) { n in
                    out[n] = components[n].map { component in
                        let f = features(component, owner: n, charge: charge, raster: raster)
                        let p = predict(
                            f, mass: mass, cellSize: Double(cellSize),
                            coefficients: component.kind == .roof
                                ? roofCoefficients ?? coefficients : coefficients)
                        return (f, p, load(component, p, binS: binS))
                    }
                }
            }
            var result = Estimate(
                components: [], owners: [], features: [], predictions: [], loads: [], seconds: 0)
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
            return String(
                format:
                    "A preview of the estimate, not the estimate: against the full estimate on Beirut at 0.5 kt, its glass "
                    + "chances came within 0.1 on %.0f–%.0f%% of sides, its walls' and roofs' on %.1f–%.0f%% of buildings, "
                    + "and the damage's colour was the same for %.1f%% of buildings.",
                glass.low * 100, glass.high * 100, walls.low * 100, walls.high * 100, damage.low * 100)
        }()

        /// A preview for dragging the charge: of each building's components of one kind on one side
        /// (façade strips, walls, slabs or roofs, by axis and way out), only the one nearest the
        /// charge, judged as `estimate` judges it; and the glazed sides, each its nearest strip
        /// standing for the side's whole façade area. About a tenth of the components, so a tenth
        /// of the sight lines, damage and draws; its error against the full estimate is measured
        /// (`scenebench drag-time`), not assumed.
        public func preview(
            charge: SIMD3<Float>, mass: Double, binS: Double = 0.7e-3, coefficients: Coefficients = .fitted,
            roofCoefficients: Coefficients? = .roofs
        ) -> (estimate: Estimate, sides: [GlassSideStrips]) {
            let start = ContinuousClock.now
            var perObject = [[(EnvelopeComponent, Features, Prediction, EnvelopeComponentLoad, Double)]](
                repeating: [], count: objects.count)
            perObject.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: objects.count) { n in
                    // Nearest of each group, and the group's area.
                    var nearest: [Int: (index: Int, distance: Float, area: Double)] = [:]
                    for (k, component) in components[n].enumerated() {
                        let key =
                            (component.axis * 2 + (component.outward > 0 ? 1 : 0)) * 8
                            + Self.kindCode(component.kind)
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
                    out[n] = nearest.sorted { $0.key < $1.key }.map { _, chosen in
                        let component = components[n][chosen.index]
                        let f = features(component, owner: n, charge: charge, raster: raster)
                        let p = predict(
                            f, mass: mass, cellSize: Double(cellSize),
                            coefficients: component.kind == .roof
                                ? roofCoefficients ?? coefficients : coefficients)
                        return (component, f, p, load(component, p, binS: binS), chosen.area)
                    }
                }
            }
            var result = Estimate(
                components: [], owners: [], features: [], predictions: [], loads: [], seconds: 0)
            var sides: [GlassSideStrips] = []
            for (n, list) in perObject.enumerated() {
                for (component, f, p, l, area) in list {
                    result.components.append(component)
                    result.owners.append(n)
                    result.features.append(f)
                    result.predictions.append(p)
                    result.loads.append(l)
                    if component.kind == .facade, let mix = mixes[n] {
                        sides.append(
                            GlassSideStrips(
                                owner: objects[n].id, axis: component.axis, outward: component.outward,
                                mix: mix,
                                strips: [(f, area)]))
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
            public var totalSeconds: Double {
                seconds.estimate + seconds.damage + seconds.glass + seconds.structure
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

        public func look(
            charge: SIMD3<Float>, mass: Double, constructions: (UUID) -> EnvelopeConstruction,
            uncertainty: Uncertainty, preview: Bool = false, parts: Parts = .all
        ) -> Look {
            func since(_ start: ContinuousClock.Instant) -> Double {
                let took = start.duration(to: .now)
                return Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
            }
            let memo = preview ? self.memo : SDOFResponseMemo()
            let glassResponses = preview ? self.glassResponses : GlassResponses()
            var clock = ContinuousClock.now
            let estimate: Estimate
            let sides: [GlassSideStrips]
            if preview {
                (estimate, sides) = self.preview(charge: charge, mass: mass)
            } else {
                estimate = self.estimate(charge: charge, mass: mass)
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
                    responses: glassResponses
                ).sides : []
            let glassS = since(clock)
            clock = .now
            let structure =
                parts.contains(.structure)
                ? SDOFResponseMemo.remembering(in: memo) {
                    structureProbabilities(
                        estimate, mass: mass, cellSize: cellSize, constructions: constructions,
                        uncertainty: uncertainty)
                }.0.chances : []
            return Look(
                estimate: estimate, damage: damage, glass: glass, structure: structure, charge: charge,
                preview: preview, seconds: (estimateS, damageS, glassS, since(clock)))
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
                            owner: objects[n].id, axis: key / 2, outward: key % 2 == 1 ? 1 : -1, mix: mix,
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
