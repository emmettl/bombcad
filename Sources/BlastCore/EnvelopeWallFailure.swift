import Foundation

/// When envelope damage judges a wall, roof or slab failed, as single degrees of freedom that can
/// be stepped with the air (`EnvelopeVenting` opens the component's cells then): the systems
/// `EnvelopeDamageAssessment.assess` builds for it, each with the deflections at which its level
/// becomes failed. Concrete fails past 10° of support rotation once yielded (ASCE/SEI 59-11, as
/// `EnvelopeDamageLevel.concrete`); masonry when it has lost all resistance (fallen). A panel or
/// one-way strip fails when either bound, fixed or simply supported, does (the level's worse end);
/// a freestanding wall's cantilever is stepped both ways, and judged by the way the net load has
/// pushed it harder so far (`cantileverLoad` turns the whole history so).
public struct EnvelopeWallFailure: Sendable {
    public struct System: Sendable {
        public var sdof: SDOFSystem
        /// Ductility past 1: the peak inward deflection past this, m (infinite for masonry).
        public var yieldPast: Double
        /// Rotation past 10°: the larger of the peak and rebound past this, m.
        public var rotationPast: Double
        /// Lost all resistance: either way past this, m (infinite for concrete).
        public var lostPast: Double
        /// +1 for the load as recorded, -1 turned (a cantilever's other way).
        public var sign: Double
    }

    public var systems: [System]
    public var cantilever: Bool

    static let failedRotation = 10 * Double.pi / 180

    /// The failure of `load`'s component on `construction`, or nil for a pane, a façade strip (a
    /// solid block's face, with nothing behind it to open into) or a component of no known kind.
    public static func make(_ load: EnvelopeComponentLoad, construction: EnvelopeConstruction)
        -> EnvelopeWallFailure?
    {
        guard load.kind == .wall || load.kind == .roof || load.kind == .slab else { return nil }
        let spans = load.spans
        let a = min(spans.short, EnvelopeDamageAssessment.largestSpan)
        let b = min(spans.long, EnvelopeDamageAssessment.largestSpan)
        var masonry = StructureMaterial.masonry
        masonry.steel = nil
        func concrete(_ sdof: SDOFSystem, rotationSpan: Double, sign: Double = 1) -> System {
            System(
                sdof: sdof, yieldPast: sdof.equivalentElasticDeflection,
                rotationPast: tan(failedRotation) * rotationSpan, lostPast: .infinity, sign: sign)
        }
        func fallen(_ sdof: SDOFSystem, sign: Double = 1) -> System {
            let last = sdof.backbone.last!
            return System(
                sdof: sdof, yieldPast: .infinity, rotationPast: .infinity,
                lostPast: last.y == 0 ? last.x : .infinity, sign: sign)
        }
        if load.isFreestanding {
            let height = min(load.height, EnvelopeDamageAssessment.largestSpan)
            let thickness = Double(construction.wallThicknessM)
            switch construction.walls {
            case .reinforcedConcrete, .reinforcedBlockwork:
                let section = construction.wallBars(thickness: thickness)
                let sdof = EnvelopePanel.reinforcedConcreteCantilever(
                    thickness: thickness, depth: section.depth, steelArea: section.steelArea,
                    material: construction.wallMaterial, height: height,
                    topMass: Double(construction.capMassKgPerM ?? 0))
                // A cantilever's rotation is atan(top / height).
                return EnvelopeWallFailure(
                    systems: [1, -1].map { concrete(sdof, rotationSpan: height, sign: $0) }, cantilever: true)
            case .unreinforcedMasonry:
                let sdof = EnvelopePanel.unreinforcedMasonryCantilever(
                    thickness: thickness, material: masonry, height: height)
                return EnvelopeWallFailure(systems: [1, -1].map { fallen(sdof, sign: $0) }, cantilever: true)
            }
        }
        let isRoof = load.kind == .roof || load.kind == .slab
        let kind = isRoof ? construction.roof : construction.walls
        let thickness = Double(isRoof ? construction.roofThicknessM : construction.wallThicknessM)
        let section = EnvelopeDamageAssessment.section(construction, thickness: thickness, roof: isRoof)
        let material = isRoof ? StructureMaterial.reinforcedConcrete : construction.wallMaterial
        if let span = load.oneWaySpan.map({ min($0, EnvelopeDamageAssessment.largestSpan) }) {
            switch kind {
            case .reinforcedConcrete, .reinforcedBlockwork:
                return EnvelopeWallFailure(
                    systems: [EnvelopePanel.Edges.fixed, .simplySupported].map { edges in
                        concrete(
                            EnvelopePanel.reinforcedOneWay(
                                thickness: thickness, depth: section.depth, steelArea: section.steelArea,
                                material: material, span: span, edges: edges),
                            rotationSpan: span / 2)
                    }, cantilever: false)
            case .unreinforcedMasonry:
                return EnvelopeWallFailure(
                    systems: [
                        fallen(
                            EnvelopePanel.unreinforcedMasonryOneWay(
                                thickness: thickness, material: masonry, span: span, edges: .fixed))
                    ], cantilever: false)
            }
        }
        switch kind {
        case .reinforcedConcrete, .reinforcedBlockwork:
            return EnvelopeWallFailure(
                systems: [EnvelopePanel.Edges.fixed, .simplySupported].map { edges in
                    concrete(
                        EnvelopePanel.reinforcedConcrete(
                            thickness: thickness, depth: section.depth, steelArea: section.steelArea,
                            material: material, a: a, b: b, edges: edges),
                        rotationSpan: a / 2)
                }, cantilever: false)
        case .unreinforcedMasonry:
            return EnvelopeWallFailure(
                systems: [
                    fallen(
                        EnvelopePanel.unreinforcedMasonry(thickness: thickness, material: masonry, a: a, b: b)
                    )
                ],
                cantilever: false)
        }
    }
}
