// Static checks of the cracked-hex reference (CrackedHexReference.swift): a box mesh, a linear and
// a Newton solver, the elastic cantilever against beam theory, and a reinforced concrete section's
// moment against curvature against a fibre section analysis with the same laws.

extension CrackedHex {
    /// A box of `nx` × `ny` × `nz` cubic elements of side `h`, from the origin. Nodes run with x
    /// slowest, so the stiffness is banded.
    public struct BoxMesh: Sendable {
        public let nx: Int
        public let ny: Int
        public let nz: Int
        public let h: Double
        /// Rest positions, moved from the lattice where a check distorts the mesh.
        public var positions: [SIMD3<Double>]

        public init(nx: Int, ny: Int, nz: Int, h: Double) {
            self.nx = nx
            self.ny = ny
            self.nz = nz
            self.h = h
            var positions: [SIMD3<Double>] = []
            for i in 0...nx {
                for j in 0...ny {
                    for k in 0...nz { positions.append(SIMD3(Double(i), Double(j), Double(k)) * h) }
                }
            }
            self.positions = positions
        }

        public var nodeCount: Int { (nx + 1) * (ny + 1) * (nz + 1) }
        public func node(_ i: Int, _ j: Int, _ k: Int) -> Int { k + (nz + 1) * (j + (ny + 1) * i) }

        public func elementNodes(_ i: Int, _ j: Int, _ k: Int) -> [Int] {
            (0..<8).map { a in node(i + (a & 1), j + (a >> 1) & 1, k + (a >> 2) & 1) }
        }

        public var elements: [(i: Int, j: Int, k: Int)] {
            var list: [(Int, Int, Int)] = []
            for i in 0..<nx {
                for j in 0..<ny {
                    for k in 0..<nz { list.append((i, j, k)) }
                }
            }
            return list
        }

        public func geometry(_ i: Int, _ j: Int, _ k: Int) -> Geometry {
            Geometry(rest: elementNodes(i, j, k).map { positions[$0] })
        }
    }

    /// How each degree of freedom is held: free, prescribed, or prescribed plus a coefficient
    /// times one of a few shared unknowns (an end face's axial shift).
    public enum Dof: Sendable, Equatable {
        case free
        case fixed(Double)
        case linked(base: Double, master: Int, coefficient: Double)
    }

    /// Elements on a mesh with their histories, and the solves.
    public struct Assembly: Sendable {
        public var elements: [Element]
        public var connectivity: [[Int]]
        public var states: [ElementHistory]
        public let nodeCount: Int

        public init(elements: [Element], connectivity: [[Int]], nodeCount: Int) {
            self.elements = elements
            self.connectivity = connectivity
            self.nodeCount = nodeCount
            states = elements.map(\.initialState)
        }

        func gather(_ u: [Double], _ e: Int) -> [Double] {
            var local = Array(repeating: 0.0, count: 24)
            for (a, n) in connectivity[e].enumerated() {
                for c in 0..<3 { local[3 * a + c] = u[3 * n + c] }
            }
            return local
        }

        /// Internal forces at `u` from the committed histories, with the trial histories and each
        /// element's tangent.
        public func evaluate(_ u: [Double], switchNow: [Bool]? = nil) -> (
            force: [Double], responses: [Response]
        ) {
            var force = Array(repeating: 0.0, count: 3 * nodeCount)
            var responses: [Response] = []
            for e in elements.indices {
                let r = elements[e].evaluate(gather(u, e), from: states[e], switchNow: switchNow?[e] ?? false)
                for (a, n) in connectivity[e].enumerated() {
                    for c in 0..<3 { force[3 * n + c] += r.force[3 * a + c] }
                }
                responses.append(r)
            }
            return (force, responses)
        }

        /// The unknowns' numbering: free dofs in order, then the shared unknowns.
        static func numbering(_ dofs: [Dof], masters: Int) -> (index: [Int?], count: Int) {
            var index: [Int?] = []
            var count = 0
            for dof in dofs {
                if case .free = dof {
                    index.append(count)
                    count += 1
                } else {
                    index.append(nil)
                }
            }
            return (index, count + masters)
        }

