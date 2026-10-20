import Testing

@testable import BlastModel

/// The cracked-hex reference (emmettl/bombcad-work#20 stage 1) against its gate G1: the patch test,
/// an elastic cantilever against beam theory, and a reinforced concrete section's moment against
/// curvature against a fibre section analysis with the same laws, each beside today's one-point
/// element with hourglass control.
@Suite("Cracked hex reference")
struct CrackedHexReferenceTests {
    static let formulations: [CrackedHex.Formulation] = [.today, .fullIntegration, .assumedStrain, .cracked]
    static let elastic = CrackedHex.Law.elastic(youngsModulus: 30e9, poissonRatio: 0.2)

    /// A unit cube of 3 × 3 × 3 elements whose eight interior nodes are moved by up to a quarter
    /// of an element, so that every element touching them is distorted.
    static func distortedMesh() -> CrackedHex.BoxMesh {
        var mesh = CrackedHex.BoxMesh(nx: 3, ny: 3, nz: 3, h: 1.0 / 3)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53) - 0.5
        }
        for i in 1...2 {
            for j in 1...2 {
                for k in 1...2 {
                    mesh.positions[mesh.node(i, j, k)] += SIMD3(next(), next(), next()) * (0.5 / 3)
                }
            }
        }
        return mesh
    }

    /// A linear field's displacement at x, its gradient's symmetric part in Voigt order.
    static let gradient: [[Double]] = [[2e-4, 1e-4, -3e-5], [-4e-5, -1e-4, 6e-5], [5e-5, 2e-5, 3e-4]]
    static func linear(_ x: SIMD3<Double>, scale: Double = 1) -> SIMD3<Double> {
        var u = SIMD3<Double>(1e-5, -2e-5, 3e-5) * scale
        for i in 0..<3 {
            for j in 0..<3 { u[i] += scale * gradient[i][j] * x[j] }
        }
        return u
    }
    static func voigt(scale: Double = 1) -> [Double] {
        let g = gradient
        return [g[0][0], g[1][1], g[2][2], g[0][1] + g[1][0], g[1][2] + g[2][1], g[2][0] + g[0][2]].map {
            $0 * scale
        }
    }

    static func assembly(
        _ mesh: CrackedHex.BoxMesh, law: CrackedHex.Law, formulation: CrackedHex.Formulation
    ) -> CrackedHex.Assembly {
        CrackedHex.Assembly(
            elements: mesh.elements.map {
                CrackedHex.Element(
                    geometry: mesh.geometry($0.i, $0.j, $0.k), law: law, formulation: formulation)
            },
            connectivity: mesh.elements.map { mesh.elementNodes($0.i, $0.j, $0.k) }, nodeCount: mesh.nodeCount
        )
    }

    static func boundary(_ mesh: CrackedHex.BoxMesh, scale: Double = 1) -> [CrackedHex.Dof] {
        var dofs = Array(repeating: CrackedHex.Dof.free, count: 3 * mesh.nodeCount)
        for i in 0...mesh.nx {
            for j in 0...mesh.ny {
                for k in 0...mesh.nz
                where [i, j, k].contains(0) || i == mesh.nx || j == mesh.ny || k == mesh.nz {
                    let node = mesh.node(i, j, k)
                    let u = linear(mesh.positions[node], scale: scale)
                    for c in 0..<3 { dofs[3 * node + c] = .fixed(u[c]) }
                }
            }
        }
        return dofs
    }

    @Test("The patch test: a linear field on a distorted mesh is reproduced exactly", arguments: formulations)
    func patch(formulation: CrackedHex.Formulation) {
        let mesh = Self.distortedMesh()
        let assembly = Self.assembly(mesh, law: Self.elastic, formulation: formulation)
        let u = assembly.solveLinear(
            dofs: Self.boundary(mesh), load: Array(repeating: 0, count: 3 * mesh.nodeCount))
        let exact = Self.voigt()
        var worstDisplacement = 0.0
        for node in 0..<mesh.nodeCount {
            let expected = Self.linear(mesh.positions[node])
            for c in 0..<3 { worstDisplacement = max(worstDisplacement, abs(u[3 * node + c] - expected[c])) }
        }
        #expect(worstDisplacement < 1e-12, "interior nodes off the linear field by \(worstDisplacement) m")
        // Every point of every element, at the centre and the eight Gauss points, has the field's
        // strain; and the hourglass amplitudes vanish.
        var worstStrain = 0.0
        for e in assembly.elements.indices {
            let local = assembly.gather(u, e)
            let geometry = assembly.elements[e].geometry
            for b in [geometry.centre] + geometry.assumed + geometry.full {
                let strain = assembly.elements[e].multiply(b, local)
                for v in 0..<6 { worstStrain = max(worstStrain, abs(strain[v] - exact[v])) }
            }
            for q in geometry.hourglassAmplitudes(local) { #expect(CrackedHex.length(q) < 1e-14) }
        }
        #expect(worstStrain < 1e-12 * 3e-4, "strain off by \(worstStrain)")
    }

    @Test(
        "Cracked uniformly, the patch stays uniform, every point with the same crack", arguments: formulations
    )
    func crackedPatch(formulation: CrackedHex.Formulation) throws {
        var concrete = CrackedHex.ReinforcedSection.standard.concrete
        concrete.bandWidth = 1.0 / 3
        let mesh = Self.distortedMesh()
        var assembly = Self.assembly(mesh, law: .concrete(concrete), formulation: formulation)
        // The field's xx strain (2e-4) is twice the cracking strain; its yy shortens and zz opens too.
        // Each step starts Newton from the field nudged by a nanometre, so that it has to find the
        // uniform state again (softening, the patch has other states nearby; this checks that the
        // uniform one is in equilibrium point by point, not that Newton finds it from afar).
        for step in 1...8 {
            let scale = Double(step) / 8
            let dofs = Self.boundary(mesh, scale: scale)
            let (index, count) = CrackedHex.Assembly.numbering(dofs, masters: 0)
            var x = Array(repeating: 0.0, count: count)
            for node in 0..<mesh.nodeCount {
                let u = Self.linear(mesh.positions[node], scale: scale)
                for c in 0..<3 {
                    if let i = index[3 * node + c] { x[i] = u[c] + 1e-9 * Double((node * 7 + c * 3) % 5 - 2) }
                }
            }
            let result = assembly.solveNonlinear(dofs: dofs, masters: 0, from: x)
            let solved = try #require(result)
            if step == 8 {
                var worst = 0.0
                for node in 0..<mesh.nodeCount {
                    let expected = Self.linear(mesh.positions[node])
                    for c in 0..<3 {
                        worst = max(worst, abs(solved.displacement[3 * node + c] - expected[c]))
                    }
                }
                #expect(worst < 1e-12, "off the linear field by \(worst) m")
            }
        }
        // The points that carry the history: the centre for today's element (and a switching one
        // not yet switched), the eight Gauss points otherwise.
        func carriers(_ state: CrackedHex.ElementHistory) -> [CrackedHex.PointHistory] {
            switch formulation {
            case .onePointHourglass: return [state.centre]
            case .switching: return state.switched ? state.points : [state.centre]
            default: return state.points
            }
        }
        let reference = carriers(assembly.states[0])[0].tension
        #expect(reference.x > 1.9 * concrete.crackingStrain && reference.z > concrete.crackingStrain)
        for state in assembly.states {
            for point in carriers(state) {
                #expect(
                    abs(point.tension.x - reference.x) < 1e-12 && abs(point.tension.z - reference.z) < 1e-12)
            }
        }
        if case .switching = formulation {
            let allSwitched = assembly.states.allSatisfy(\.switched)
            let noHourglass = assembly.states.allSatisfy { state in
                state.hourglassForce.allSatisfy { $0 == .zero }
            }
            #expect(allSwitched)
            #expect(noHourglass)
        }
    }

    @Test("The assumed-strain element has only the six rigid-body modes free")
    func noSpuriousModes() {
        // A brick 2 × 1 × 0.5, sheared and tapered a little.
        var rest: [SIMD3<Double>] = (0..<8).map { a in
            let s = CrackedHex.corner(a)
            return SIMD3(s.x * 1.0, s.y * 0.5, s.z * 0.25)
        }
        rest[7] += SIMD3(0.1, -0.05, 0.03)
        rest[2] += SIMD3(-0.05, 0.02, 0)
        let element = CrackedHex.Element(
            geometry: CrackedHex.Geometry(rest: rest), law: Self.elastic, formulation: .assumedStrain)
        let k = element.evaluate(Array(repeating: 0, count: 24), from: element.initialState).tangent
        // Hold corner 0 fully, corner 1 across y and z and corner 2 across z: what is left must be
        // positive definite.
        let held: Set<Int> = [0, 1, 2, 4, 5, 8]
        let free = (0..<24).filter { !held.contains($0) }
        var a = free.flatMap { i in free.map { j in k[24 * i + j] } }
        let n = free.count
        let largest = (0..<n).map { a[n * $0 + $0] }.max()!
        var smallestPivot = Double.infinity
        for c in 0..<n {
            var d = a[n * c + c]
            for p in 0..<c { d -= a[n * c + p] * a[n * c + p] }
            smallestPivot = min(smallestPivot, d)
            guard d > 0 else { break }
            a[n * c + c] = d.squareRoot()
            for r in (c + 1)..<n {
                var v = a[n * r + c]
                for p in 0..<c { v -= a[n * r + p] * a[n * c + p] }
                a[n * r + c] = v / a[n * c + c]
            }
        }
        #expect(smallestPivot > 1e-4 * largest, "smallest pivot \(smallestPivot) of \(largest)")
    }

    @Test("An elastic cantilever matches beam theory within 5% on two and four elements through")
    func cantilever() {
        for n in [1, 2, 4] {
            let assumed = CrackedHex.cantilever(elementsThroughDepth: n, formulation: .assumedStrain).ratio
            let today = CrackedHex.cantilever(elementsThroughDepth: n, formulation: .today).ratio
            let switching = CrackedHex.cantilever(elementsThroughDepth: n, formulation: .cracked).ratio
            let full = CrackedHex.cantilever(elementsThroughDepth: n, formulation: .fullIntegration).ratio
            // Elastic, the switching element never switches: it is today's.
            #expect(abs(switching - today) < 1e-12)
            if n >= 2 {
                #expect(abs(assumed - 1) < 0.05, "\(n) through: assumed strain \(assumed) of beam theory")
                #expect(abs(today - 1) < 0.05, "\(n) through: today's \(today) of beam theory")
            } else {
                // One element deep, Poisson's ratio stiffens it by about 1 / (1 − ν²) (no ASQBI term).
                #expect(assumed > 0.9 && assumed < 1, "one through: assumed strain \(assumed)")
            }
            // Plain full integration locks in bending (parasitic shear), worst on the coarsest mesh.
            #expect(full < assumed - 0.015, "\(n) through: full integration \(full)")
            if n == 1 { #expect(full < 0.8, "one through: full integration \(full)") }
        }
    }

    /// Curvatures for the moment–curvature check, per metre: to 0.004 by 0.0002, then to 0.06 by
    /// 0.002 (the section's top fibre past 0.0035).
    static let curvatures: [Double] =
        stride(from: 0.0002, through: 0.004, by: 0.0002).map { $0 }
        + stride(from: 0.006, through: 0.06, by: 0.002).map { $0 }

    @Test(
        "A reinforced section's moment–curvature matches section analysis within 5% on 4, 6 and 12 through",
        arguments: [4, 6, 12])
    func momentCurvature(elementsThroughDepth n: Int) {
        let section = CrackedHex.ReinforcedSection.standard
        let h = section.depth / Double(n)
        let reference = CrackedHex.sectionAnalysis(section, bandWidth: h, curvatures: Self.curvatures)
        let cracked = CrackedHex.momentCurvature(
            section, elementsThroughDepth: n, formulation: .cracked, curvatures: Self.curvatures,
            smearedBars: false)
        #expect(cracked.moments.count == Self.curvatures.count, "the static solve stopped")
        // Declared before running: every curvature from twice the cracking curvature on.
        var worstCracked = 0.0
        for (i, kappa) in Self.curvatures.enumerated() where kappa >= 2 * section.crackingCurvature {
            worstCracked = max(worstCracked, abs(cracked.moments[i] / reference[i] - 1))
        }
        #expect(
            worstCracked < 0.05, "\(n) through: the cracked element off section analysis by \(worstCracked)")
        // Today's element runs strong where the compression zone is thinner than an element. (On 12
        // through it is within 2% as far as its static solve converges, to 0.014 per metre.)
        if n <= 6 {
            let today = CrackedHex.momentCurvature(
                section, elementsThroughDepth: n, formulation: .today, curvatures: Self.curvatures,
                smearedBars: true)
            var worstToday = 0.0
            for (i, kappa) in Self.curvatures.enumerated()
            where kappa >= 2 * section.crackingCurvature && i < today.moments.count {
                worstToday = max(worstToday, abs(today.moments[i] / reference[i] - 1))
            }
            #expect(worstToday > 0.05, "today's \(worstToday), the cracked element's \(worstCracked)")
        }
        #expect(cracked.switched > 0)
    }
}
