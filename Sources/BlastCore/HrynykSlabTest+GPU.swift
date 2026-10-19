import BlastModel
import Foundation
import Metal
import simd

extension HrynykSlabTest {
    /// Strikes `slab` once for each of `masses` at the centre, on one model carried from impact to
    /// impact. `values` perturbs the inputs for an ensemble (keys as `ValidationEnsemble`'s, and
    /// "speed", "bearing" and "rupture" as factors). `progress` hears of each impact as it ends.
    public static func run(
        device: MTLDevice, slab: Slab, inputs: Inputs, settings: Settings = Settings(),
        masses: [Float]? = nil,
        values: [String: Double] = [:], progress: (Impact) -> Void = { _ in },
        adjust: (inout StructureModel) -> Void = { _ in },
        prepare: (StructureSolver, Layout) -> Void = { _, _ in },
        inspect: (StructureSolver, Layout, Int, Double) -> Void = { _, _, _, _ in }
    ) throws -> Result {
        var settings = settings
        if let factor = values["bearing"] { settings.bearingSide *= Float(factor) }
        if let factor = values["rupture"] { settings.ruptureFactor *= Float(factor) }
        let material = ValidationEnsemble.perturbed(
            self.material(slab, inputs: inputs, settings: settings), values)
        let speed = inputs.impactSpeed * Float(values["speed"] ?? 1)
        var (model, l) = self.model(slab, inputs: inputs, settings: settings, material: material)
        adjust(&model)
        let solver = try StructureSolver(device: device, model: model)
        solver.groundContact = false
        prepare(solver, l)
        let h = l.h
        let g = solver.gravity
        let face = (l.centre - l.faceHalf)...(l.centre + l.faceHalf)
        // The bearing plates' seats: beneath, resting on the pin (pushing up only) and held
        // sideways as each corner's pin or roller holds it; above, held down by the ball.
        let near = l.supports[0]
        let far = l.supports[1]
        let corners: [(i: Int, j: Int, x: Bool, y: Bool)] = [
            (near, near, false, true),  // south: free along the south-east edge (x)
            (far, near, true, true),  // east: pinned
            (far, far, true, false),  // north: free along the north-east edge (y)
            (near, far, false, false),  // west: free
        ]
        var seatsBelow: [(Int, Int)] = []
        var seatsAbove: [(Int, Int)] = []
        solver.mutateNodes { nodes in
            for corner in corners {
                for i in (corner.i - l.seatHalf)...(corner.i + l.seatHalf) {
                    for j in (corner.j - l.seatHalf)...(corner.j + l.seatHalf) {
                        if let n = solver.storedNode(i, j, 0) {
                            nodes[n].restsOnSupport = true
                            nodes[n].restrain(x: corner.x, y: corner.y)
                            seatsBelow.append((i, j))
                        }
                        if let n = solver.storedNode(i, j, l.bearingTop) {
                            nodes[n].isHeldDown = true
                            seatsAbove.append((i, j))
                        }
                    }
                }
            }
        }
        var faceNodes: [Int] = []
        var weightNodes: [Int] = []
        for i in face {
            for j in face {
                for k in l.slabTop...l.faceTop {
                    if let n = solver.storedNode(i, j, k) {
                        faceNodes.append(n)
                        if k == l.faceTop { weightNodes.append(n) }
                    }
                }
            }
        }
        let faceMass = Float((2 * l.faceHalf) * (2 * l.faceHalf) * (l.faceTop - l.slabTop)) * h * h * h * 7850

        func reactions() -> (below: Float, above: Float) {
            var below: Float = 0
            var above: Float = 0
            for (i, j) in seatsBelow where solver.displacement(i, j, 0).z == 0 {
                below -= solver.nodalForce(i, j, 0).z
            }
            for (i, j) in seatsAbove where solver.displacement(i, j, l.bearingTop).z == 0 {
                above -= solver.nodalForce(i, j, l.bearingTop).z
            }
            return (below, above)
        }
        // The midpoint of the bottom face: the lowest node at the centre still held by an element.
        func attached(_ i: Int, _ j: Int, _ k: Int) -> Bool {
            for a in (i - 1)...i {
                for b in (j - 1)...j {
                    for c in (k - 1)...k where c >= l.slabBottom && c < l.slabTop {
                        let flag = solver.flag(a, b, c)
                        if flag == .active || flag == .bare { return true }
                    }
                }
            }
            return false
        }
        func midpoint() -> Float {
            let k = (l.slabBottom...l.slabTop).first { attached(l.centre, l.centre, $0) } ?? l.slabTop
            return -solver.displacement(l.centre, l.centre, k).z
        }
        func settle() {
            solver.damping = settings.settleDamping
            let stop = solver.time + settings.settleTime
            while solver.time < stop { solver.advance(steps: 100) }
            solver.damping = 0
            solver.mutateNodes { nodes in
                for n in nodes.indices { nodes[n].velocity = .zero }
            }
        }
        // The slab's top at column (i, j): the highest node there still held by a concrete element.
        func surface(_ i: Int, _ j: Int) -> Float? {
            guard
                let k = stride(from: l.slabTop, through: l.slabBottom, by: -1).first(where: {
                    attached(i, j, $0)
                })
            else { return nil }
            return solver.referencePosition(i, j, k).z + solver.displacement(i, j, k).z
        }
        // The step down at the face's edge: the slab's top along the face's perimeter against its
        // top two elements out (while the face is bonded on, its perimeter nodes).
        func faceStep() -> Float {
            var inside: [Float] = []
            var outside: [Float] = []
            let a = l.faceHalf
            for i in (l.centre - a - 2)...(l.centre + a + 2) {
                for j in (l.centre - a - 2)...(l.centre + a + 2) {
                    let ring = max(abs(i - l.centre), abs(j - l.centre))
                    if ring == a, let z = surface(i, j) { inside.append(z) }
                    if ring == a + 2, let z = surface(i, j) { outside.append(z) }
                }
            }
            guard !inside.isEmpty, !outside.isEmpty else { return 0 }
            return outside.reduce(0, +) / Float(outside.count) - inside.reduce(0, +) / Float(inside.count)
        }
        // Where the concrete the face was bonded to has all gone, the face is a loose piece, which
        // contact (on once any element has failed) lets strike the slab: it is set back, undeformed
        // and at rest, on the highest point of the slab's top under it at the centre, one element
        // above it, where contact begins.
        func reseatFace() -> Bool {
            let bonded = face.contains { i in face.contains { j in attached(i, j, l.slabTop) } }
            if bonded { return false }
            let heights = face.flatMap { i in face.compactMap { j in surface(i, j) } }
            guard let top = heights.max() else { return false }
            let lift = top + h - solver.referencePosition(l.centre, l.centre, l.slabTop).z
            solver.mutateNodes { nodes in
                for n in faceNodes {
                    nodes[n].displacement = SIMD3(0, 0, lift)
                    nodes[n].velocity = .zero
                }
            }
            return true
        }
        func damage() -> (area: Float, layers: Int, removed: Int, bare: Int) {
            let reach = Int((0.45 / h).rounded())
            var area: Float = 0
            var layers = 0
            var removed = 0
            var bare = 0
            for i in 0..<solver.ex {
                for j in 0..<solver.ey {
                    for k in l.slabBottom..<l.slabTop {
                        let flag = solver.flag(i, j, k)
                        if flag == .eroded { removed += 1 }
                        if flag == .bare { bare += 1 }
                    }
                }
            }
            for k in l.slabBottom..<l.slabTop {
                var crossed = false
                for i in (l.centre - reach)..<(l.centre + reach) {
                    for j in (l.centre - reach)..<(l.centre + reach) {
                        let flag = solver.flag(i, j, k)
                        let gone = flag == .eroded || flag == .bare
                        if k == l.slabBottom && gone { area += h * h }
                        if gone || solver.crackOpening(i, j, k) >= 0.001 { crossed = true }
                    }
                }
                if crossed { layers += 1 }
            }
            return (area, layers, removed, bare)
        }

        settle()
        let selfWeightSag = midpoint()
        let stepsPerSample = max(
            1, Int((settings.sampleInterval / Double(solver.criticalTimeStep)).rounded()))
        let sample = Double(stepsPerSample) * Double(solver.criticalTimeStep)
        var impacts: [Impact] = []
        for (number, mass) in (masses ?? Array(inputs.masses.prefix(4))).enumerated() {
            let wallStart = ContinuousClock.now
            let reseated = reseatFace()
            let start = midpoint()
            let startStep = faceStep()
            let startReaction = reactions().below
            // The weight: its face's nodes all start down at the impact speed, the rest of its mass
            // shared among the face's top nodes.
            let added = max(mass - faceMass, 0) / Float(weightNodes.count)
            solver.mutateNodes { nodes in
                for n in faceNodes { nodes[n].velocity = SIMD3(0, 0, -speed) }
                for n in weightNodes { nodes[n].mass += added }
            }
            var attachedWeight = true
            var weightLeft: Float?
            let t0 = solver.time
            var displacement: [SIMD2<Float>] = []
            var below: [Float] = []
            var above: [Float] = []
            var speeds: [Double] = [Double(speed)]
            while solver.time - t0 < settings.duration - 1e-9 {
                solver.advance(steps: stepsPerSample)
                let t = Float(solver.time - t0)
                inspect(solver, l, number + 1, solver.time - t0)
                displacement.append(SIMD2(t, midpoint() - start))
                let r = reactions()
                below.append(r.below - startReaction)
                above.append(r.above)
                if attachedWeight {
                    var rising = false
                    solver.mutateNodes { nodes in
                        let momentum = weightNodes.reduce(Float(0)) {
                            $0 + nodes[$1].mass * nodes[$1].velocity.z
                        }
                        let total = weightNodes.reduce(Float(0)) { $0 + nodes[$1].mass }
                        let v = momentum / total
                        speeds.append(Double(-v))
                        if v > 0 {
                            for n in weightNodes { nodes[n].mass -= added }
                            rising = true
                        }
                    }
                    if rising {
                        attachedWeight = false
                        weightLeft = t
                    }
                }
            }
            if attachedWeight {
                solver.mutateNodes { nodes in
                    for n in weightNodes { nodes[n].mass -= added }
                }
            }
            let records = displacement.count
            let tail = displacement.filter { Double($0.x) >= settings.duration - 0.03 }
            let residualTail = tail.map(\.y).reduce(0, +) / Float(max(tail.count, 1))
            // The impact force: the weight's mass times its deceleration (contact force over the
            // weight: its deceleration less gravity's pull), nil once it has left.
            var force = [Double](repeating: 0, count: records)
            for i in 1..<speeds.count where i - 1 < records {
                force[i - 1] = Double(mass) * ((speeds[i - 1] - speeds[i]) / sample + Double(g))
            }
            let pad = Int((0.02 / sample).rounded())
            let padded = [Double](repeating: 0, count: pad) + force + [Double](repeating: 0, count: pad)
            let filtered = Array(
                butterworthForwardBackward(padded, rate: 1 / sample, cutoff: 1200)[pad..<(pad + records)])
            settle()
            let residual = midpoint() - start
            let step = faceStep()
            let d = damage()
            let peakIndex = displacement.indices.max { displacement[$0].y < displacement[$1].y } ?? 0
            let reactionIndex = below.indices.max { below[$0] < below[$1] } ?? 0
            let forceIndex = filtered.indices.max { filtered[$0] < filtered[$1] } ?? 0
            let window = max(1, Int((0.0005 / sample).rounded()))
            var averaged: Float = 0
            if below.count >= window {
                var sum = below[0..<window].reduce(0, +)
                averaged = sum / Float(window)
                for end in window..<below.count {
                    sum += below[end] - below[end - window]
                    averaged = max(averaged, sum / Float(window))
                }
            }
            let tenth = max(1, Int((0.0001 / sample).rounded()))
            let early = min(records, Int((0.05 / sample).rounded()))
            let elapsed = ContinuousClock.now - wallStart
            let impact = Impact(
                number: number + 1, mass: mass, peakDisplacement: displacement[peakIndex].y,
                peakTime: displacement[peakIndex].x, residualDisplacement: residual,
                residualTail: residualTail,
                peakReaction: below[reactionIndex], peakReactionAveraged: averaged,
                reactionTime: Float(Double(reactionIndex + 1) * sample),
                peakImpactForce: Float(filtered[forceIndex]),
                impactForceTime: Float((Double(forceIndex) + 0.5) * sample),
                peakImpactForceRaw: Float(force.max() ?? 0), weightLeft: weightLeft, faceReseated: reseated,
                penetration: step - startStep, totalPenetration: step,
                bottomAreaGone: d.area, layersCrossed: d.layers, thicknessLayers: l.thicknessElements,
                punched: d.area >= 0.09 && d.layers == l.thicknessElements, elementsRemoved: d.removed,
                elementsBare: d.bare, blownUp: solver.summary().hasBlownUp,
                displacementHistory: stride(from: tenth - 1, to: records, by: tenth).map { displacement[$0] },
                forceHistory: (0..<early).map {
                    [
                        Float(Double($0 + 1) * sample), below[$0], above[$0], Float(filtered[$0]),
                        Float(force[$0]),
                    ]
                },
                wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds)
                    * 1e-18)
            impacts.append(impact)
            progress(impact)
            if impact.blownUp { break }
        }
        return Result(
            slab: slab.name, settings: settings, elementSize: h, elementCount: solver.elementCount,
            timeStep: solver.criticalTimeStep, impacts: impacts, selfWeightSag: selfWeightSag)
    }
}
