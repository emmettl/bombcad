import Foundation
import simd

/// A buckling curve of EN 1993-1-1 (Table 6.2 picks one by section, axis, steel and how it was
/// made): its imperfection factor α (Table 6.1), the reduction χ it gives a member in compression
/// (§6.3.1.2), and the bow e₀ that stands for the member's crookedness and residual stresses in an
/// analysis (Table 5.1).
public enum BucklingCurve: String, Codable, Sendable, CaseIterable, Hashable {
    case a0, a, b, c, d

    public var alpha: Float {
        switch self {
        case .a0: 0.13
        case .a: 0.21
        case .b: 0.34
        case .c: 0.49
        case .d: 0.76
        }
    }

    /// L / e₀ from Table 5.1: for an elastic analysis checked on the section's strength, and the
    /// larger bow for a plastic analysis, as the beams' fibres are.
    public func bowDivisor(plastic: Bool = true) -> Float {
        switch self {
        case .a0: plastic ? 300 : 350
        case .a: plastic ? 250 : 300
        case .b: plastic ? 200 : 250
        case .c: plastic ? 150 : 200
        case .d: plastic ? 100 : 150
        }
    }

    /// χ = 1 / (Φ + √(Φ² − λ̄²)), Φ = ½ [1 + α (λ̄ − 0.2) + λ̄²], at most 1.
    public func reduction(slenderness: Float) -> Float {
        let phi = 0.5 * (1 + alpha * (slenderness - 0.2) + slenderness * slenderness)
        return min(1, 1 / (phi + max(phi * phi - slenderness * slenderness, 0).squareRoot()))
    }
}

/// The bows steel beams start with (`StructureModel.memberImperfections`). Each steel member's
/// line of beams is cut at its joints: every node another member, a shell or a tie shares, and its
/// ends. Each length between joints, of at least four beams, is given a half sine across its
/// weaker side (either, for a square) of the amplitude EN 1993-1-1 §5.3.2(11) takes for a member's
/// imperfection in its buckling mode, e₀ = α (λ̄ − 0.2) W_pl / A (γ_M1 = 1), λ̄ = √(N_pl / N_cr)
/// for the length pinned at its joints and W_pl / A a quarter of the weaker side: so its
/// resistance follows its curve (`BucklingTests`, 0.97–1.02 of χ over λ̄ 0.2–2 on curves a, b
/// and c, where Table 5.1's bows, sized for I-sections, gave 0.82–0.98). Members of a material
/// without a real yield (an elastic stand-in, above 2 GPa) stay straight. Its nodes turned to the sine's slope (the joints left as they
/// are). The beams' kernel adds each end's offset and turn to its node's own motion, so taking the
/// motion from the straight line, and takes the strain the bow alone would carry away from each
/// fibre's: a bowed member starts without stress, its axial force acting through the bow bends it
/// as the crooked member's does, and the bow turns with it. The nodes stay on the straight line
/// for the air, contact and drawing, a few millimetres from where the bow would put them.
enum MemberImperfection {
    /// Nine float4s a beam (`beamElements` in `Shell.metal`): each end's offset from the straight
    /// line and its turn (a quaternion), then the bow's own stretch, the two sides' bending and the
    /// two middle directors' offsets, the first's w 1 for a bowed beam. Nil if no beam is bowed.
    static let perBeam = 9

    /// A study's own L / e₀ for every bowed member, in place of its curve's (`BucklingStudy`).
    @TaskLocal static var divisorOverride: Float?

