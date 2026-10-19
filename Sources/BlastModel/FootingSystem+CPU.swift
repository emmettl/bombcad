import Foundation
import simd

/// The bed of springs a rigid footing stands on: points over its base, each bearing in
/// compression only, sliding with Coulomb friction and yielding past its share of the bearing
/// capacity, so that the footing's heel can lift and its contact shift as it turns.
///
/// The points lie on a grid of 17 by 17 over the base, from edge to edge. A bed of equal springs
/// turns two and a half times too easily for its vertical stiffness: a rigid footing on an
/// elastic half-space bears hardest at its edges. So each point's stiffness is its share of
/// (1 − s²)^−a (1 − t²)^−b over the base, s and t running from −1 to 1 across it: the rigid
/// punch's pressure when a = b = 1/2, more and more at the edges as they near 1, and towards the
/// middle below 0. Each
/// exponent is set so that the bed turns about its axis as stiffly, against its vertical
/// stiffness, as the half-space does (`FootingImpedance`), and the bed is scaled to the
/// half-space's vertical stiffness. A long footing turns about its long axis more stiffly than
/// any bed of its width can; there the exponent stops at 0.95 and the bed is scaled to turn as
/// stiffly as the half-space, which makes it stiffer vertically (1.6 times over a strip ten times
/// as long as it is wide). `stiffness` says what the bed gives.
public struct FootingBed: Sendable {
    public struct Point: Sendable {
        /// From the base centre, in metres.
        public var place: SIMD2<Float>
        public var area: Float
        /// N/m.
        public var vertical: Float
        public var horizontal: SIMD2<Float>
    }

    public static let pointsAcross = 17
    /// The greatest exponent of the bed's weighting towards the edges.
    package static let steepest = 0.95

    public var points: [Point]
    /// What the bed gives, by `FootingImpedance.Mode`.
    public var stiffness: [Float]
    /// The cones fitted to it.
    public var impedance: FootingImpedance

    /// The bed under a footing `width` along x and `length` along y on `soil`; set into it by
    /// `embedment`, `thickness` deep, the base is stiffer vertically and horizontally by
    /// Gazetas's trench factor (its sides' share, and the rest of its rocking, is
    /// `FootingSides`').
    public init(width: Float, length: Float, soil: Soil, embedment: Embedment? = nil, thickness: Float = 0) {
        var radiating = soil
        radiating.radiationDamping = true
        let halfSpace = FootingImpedance(width: width, length: length, soil: radiating)
        // Massless soil over a layer is stiffer as the cones' echoes say, statically. (The
        // half-space's rocking stiffness already has the layer's.)
        let trench =
            embedment?.gazetasFactors(width: width, length: length, thickness: thickness).trench
            ?? [1, 1, 1, 1, 1]
        let target = FootingImpedance.Mode.allCases.map {
            (soil.radiationDamping ? halfSpace.stiffness[$0.rawValue] : halfSpace.staticStiffness($0))
                * trench[$0.rawValue]
        }
        let n = Self.pointsAcross
        // Scaled to the vertical stiffness, or stiffer if the rocking needs it: the bed's rocking
        // stiffness over its vertical is mean(s²) (extent / 2)².
        let steepest = Self.punchWeights(n, exponent: Self.steepest).meanSquare
        let scale = max(
            Double(target[0]), Double(target[4]) / (steepest * Double(width * width) / 4),
            Double(target[3]) / (steepest * Double(length * length) / 4))
        // Along each axis: the weights, and the mean square of s they give.
        func axis(_ extent: Float, rocking: Float) -> (weights: [Double], meanSquare: Double) {
            let wanted = Double(rocking) / scale / Double(extent * extent / 4)
            // Below zero the weights gather towards the middle instead.
            var low = -1.0
            var high = Self.steepest
            var best = Self.punchWeights(n, exponent: high)
            if best.meanSquare > wanted {
                for _ in 0..<40 {
                    let middle = 0.5 * (low + high)
                    let trial = Self.punchWeights(n, exponent: middle)
                    if trial.meanSquare > wanted { high = middle } else { low = middle }
                }
                best = Self.punchWeights(n, exponent: 0.5 * (low + high))
            }
            return best
        }
        let alongX = axis(width, rocking: target[4])
        let alongY = axis(length, rocking: target[3])
        let area = width * length
        let total = scale * alongX.weights.reduce(0, +) * alongY.weights.reduce(0, +)
        var points: [Point] = []
        for i in 0..<n {
            for j in 0..<n {
                let s = Float(i) / Float(n - 1) * 2 - 1
                let t = Float(j) / Float(n - 1) * 2 - 1
                // The trapezoid rule's areas, from edge to edge.
                let a =
                    (i == 0 || i == n - 1 ? 0.5 : 1) * (j == 0 || j == n - 1 ? 0.5 : 1)
                    * area / Float((n - 1) * (n - 1))
                // Along the base, the same share: a rigid footing's shear, like its pressure,
                // gathers at its edges, and a point slides when its own share of the footing's
                // friction is used up, all at once.
                let k = scale * alongX.weights[i] * alongY.weights[j]
                points.append(
                    Point(
                        place: SIMD2(s * width / 2, t * length / 2), area: a, vertical: Float(k),
                        horizontal: SIMD2(target[1], target[2]) * Float(k / total)))
            }
        }
        self.points = points
        let vertical = points.reduce(0) { $0 + $1.vertical }
        let aboutX = points.reduce(0) { $0 + $1.vertical * $1.place.y * $1.place.y }
        let aboutY = points.reduce(0) { $0 + $1.vertical * $1.place.x * $1.place.x }
        stiffness = [vertical, target[1], target[2], aboutX, aboutY]
        impedance = FootingImpedance(width: width, length: length, soil: soil, stiffness: stiffness)
    }