        /// The displacement from the unknowns.
        static func displacement(_ x: [Double], dofs: [Dof], index: [Int?], free: Int) -> [Double] {
            dofs.enumerated().map { d, dof in
                switch dof {
                case .free: return x[index[d]!]
                case .fixed(let value): return value
                case .linked(let base, let master, let coefficient):
                    return base + coefficient * x[free + master]
                }
            }
        }

        /// Each dof's (unknown, coefficient), if it has one.
        static func map(_ d: Int, dofs: [Dof], index: [Int?], free: Int) -> (Int, Double)? {
            switch dofs[d] {
            case .free: return (index[d]!, 1)
            case .fixed: return nil
            case .linked(_, let master, let coefficient): return (free + master, coefficient)
            }
        }

        /// Linear solve K u = f for an elastic assembly at rest, by banded Cholesky; `dofs` may
        /// not link. Returns the displacement.
        public func solveLinear(dofs: [Dof], load: [Double]) -> [Double] {
            let (index, count) = Assembly.numbering(dofs, masters: 0)
            let zero = Array(repeating: 0.0, count: 3 * nodeCount)
            var prescribed = zero
            for (d, dof) in dofs.enumerated() {
                if case .fixed(let value) = dof { prescribed[d] = value }
            }
            let (_, responses) = evaluate(zero)
            var band = 0
            for nodes in connectivity {
                let unknowns = nodes.flatMap { n in (0..<3).compactMap { index[3 * n + $0] } }
                if let low = unknowns.min(), let high = unknowns.max() { band = max(band, high - low) }
            }
            var matrix = BandedMatrix(count: count, band: band)
            var rhs = Array(repeating: 0.0, count: count)
            for d in 0..<(3 * nodeCount) {
                if let i = index[d] { rhs[i] += load[d] }
            }
            for (e, nodes) in connectivity.enumerated() {
                let global = nodes.flatMap { n in (0..<3).map { 3 * n + $0 } }
                for p in 0..<24 {
                    guard let i = index[global[p]] else { continue }
                    for q in 0..<24 {
                        let k = responses[e].tangent[24 * p + q]
                        if let j = index[global[q]] {
                            if j <= i { matrix.add(i, j, k) }
                        } else {
                            rhs[i] -= k * prescribed[global[q]]
                        }
                    }
                }
            }
            let x = matrix.solve(rhs)
            return Assembly.displacement(x, dofs: dofs, index: index, free: count)
        }

