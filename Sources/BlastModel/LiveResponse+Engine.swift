import Foundation
import simd

extension LiveResponse {
    /// Where the live drag's work is done: each chosen component's sight line, features and loads
    /// (`loads`), and the networks' rows (`run`). On the GPU in the app (BlastCore's `LiveDragGPU`);
    /// on the CPU here (`CPUEngine`), as the reference and where there is no GPU.
    public protocol Engine: AnyObject, Sendable {
        /// `itemWidth` floats for each of `request`'s items, as `CPUEngine.loads` lays them out.
        func loads(_ request: LoadRequest) throws -> [Float]
        /// The network `name`'s outputs for `count` rows (`Weights.run`).
        func run(_ name: String, rows: [Float], count: Int) throws -> [Float]
        /// What it is, for a status line ("GPU", "CPU").
        var label: String { get }
        /// The GPU's own time on the last call, s (none on the CPU).
        var lastGPUSeconds: Double { get }
    }

    /// An item's floats in `Engine.loads`: its 18 features (`Feature`), then its peak, impulse,
    /// rise, walls' rise and front share at the yield, then its peak and impulse at the yield times
    /// e^`slopeStep`, and its walls' rise there.
    public static let itemWidth = 26
    public static let featureCount = 18

    /// The features' order in an item's floats, as `FacadeLoadSurrogate.Features`'s.
    public enum Feature: Int, CaseIterable {
        case distance, cosine, crossed, blocked, ridge, groundRise, height, shadow, front, edge, edgeFrom,
            edgeTo,
            edgeTop, edgeSide, edgeWidth, lastTop, canyon, canyonHeight
    }

    /// What `Engine.loads` works on: the district's raster (`Prepared.identity` names it, so that a
    /// GPU keeps it between frames), and each item's component, outer face's centre and thin axis,
    /// facing and way out, owner (its index in the raster's objects), whether it takes the roofs'
    /// terms, and its learned peak factor; the charge, its open reach, its yield and the cells.
    public struct LoadRequest: @unchecked Sendable {
        /// The items' components: the district's own, by object and index, not copied.
        public struct Components: Sendable {
            let district: [[EnvelopeComponent]]
            let items: [SIMD2<Int32>]
            public subscript(item: Int) -> EnvelopeComponent {
                district[Int(items[item].x)][Int(items[item].y)]
            }
            public var count: Int { items.count }
        }

        public var identity: UUID
        public var raster: FacadeLoadSurrogate.Raster
        public var components: Components
        public var centres: [SIMD4<Float>]
        public var facings: [SIMD4<Float>]
        public var owners: [SIMD2<Int32>]
        public var factors: [Float]
        public var charge: SIMD3<Float>
        public var openReachM: Double
        public var mass: Double
        public var cellSize: Float
        public var coefficients: FacadeLoadSurrogate.Coefficients
        public var roofCoefficients: FacadeLoadSurrogate.Coefficients

        public var count: Int { components.count }
    }

    /// The live drag's work on the CPU: the features as `FacadeLoadSurrogate.features` gives them and
    /// the loads as `predict`, in double precision; the networks as `Weights.run`.
    public final class CPUEngine: Engine, @unchecked Sendable {
        public let weights: Weights?
        /// Without weights it works out the loads alone.
        public init(weights: Weights?) { self.weights = weights }
        public var label: String { "CPU" }
        public var lastGPUSeconds: Double { 0 }

        public func loads(_ request: LoadRequest) throws -> [Float] {
            var out = [Float](repeating: 0, count: request.count * itemWidth)
            let dx = Double(request.cellSize)
            let stepped = request.mass * exp(slopeStep)
            out.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: request.count) { n in
                    let component = request.components[n]
                    var f = FacadeLoadSurrogate.features(
                        region: component.region, axis: component.axis, outward: component.outward,
                        owner: Int(request.owners[n].x), charge: request.charge, raster: request.raster,
                        facing: SIMD3(request.facings[n].x, request.facings[n].y, request.facings[n].z))
                    f.chargeOpenM = request.openReachM
                    f.learnedPeakFactor = Double(request.factors[n])
                    let terms = request.owners[n].y != 0 ? request.roofCoefficients : request.coefficients
                    let structures = request.owners[n].y != 0 ? terms : terms.forStructures
                    let p = terms.forGlass(
                        FacadeLoadSurrogate.predict(f, mass: request.mass, cellSize: dx, coefficients: terms),
                        distanceM: f.distanceM, mass: request.mass)
                    let rs = FacadeLoadSurrogate.predict(
                        f, mass: request.mass, cellSize: dx, coefficients: structures)
                    let q = FacadeLoadSurrogate.predict(f, mass: stepped, cellSize: dx, coefficients: terms)
                    let qs = FacadeLoadSurrogate.predict(
                        f, mass: stepped, cellSize: dx, coefficients: structures)
                    let values =
                        LiveResponse.values(f) + [
                            p.peakPa, p.impulsePaS, p.riseShare, rs.riseShare, p.frontShare, q.peakPa,
                            q.impulsePaS,
                            qs.riseShare,
                        ]
                    for (k, v) in values.enumerated() { out[n * itemWidth + k] = Float(v) }
                }
            }
            return out
        }

        public func run(_ name: String, rows: [Float], count: Int) throws -> [Float] {
            guard let weights else { throw LearnedFieldError.network("no live response weights") }
            return weights.run(name, rows: rows, count: count)
        }
    }

    /// `f`'s 18 values, in `Feature`'s order.
    static func values(_ f: FacadeLoadSurrogate.Features) -> [Double] {
        [
            f.distanceM, f.cosIncidence, Double(f.buildingsCrossed), f.blockedM, f.ridgeM, f.groundRiseM,
            f.heightM,
            f.shadowM, f.frontM, f.edgeM, f.edgeFromChargeM, f.edgeToTargetM, f.edgeTopM, f.edgeSideM,
            f.edgeWidthM,
            f.lastTopM, f.canyonM, f.canyonHeightM,
        ]
    }

    /// The features an item's floats give back, with the charge's open reach.
    static func features(_ v: UnsafeBufferPointer<Float>, at start: Int, openReachM: Double, factor: Double)
        -> FacadeLoadSurrogate.Features
    {
        func d(_ f: Feature) -> Double { Double(v[start + f.rawValue]) }
        var f = FacadeLoadSurrogate.Features(
            distanceM: d(.distance), cosIncidence: d(.cosine), buildingsCrossed: Int(d(.crossed).rounded()),
            blockedM: d(.blocked), ridgeM: d(.ridge), groundRiseM: d(.groundRise), heightM: d(.height),
            shadowM: d(.shadow), frontM: d(.front), edgeM: d(.edge), edgeFromChargeM: d(.edgeFrom),
            edgeToTargetM: d(.edgeTo), edgeTopM: d(.edgeTop), edgeSideM: d(.edgeSide),
            edgeWidthM: d(.edgeWidth),
            lastTopM: d(.lastTop), canyonM: d(.canyon), canyonHeightM: d(.canyonHeight))
        f.chargeOpenM = openReachM
        f.learnedPeakFactor = factor
        return f
    }
}