    static func bows(
        mesh: ShellMesh, model: StructureModel, materials: [StructureMaterial], divisor: Float? = nil
    ) -> [SIMD4<Float>]? {
        guard model.memberImperfections, !mesh.beams.isEmpty else { return nil }
        // Who uses each node: beams of each solid, and anything else.
        var solidsOfNode = [Set<Int>](repeating: [], count: mesh.positions.count)
        var sharedElsewhere = [Bool](repeating: false, count: mesh.positions.count)
        for element in mesh.elements {
            for corner in 0..<4 { sharedElsewhere[Int(element.nodes[corner])] = true }
        }
        for tie in mesh.ties {
            sharedElsewhere[Int(tie.slave)] = true
            sharedElsewhere[Int(tie.master)] = true
        }
        var beamsOfSolid: [Int: [Int]] = [:]
        for (b, beam) in mesh.beams.enumerated() {
            beamsOfSolid[beam.solid, default: []].append(b)
            for end in 0..<2 { solidsOfNode[Int(beam.nodes[end])].insert(beam.solid) }
        }
        var offsets = [SIMD4<Float>](repeating: .zero, count: perBeam * mesh.beams.count)
        var any = false
        for (solid, beams) in beamsOfSolid {
            let first = mesh.beams[beams[0]]
            guard materials.indices.contains(first.material), materials[first.material].model == .vonMises,
                materials[first.material].steel == nil
            else { continue }
            let k = first.axis
            let curve = solid < model.solids.count ? model.bucklingCurve(of: solid) : model.bucklingCurve
            let ratio = divisor ?? divisorOverride
            let steel = materials[first.material]
            guard steel.yieldStress < 2e9 else { continue }
            // The line's nodes in order along it, and its joints.
            let nodes = Set(beams.flatMap { [Int(mesh.beams[$0].nodes.x), Int(mesh.beams[$0].nodes.y)] })
                .sorted { mesh.positions[$0][k] < mesh.positions[$1][k] }
            guard let low = nodes.first, let high = nodes.last else { continue }
            let joints = nodes.filter {
                $0 == low || $0 == high || sharedElsewhere[$0] || solidsOfNode[$0].count > 1
            }
            // The weaker side: the beam bends that way most easily.
            let section = first.section
            let i2 = (k + 1) % 3
            let i3 = (k + 2) % 3
            // A square section's two planes are alike: the first. (Bowed along the diagonal, its
            // corner would carry √2 times the bending stress of a bow in either plane.)
            var direction = SIMD3<Float>.zero
            if section.x <= section.y {
                direction[i2] = 1
            } else {
                direction[i3] = 1
            }
            var along = SIMD3<Float>.zero
            along[k] = 1
            // The bow's offset and the turn of the line at each coordinate along it.
            var shape: [(start: Float, length: Float)] = []
            for (a, b) in zip(joints, joints.dropFirst()) {
                let between = nodes.filter {
                    mesh.positions[$0][k] > mesh.positions[a][k]
                        && mesh.positions[$0][k] < mesh.positions[b][k]
                }
                guard between.count >= 3 else { continue }
                shape.append((mesh.positions[a][k], mesh.positions[b][k] - mesh.positions[a][k]))
            }
            guard !shape.isEmpty else { continue }
            let jointSet = Set(joints)
            func bow(at x: Float) -> (offset: SIMD3<Float>, turn: SIMD3<Float>)? {
                guard
                    let segment = shape.first(where: {
                        x >= $0.start - 1e-5 && x <= $0.start + $0.length + 1e-5
                    })
                else { return nil }
                let e0: Float
                if let ratio {
                    e0 = segment.length / ratio
                } else {
                    // λ̄ = √(N_pl / N_cr) of the length as a pinned strut, across the weaker side.
                    let thin = min(section.x, section.y)
                    let area = section.x * section.y
                    let inertia = area * thin * thin / 12
                    let critical =
                        Float.pi * Float.pi * steel.youngsModulus * inertia
                        / (segment.length * segment.length)
                    let slenderness = (steel.yieldStress * area / critical).squareRoot()
                    e0 = curve.alpha * max(slenderness - 0.2, 0) * thin / 4
                }
                let phase = Float.pi * (x - segment.start) / segment.length
                let slope = e0 * Float.pi / segment.length * cos(phase)
                return (e0 * sin(phase) * direction, slope * cross(along, direction))
            }
            for b in beams {
                let beam = mesh.beams[b]
                let ends = [Int(beam.nodes.x), Int(beam.nodes.y)]
                // Both ends in one bowed length: the beam lies within it.
                let xs = ends.map { mesh.positions[$0][k] }
                guard let start = bow(at: xs[0]), let end = bow(at: xs[1]),
                    shape.contains(where: {
                        min(xs[0], xs[1]) >= $0.start - 1e-5
                            && max(xs[0], xs[1]) <= $0.start + $0.length + 1e-5
                    })
                else { continue }
                // Joints stay where they are, unturned: other members share them.
                let states = [start, end].enumerated().map { c, state in
                    jointSet.contains(ends[c]) ? (offset: SIMD3<Float>.zero, turn: SIMD3<Float>.zero) : state
                }
                var e2 = SIMD3<Float>.zero
                var e3 = SIMD3<Float>.zero
                e2[i2] = 1
                e3[i3] = 1
                func turned(_ v: SIMD3<Float>, by angle: SIMD3<Float>) -> SIMD3<Float> {
                    let size = simd_length(angle)
                    guard size > 0 else { return .zero }
                    return simd_quatf(angle: size, axis: angle / size).act(v) - v
                }
                let offset2 = states.map { turned(e2, by: $0.turn) }
                let offset3 = states.map { turned(e3, by: $0.turn) }
                func quaternion(_ angle: SIMD3<Float>) -> SIMD4<Float> {
                    let size = simd_length(angle)
                    guard size > 0 else { return SIMD4(0, 0, 0, 1) }
                    let q = simd_quatf(angle: size, axis: angle / size)
                    return SIMD4(q.imag, q.real)
                }
                let span = beam.length
                let o = perBeam * b
                offsets[o] = SIMD4(states[0].offset, 1)
                offsets[o + 1] = SIMD4(states[1].offset, 0)
                offsets[o + 2] = quaternion(states[0].turn)
                offsets[o + 3] = quaternion(states[1].turn)
                offsets[o + 4] = SIMD4((states[1].offset - states[0].offset) / span, 0)
                offsets[o + 5] = SIMD4(0.5 * section.x * (offset2[1] - offset2[0]) / span, 0)
                offsets[o + 6] = SIMD4(0.5 * section.y * (offset3[1] - offset3[0]) / span, 0)
                offsets[o + 7] = SIMD4(0.5 * (offset2[0] + offset2[1]), 0)
                offsets[o + 8] = SIMD4(0.5 * (offset3[0] + offset3[1]), 0)
                any = true
            }
        }
        return any ? offsets : nil
    }
}