        /// Newton's method to equilibrium with no load on the free dofs, from the unknowns `x`,
        /// with a backtracking line search, committing the histories when it converges. Returns the
        /// unknowns and the displacement, or nil (histories untouched) if it does not converge.
        public mutating func solveNonlinear(
            dofs: [Dof], masters: Int, from start: [Double], tolerance: Double = 1e-9, iterations: Int = 60
        ) -> (unknowns: [Double], displacement: [Double])? {
            let (index, count) = Assembly.numbering(dofs, masters: masters)
            let free = count - masters
            var switchNow = Array(repeating: false, count: elements.count)
            struct Trial {
                var x: [Double]
                var u: [Double]
                var residual: [Double]
                var norm: Double
                var scale: Double
                var responses: [Response]
            }
            func trial(_ x: [Double]) -> Trial {
                let u = Assembly.displacement(x, dofs: dofs, index: index, free: free)
                let (force, responses) = evaluate(u, switchNow: switchNow)
                var residual = Array(repeating: 0.0, count: count)
                var scale = 0.0
                for d in force.indices {
                    scale = max(scale, abs(force[d]))
                    if let (i, c) = Assembly.map(d, dofs: dofs, index: index, free: free) {
                        residual[i] += c * force[d]
                    }
                }
                let norm = residual.reduce(0.0) { max($0, abs($1)) }
                return Trial(x: x, u: u, residual: residual, norm: norm, scale: scale, responses: responses)
            }
            var current = trial(start)
            for _ in 0..<iterations {
                // A switch made in one iteration holds for the rest of the step.
                for (e, r) in current.responses.enumerated() where r.state.switched { switchNow[e] = true }
                if current.norm <= tolerance * max(current.scale, 1e-30) {
                    states = current.responses.map(\.state)
                    return (current.x, current.u)
                }
                var matrix = Array(repeating: 0.0, count: count * count)
                for (e, nodes) in connectivity.enumerated() {
                    let global = nodes.flatMap { n in (0..<3).map { 3 * n + $0 } }
                    let maps = global.map { Assembly.map($0, dofs: dofs, index: index, free: free) }
                    for p in 0..<24 {
                        guard let (i, ci) = maps[p] else { continue }
                        for q in 0..<24 {
                            guard let (j, cj) = maps[q] else { continue }
                            matrix[count * i + j] += ci * cj * current.responses[e].tangent[24 * p + q]
                        }
                    }
                }
                guard let step = CrackedHex.solveDense(matrix, current.residual.map { -$0 }, count: count)
                else {
                    return nil
                }
                var best: Trial?
                var fraction = 1.0
                for _ in 0..<8 {
                    let next = trial((0..<count).map { current.x[$0] + fraction * step[$0] })
                    if best == nil || next.norm < best!.norm { best = next }
                    if next.norm < current.norm { break }
                    fraction /= 2
                }
                current = best!
            }
            return nil
        }
    }

    /// A symmetric positive-definite banded matrix, its lower band stored by rows.
    struct BandedMatrix {
        let count: Int
        let band: Int
        var values: [Double]

        init(count: Int, band: Int) {
            self.count = count
            self.band = band
            values = Array(repeating: 0, count: count * (band + 1))
        }

        /// Adds to entry (i, j), j ≤ i.
        mutating func add(_ i: Int, _ j: Int, _ v: Double) { values[i * (band + 1) + i - j] += v }
        func get(_ i: Int, _ j: Int) -> Double { i - j > band ? 0 : values[i * (band + 1) + i - j] }

        /// Cholesky factorisation and the two substitutions.
        func solve(_ rhs: [Double]) -> [Double] {
            var l = self
            for i in 0..<count {
                for j in max(0, i - band)...i {
                    var sum = l.get(i, j)
                    for k in max(0, i - band, j - band)..<j { sum -= l.get(i, k) * l.get(j, k) }
                    if i == j {
                        precondition(sum > 0, "the stiffness is not positive definite")
                        l.values[i * (band + 1)] = sum.squareRoot()
                    } else {
                        l.values[i * (band + 1) + i - j] = sum / l.get(j, j)
                    }
                }
            }
            var y = rhs
            for i in 0..<count {
                for k in max(0, i - band)..<i { y[i] -= l.get(i, k) * y[k] }
                y[i] /= l.get(i, i)
            }
            for i in stride(from: count - 1, through: 0, by: -1) {
                for k in (i + 1)..<min(count, i + band + 1) { y[i] -= l.get(k, i) * y[k] }
                y[i] /= l.get(i, i)
            }
            return y
        }
    }

    /// Gaussian elimination with partial pivoting; nil if singular.
    static func solveDense(_ matrix: [Double], _ rhs: [Double], count n: Int) -> [Double]? {
        var a = matrix
        var b = rhs
        for c in 0..<n {
            var pivot = c
            for r in (c + 1)..<max(n, c + 1) where abs(a[n * r + c]) > abs(a[n * pivot + c]) { pivot = r }
            if abs(a[n * pivot + c]) < 1e-300 { return nil }
            if pivot != c {
                for k in 0..<n { a.swapAt(n * c + k, n * pivot + k) }
                b.swapAt(c, pivot)
            }
            let diagonal = a[n * c + c]
            for r in (c + 1)..<max(n, c + 1) {
                let f = a[n * r + c] / diagonal
                if f == 0 { continue }
                for k in c..<n { a[n * r + k] -= f * a[n * c + k] }
                b[r] -= f * b[c]
            }
        }
        var x = Array(repeating: 0.0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[r]
            for k in (r + 1)..<max(n, r + 1) { sum -= a[n * r + k] * x[k] }
            x[r] = sum / a[n * r + r]
        }
        return x
    }
}