    /// The shares of (1 − s²)^−a over `n` points from s = −1 to 1, each over half the gap to its
    /// neighbours, summing to one, and the mean of s² they give.
    static func punchWeights(_ n: Int, exponent a: Double) -> (weights: [Double], meanSquare: Double) {
        // ∫ (1 − s²)^−a ds from s to 1 is ∫ sin^c ψ dψ from 0 to arccos s, c = 1 − 2a; with
        // τ = ψ^(c+1) / (c + 1) the integrand becomes (sin ψ / ψ)^c, smooth, for Simpson's rule.
        let c = 1 - 2 * a
        func tail(_ s: Double) -> Double {
            let end = pow(acos(min(max(s, -1), 1)), c + 1) / (c + 1)
            let m = 64
            var total = 0.0
            for k in 0...(2 * m) {
                let tau = end * Double(k) / Double(2 * m)
                let psi = pow((c + 1) * tau, 1 / (c + 1))
                let f = psi > 0 ? pow(sin(psi) / psi, c) : 1
                total += f * (k == 0 || k == 2 * m ? 1 : (k % 2 == 1 ? 4 : 2))
            }
            return total * end / Double(6 * m)
        }
        // Over [s0, s1] with 0 ≤ s0 ≤ s1 ≤ 1.
        func cell(_ s0: Double, _ s1: Double) -> Double { tail(s0) - tail(s1) }
        let gap = 1 / Double(n - 1)
        var weights: [Double] = []
        var total = 0.0
        var squares = 0.0
        for i in 0..<n {
            let s = Double(i) * 2 * gap - 1
            let low = max(-1, s - gap)
            let high = min(1, s + gap)
            let w =
                low < 0 && high > 0
                ? cell(0, -low) + cell(0, high) : high <= 0 ? cell(-high, -low) : cell(low, high)
            weights.append(w)
            total += w
            squares += w * s * s
        }
        return (weights.map { $0 / total }, squares / total)
    }
}

/// The soil against an embedded footing's sides (`Embedment`): points over each side, from its
/// base up to the soil's surface or its top, 9 along and 5 down, each a spring across the side
/// from the soil's pressure at rest, limited by the active and passive pressures, and a spring
/// along it limited by friction. Their stiffnesses give the footing Gazetas's embedded static
/// stiffness vertically and horizontally along x and y, the base giving the rest; the sides'
/// rocking stiffness follows.
public struct FootingSides: Sendable {
    public struct Point: Sendable {
        /// From the base centre, in metres, and the area it stands for.
        public var place: SIMD3<Float>
        public var area: Float
        /// The side's outward normal, in plan.
        public var normal: SIMD2<Float>
        /// Stiffness across and along the side per unit area, Pa/m.
        public var across: Float
        public var along: Float
        /// The soil's pressure there at rest, active and passive, in Pa.
        public var pressures: SIMD3<Float>
    }

    public static let pointsAlong = 9
    public static let pointsDown = 5

    public var points: [Point]
    /// What the sides add to the footing's static stiffness, by `FootingImpedance.Mode`, about
    /// the base centre.
    public var stiffness: [Float]
    /// What Gazetas's embedded footing has in all, base and sides.
    public var target: [Float]
    /// The rocking stiffness about x and y Gazetas's footing has beyond what the base and the
    /// sides' springs give: a spring on the footing itself. Springs on the sides turn it less
    /// than a quarter as much as Gazetas says embedment does, their lever no longer than the
    /// sides are high.
    public var rocking: SIMD2<Float>
    /// The most moment that spring gives, about x and y: what the passive pressure, less that at
    /// rest, on the side the turning pushes into resists about the base centre.
    public var rockingLimit: SIMD2<Float>
    /// The horizontal force along x per radian of turning about y, and along y per radian about
    /// x, that the sides give about the base centre.
    public var coupling: SIMD2<Float>