// MARK: - The elastic cantilever

extension CrackedHex {
    public struct CantileverResult: Sendable {
        /// The tip's deflection conjugate to the load (its work over the load), and beam theory's
        /// with shear (Timoshenko's coefficient 10 (1 + ν) / (12 + 11 ν)).
        public var deflection: Double
        public var beamTheory: Double
        public var ratio: Double { deflection / beamTheory }
    }

    /// A cantilever `slenderness` depths long and one element wide, `elements` through its depth,
    /// clamped over its root face and loaded by a uniform shear over its tip face.
    public static func cantilever(
        elementsThroughDepth n: Int, formulation: Formulation, slenderness: Int = 10, depth: Double = 0.3,
        youngsModulus: Double = 30e9, poissonRatio: Double = 0.2
    ) -> CantileverResult {
        let h = depth / Double(n)
        let mesh = BoxMesh(nx: slenderness * n, ny: 1, nz: n, h: h)
        let law = Law.elastic(youngsModulus: youngsModulus, poissonRatio: poissonRatio)
        let assembly = Assembly(
            elements: mesh.elements.map {
                Element(geometry: mesh.geometry($0.i, $0.j, $0.k), law: law, formulation: formulation)
            },
            connectivity: mesh.elements.map { mesh.elementNodes($0.i, $0.j, $0.k) }, nodeCount: mesh.nodeCount
        )
        var dofs = Array(repeating: Dof.free, count: 3 * mesh.nodeCount)
        var load = Array(repeating: 0.0, count: 3 * mesh.nodeCount)
        let p = 1e5
        let width = h
        for j in 0...mesh.ny {
            for k in 0...mesh.nz {
                for c in 0..<3 { dofs[3 * mesh.node(0, j, k) + c] = .fixed(0) }
                let share =
                    (j == 0 || j == mesh.ny ? 0.5 : 1) * (k == 0 || k == mesh.nz ? 0.5 : 1) / Double(n)
                load[3 * mesh.node(mesh.nx, j, k) + 2] = -p * share
            }
        }
        let u = assembly.solveLinear(dofs: dofs, load: load)
        let work = zip(load, u).reduce(0.0) { $0 + $1.0 * $1.1 }
        let length = Double(slenderness) * depth
        let inertia = width * depth * depth * depth / 12
        let shear = youngsModulus / (2 * (1 + poissonRatio))
        let kappa = 10 * (1 + poissonRatio) / (12 + 11 * poissonRatio)
        let beam =
            p * length * length * length / (3 * youngsModulus * inertia) + p * length
            / (kappa * shear * width * depth)
        return CantileverResult(deflection: work / p, beamTheory: beam)
    }
}

// MARK: - A reinforced concrete section in bending

extension CrackedHex {
    /// A rectangular section reinforced near its tension face: `depth`, bars `barHeight` above the
    /// tension face with `barAreaPerWidth` m² per metre width.
    public struct ReinforcedSection: Sendable {
        public var depth: Double
        public var barHeight: Double
        public var barAreaPerWidth: Double
        public var concrete: Concrete
        public var steel: Steel

        public init(
            depth: Double, barHeight: Double, barAreaPerWidth: Double, concrete: Concrete, steel: Steel
        ) {
            self.depth = depth
            self.barHeight = barHeight
            self.barAreaPerWidth = barAreaPerWidth
            self.concrete = concrete
            self.steel = steel
        }