    /// The sides of a footing `width` along x by `length` along y and `thickness` deep, set into
    /// `soil` by `embedment`, whose base alone gives `base` (with its trench factor). On a
    /// terrain, `ground`: each column of points is buried as deep as the surface stands over the
    /// base there (none where the base is out of the ground), and each side's active and passive
    /// pressures are those for its ground rising or falling away from it.
    public init(
        width: Float, length: Float, thickness: Float, soil: Soil, embedment: Embedment, base: [Float],
        ground: FootingGround? = nil
    ) {
        let factors = embedment.gazetasFactors(width: width, length: length, thickness: thickness)
        let surface = zip(base, factors.trench).map { $0 / $1 }
        let turns = surface.indices.map { FootingImpedance.Mode(rawValue: $0)!.isRocking }
        target = surface.indices.map {
            surface[$0] * factors.sidewall[$0] * (turns[$0] ? 1 : factors.trench[$0])
        }
        let d = embedment.contactHeight(thickness: thickness)
        let unitWeight = soil.material.density * 9.81
        let n = Self.pointsAlong
        let m = Self.pointsDown
        func weight(_ k: Int, of count: Int) -> Float {
            (k == 0 || k == count - 1 ? 0.5 : 1) / Float(count - 1)
        }
        let sides: [(normal: SIMD2<Float>, extent: Float)] = [
            (SIMD2(1, 0), length), (SIMD2(-1, 0), length), (SIMD2(0, 1), width), (SIMD2(0, -1), width),
        ]
        func plan(_ normal: SIMD2<Float>, _ extent: Float, _ i: Int) -> SIMD2<Float> {
            let s = Float(i) / Float(n - 1) - 0.5
            return normal * SIMD2(width, length) / 2 + SIMD2(-normal.y, normal.x) * s * extent
        }
        // How deep the ground stands over the base at each column, and the side's height in it.
        let buried = sides.map { side in
            (0..<n).map { i in
                ground.map { $0.depth(at: plan(side.normal, side.extent, i)) } ?? embedment.depth
            }
        }
        let heights = buried.map { $0.map { min(max($0, 0), thickness) } }
        // The sides' areas in the soil, facing x and facing y.
        let faces =
            ground == nil
            ? SIMD2(2 * length * d, 2 * width * d)
            : (0..<4).reduce(SIMD2<Float>.zero) { total, k in
                let area = (0..<n).reduce(Float(0)) {
                    $0 + weight($1, of: n) * sides[k].extent * heights[k][$1]
                }
                return total + (k < 2 ? SIMD2(area, 0) : SIMD2(0, area))
            }
        // The springs: along the sides for the vertical stiffness, then across those facing x
        // and y for the horizontal ones, less what the sides along the motion grip.
        let wall = ground == nil ? 2 * (width + length) * d : faces.x + faces.y
        let along = max(target[0] - base[0], 0) / max(wall, 1e-9)
        // (On level ground in the order it always was, bit for bit.)
        let grips =
            ground == nil
            ? SIMD2(along * 2 * width * d, along * 2 * length * d) : along * SIMD2(faces.y, faces.x)
        let acrossX = max((target[1] - base[1] - grips.x) / max(faces.x, 1e-9), 0.01 * along)
        let acrossY = max((target[2] - base[2] - grips.y) / max(faces.y, 1e-9), 0.01 * along)
        var points: [Point] = []
        for (k, side) in sides.enumerated() {
            let coefficients =
                ground.map { embedment.sloping(rise: $0.rise(away: side.normal)) }
                ?? (embedment.atRest, embedment.active, embedment.passive)
            let stiffness = k < 2 ? acrossX : acrossY
            for i in 0..<n where heights[k][i] > 0 {
                for j in 0..<m {
                    let z = Float(j) / Float(m - 1) * heights[k][i]
                    let depth = buried[k][i] - z
                    let place = plan(side.normal, side.extent, i)
                    points.append(
                        Point(
                            place: SIMD3(place.x, place.y, z),
                            area: weight(i, of: n) * weight(j, of: m) * side.extent * heights[k][i],
                            normal: side.normal, across: stiffness, along: along,
                            pressures: SIMD3(coefficients.0, coefficients.1, coefficients.2)
                                * unitWeight * depth))
                }
            }
        }
        self.points = points
        // What they give, turned or moved a little about the base centre.
        func give(_ motion: (SIMD3<Float>) -> SIMD3<Float>, _ measure: (SIMD3<Float>, SIMD3<Float>) -> Float)
            -> Float
        {
            points.reduce(0) { total, point in
                let normal = SIMD3(point.normal.x, point.normal.y, 0)
                let up = SIMD3<Float>(0, 0, 1)
                let sideways = simd_cross(up, normal)
                let u = motion(point.place)
                let force =
                    point.area
                    * (point.across * simd_dot(u, normal) * normal + point.along * simd_dot(u, up) * up
                        + point.along * simd_dot(u, sideways) * sideways)
                return total + measure(point.place, force)
            }
        }
        let stiffness = [
            give({ _ in SIMD3(0, 0, 1) }, { $1.z }),
            give({ _ in SIMD3(1, 0, 0) }, { $1.x }),
            give({ _ in SIMD3(0, 1, 0) }, { $1.y }),
            give({ simd_cross(SIMD3(1, 0, 0), $0) }, { simd_cross($0, $1).x }),
            give({ simd_cross(SIMD3(0, 1, 0), $0) }, { simd_cross($0, $1).y }),
        ]
        self.stiffness = stiffness
        let target = target
        rocking = SIMD2(
            max(target[3] - base[3] - stiffness[3], 0), max(target[4] - base[4] - stiffness[4], 0))
        func limit(_ normal: SIMD2<Float>) -> Float {
            points.filter { $0.normal == normal }.reduce(0) {
                $0 + ($1.pressures.z - $1.pressures.x) * $1.area * $1.place.z
            }
        }
        rockingLimit = SIMD2(limit(SIMD2(0, 1)), limit(SIMD2(1, 0)))
        coupling = SIMD2(
            give({ simd_cross(SIMD3(0, 1, 0), $0) }, { $1.x }),
            give({ simd_cross(SIMD3(1, 0, 0), $0) }, { $1.y }))
    }
}

/// A footing's state after the last step (`StructureSolver.footingSummaries()`).
public struct FootingSummary: Sendable {
    /// The plan: centre of the base at rest, and its extent along x and y.
    public var baseCentre: SIMD3<Float>
    public var size: SIMD2<Float>
    /// Displacement of the base centre, and the footing's rotation as a rotation vector (radians).
    public var displacement: SIMD3<Float>
    public var rotation: SIMD3<Float>
    public var velocity: SIMD3<Float>
    /// The soil's force on the footing, and its moment about the base centre.
    public var soilForce: SIMD3<Float>
    public var soilMoment: SIMD3<Float>
    /// The body's force on the footing through the connection.
    public var jointForce: SIMD3<Float>
    /// The fraction of the bed's stiffness that bears, the largest lift of any point of the base
    /// off the soil, and the deepest the soil has yielded under it, in metres.
    public var bearing: Float
    public var uplift: Float
    public var settlement: Float
    /// The part of the base that bears, from the base centre: least and greatest x, least and
    /// greatest y (empty, least above greatest, when none does).
    public var contact: SIMD4<Float>
    public var mass: Float
    /// Embedded: the soil's force on its sides, and the most the soil has given way or followed
    /// across any side, in metres.
    public var sideForce: SIMD3<Float> = .zero
    public var sideGiveWay: Float = 0
    /// On a terrain: the ground's mean slope round it (∂h/∂x, ∂h/∂y), the factor its slope puts
    /// on the bearing capacity (`FootingGround`), and the most the soil bears under the whole
    /// base, in newtons.
    public var groundSlope: SIMD2<Float> = .zero
    public var bearingFactor: Float = 1
    public var capacity: Float = .infinity

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        baseCentre: SIMD3<Float>,
        size: SIMD2<Float>,
        displacement: SIMD3<Float>,
        rotation: SIMD3<Float>,
        velocity: SIMD3<Float>,
        soilForce: SIMD3<Float>,
        soilMoment: SIMD3<Float>,
        jointForce: SIMD3<Float>,
        bearing: Float,
        uplift: Float,
        settlement: Float,
        contact: SIMD4<Float>,
        mass: Float,
        sideForce: SIMD3<Float> = .zero,
        sideGiveWay: Float = 0,
        groundSlope: SIMD2<Float> = .zero,
        bearingFactor: Float = 1,
        capacity: Float = .infinity
    ) {
        self.baseCentre = baseCentre
        self.size = size
        self.displacement = displacement
        self.rotation = rotation
        self.velocity = velocity
        self.soilForce = soilForce
        self.soilMoment = soilMoment
        self.jointForce = jointForce
        self.bearing = bearing
        self.uplift = uplift
        self.settlement = settlement
        self.contact = contact
        self.mass = mass
        self.sideForce = sideForce
        self.sideGiveWay = sideGiveWay
        self.groundSlope = groundSlope
        self.bearingFactor = bearingFactor
        self.capacity = capacity
    }
}