        /// 300 mm deep, 1% steel (of the depth to the bars) yielding at 500 MPa, 45 mm above the
        /// tension face; concrete of 30 MPa, E 30 GPa (so its peak at 0.002), f_t 2.9 MPa and
        /// G_f 140 N/m (the fib Model Code 2010's for that strength, recalled).
        public static let standard = ReinforcedSection(
            depth: 0.3, barHeight: 0.045, barAreaPerWidth: 0.01 * 0.255,
            concrete: Concrete(
                youngsModulus: 30e9, compressiveStrength: 30e6, tensileStrength: 2.9e6, fractureEnergy: 140,
                bandWidth: 0.075),
            steel: Steel(yieldStress: 500e6))

        /// The curvature at which the section's extreme fibre cracks, uncracked and elastic.
        public var crackingCurvature: Double { 2 * concrete.crackingStrain / depth }
    }

    /// Moment per unit width against curvature (tension face first) by fibre section analysis,
    /// plane sections and no axial force, with the elements' laws and the crack band `bandWidth`.
    public static func sectionAnalysis(
        _ section: ReinforcedSection, bandWidth: Double, curvatures: [Double], fibres: Int = 3000
    ) -> [Double] {
        var concrete = section.concrete
        concrete.bandWidth = bandWidth
        let dz = section.depth / Double(fibres)
        let middle = section.depth / 2
        let heights = (0..<fibres).map { (Double($0) + 0.5) * dz }
        var committed = Array(repeating: (tension: 0.0, compression: 0.0), count: fibres)
        var steelState = Steel.State()
        var reference = 0.0
        var moments: [Double] = []
        for kappa in curvatures {
            func evaluate(_ e0: Double) -> (
                force: Double, stiffness: Double, moment: Double, fibres: [(Double, Double)],
                steel: Steel.State
            ) {
                var force = 0.0
                var stiffness = 0.0
                var moment = 0.0
                var trial = committed
                for f in 0..<fibres {
                    let e = e0 - kappa * (heights[f] - middle)
                    var most = trial[f].tension
                    var deepest = trial[f].compression
                    let (s, t) = concrete.normal(e, tension: &most, compression: &deepest)
                    trial[f] = (most, deepest)
                    force += s * dz
                    stiffness += t * dz
                    moment -= s * dz * (heights[f] - middle)
                }
                var bar = steelState
                let e = e0 - kappa * (section.barHeight - middle)
                let (s, t) = section.steel.stress(e, state: &bar)
                force += s * section.barAreaPerWidth
                stiffness += t * section.barAreaPerWidth
                moment -= s * section.barAreaPerWidth * (section.barHeight - middle)
                return (force, stiffness, moment, trial.map { ($0.tension, $0.compression) }, bar)
            }
            // Newton on the mid-depth strain, falling back on bisection.
            var e0 = reference
            var result = evaluate(e0)
            var converged = false
            for _ in 0..<60 {
                if abs(result.force) < 1e-7 * section.concrete.compressiveStrength * section.depth {
                    converged = true
                    break
                }
                guard result.stiffness > 0 else { break }
                e0 -= result.force / result.stiffness
                result = evaluate(e0)
            }
            if !converged {
                var low = reference - 0.02
                var high = reference + 0.02
                for _ in 0..<200 {
                    e0 = (low + high) / 2
                    result = evaluate(e0)
                    if result.force > 0 { high = e0 } else { low = e0 }
                }
            }
            reference = e0
            committed = result.fibres.map { (tension: $0.0, compression: $0.1) }
            steelState = result.steel
            moments.append(result.moment)
        }
        return moments
    }

    public struct MomentCurvatureResult: Sendable {
        public var curvatures: [Double]
        /// Moment per unit width at each curvature, from the end face's reactions; shorter than
        /// `curvatures` where the static solve stopped converging.
        public var moments: [Double]
        /// Elements switched to their eight points by the end, of all.
        public var switched: Int
        public var elements: Int
    }

    /// A length of the section two elements long and one wide, `n` elements through its depth,
    /// bent by turning its end faces about their mid-depth (each by half the curvature times the
    /// length) with a shared axial shift that leaves no axial force; the bars run along the length.
    /// With `smearedBars` (today's placing) the bars are spread over a band one element deep centred
    /// on them, split between the layers it overlaps and strained with each element's centre;
    /// otherwise each element holding them strains them at their own height.
    public static func momentCurvature(
        _ section: ReinforcedSection, elementsThroughDepth n: Int, formulation: Formulation,
        curvatures: [Double],
        smearedBars: Bool, tolerance: Double = 1e-9
    ) -> MomentCurvatureResult {
        let h = section.depth / Double(n)
        let mesh = BoxMesh(nx: 2, ny: 1, nz: n, h: h)
        var concrete = section.concrete
        concrete.bandWidth = h
        let law = Law.concrete(concrete)
        let area = section.barAreaPerWidth * h
        var elements: [Element] = []
        for e in mesh.elements {
            var bars: [Bar] = []
            let bottom = Double(e.k) * h
            if smearedBars {
                let overlap =
                    min(bottom + h, section.barHeight + h / 2) - max(bottom, section.barHeight - h / 2)
                if overlap > 0 {
                    bars.append(Bar(axis: 0, area: area * overlap / h, position: .zero, spreadAcross: 1))
                }
            } else if section.barHeight >= bottom && section.barHeight < bottom + h {
                let zeta = 2 * (section.barHeight - bottom) / h - 1
                bars.append(Bar(axis: 0, area: area, position: SIMD3(0, 0, zeta), spreadAcross: 1))
            }
            elements.append(
                Element(
                    geometry: mesh.geometry(e.i, e.j, e.k), law: law, formulation: formulation,
                    steel: section.steel,
                    bars: bars))
        }
        var assembly = Assembly(
            elements: elements, connectivity: mesh.elements.map { mesh.elementNodes($0.i, $0.j, $0.k) },
            nodeCount: mesh.nodeCount)
        let length = 2 * h
        let middle = section.depth / 2
        func dofs(_ kappa: Double) -> [Dof] {
            let theta = kappa * length / 2
            var dofs = Array(repeating: Dof.free, count: 3 * mesh.nodeCount)
            for i in 0...mesh.nx {
                for j in 0...mesh.ny {
                    for k in 0...mesh.nz {
                        let node = mesh.node(i, j, k)
                        dofs[3 * node + 1] = .fixed(0)
                        guard i == 0 || i == mesh.nx else { continue }
                        let side: Double = i == 0 ? -1 : 1
                        let z = Double(k) * h - middle
                        dofs[3 * node] = .linked(base: -side * theta * z, master: 0, coefficient: side)
                        dofs[3 * node + 2] = .fixed(0)
                    }
                }
            }
            return dofs
        }
        let (_, count) = Assembly.numbering(dofs(0), masters: 1)
        var x = Array(repeating: 0.0, count: count)
        var moments: [Double] = []
        var reached = 0.0
        steps: for target in curvatures {
            // Halve the step where Newton fails; stop where eight halvings do not help.
            var pending = [target]
            while let kappa = pending.last {
                let saved = assembly.states
                if let solved = assembly.solveNonlinear(
                    dofs: dofs(kappa), masters: 1, from: x, tolerance: tolerance)
                {
                    x = solved.unknowns
                    reached = kappa
                    pending.removeLast()
                } else {
                    assembly.states = saved
                    guard pending.count < 8 else { break steps }
                    pending.append((reached + kappa) / 2)
                }
            }
            let u = Assembly.displacement(
                x, dofs: dofs(target), index: Assembly.numbering(dofs(target), masters: 1).index,
                free: count - 1)
            let (force, _) = assembly.evaluate(u)
            var moment = 0.0
            for j in 0...mesh.ny {
                for k in 0...mesh.nz {
                    moment -= force[3 * mesh.node(mesh.nx, j, k)] * (Double(k) * h - middle)
                }
            }
            moments.append(moment / h)
        }
        return MomentCurvatureResult(
            curvatures: curvatures, moments: moments, switched: assembly.states.filter(\.switched).count,
            elements: elements.count)
    }
}
