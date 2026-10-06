import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Punching of flat slabs at their columns, and the bars that hold a slab once it has punched.
@Suite("Punching")
struct PunchingTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// A 2.4 m square slab, 200 mm thick, on a 300 mm column stub at its middle, with 1% of bars
    /// in its top face each way (16 mm at 125 mm, centred 40 mm down) and lighter bars below,
    /// loaded by a pressure rising slowly on its top. Returns the column's reaction and the
    /// number of elements removed, against time.
    private func pushDown(elementSize h: Float) throws -> [(time: Float, reaction: Float, failed: Int)] {
        let slab = Box(min: SIMD3(0, 0, 1), max: SIMD3(2.4, 2.4, 1.2))
        let column = Box(min: SIMD3(1.05, 1.05, 0.4), max: SIMD3(1.35, 1.35, 1.2))
        var model = StructureModel(
            solids: [slab, column],
            material: .concrete(
                name: "Test", compressiveStrength: 30e6, steel: .grade500), elementSize: h, fixedBase: false)
        model.elementKind = .shell
        model.setReinforcement(.none, of: 0)
        model.setReinforcement(.none, of: 1)
        model.autoReinforce()
        model.addMat(
            to: slab, thicknessAxis: 2, areaPerMetre: 1.6e-3, depth: 0.04, faces: (low: false, high: true))
        model.addMat(
            to: slab, thicknessAxis: 2, areaPerMetre: 0.5e-3, depth: 0.04, faces: (low: true, high: false))
        let solver = try ShellSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        solver.damping = 50
        let base = solver.nearestNode(to: SIMD3(1.2, 1.2, 0.4))
        solver.mutateNodes { nodes in nodes[base].isClamped = true }
        // 400 kPa over 0.4 s: slow against the slab's period of a few milliseconds.
        solver.appliedLoad = PressureLoad(
            axis: 2, positiveSide: true, history: [SIMD2(0, 0), SIMD2(0.4, 400e3)])
        var history: [(time: Float, reaction: Float, failed: Int)] = []
        let stepsPerSample = max(1, Int(0.002 / solver.criticalTimeStep))
        while solver.time < 0.3 {
            solver.advance(steps: stepsPerSample)
            history.append((Float(solver.time), -solver.nodalForce(base).z, solver.summary().erodedElements))
        }
        return history
    }

    @Test("A flat slab punches at its column at the Eurocode 2 strength, then hangs on its bars")
    func punchingStrength() throws {
        // Eurocode 2: d = 160 mm, k = 2, rho = 1%: v = 0.18 k (100 rho fc)^(1/3) = 1.12 MPa on
        // u1 = 4 c + 4 pi d = 3.21 m, so V = 0.575 MN. The slab's flexural strength around the
        // column is well above that.
        let d: Float = 0.16
        let v = 0.18 * 2 * pow(Float(100 * 0.01 * 30), 1 / 3) * 1e6
        let expected = v * (4 * 0.3 + 4 * Float.pi * d) * d
        for h in [0.1, 0.075] as [Float] {
            let history = try pushDown(elementSize: h)
            // The first peak: punching, before the bottom bars take up the load again.
            var highest: Float = 0
            var top: Int?
            for (n, sample) in history.enumerated() {
                if sample.reaction < 0.6 * highest {
                    top = n
                    break
                }
                highest = max(highest, sample.reaction)
            }
            guard let top else {
                Issue.record("\(h) m: the load never fell")
                continue
            }
            let peak = highest
            let failedAtPeak = history[top - 1].failed
            #expect(abs(peak - expected) / expected < 0.15, "\(h) m: \(peak) N against \(expected) N")
            #expect(failedAtPeak == 0, "\(h) m: \(failedAtPeak) elements failed before the peak")
            // Then the bottom bars hang the slab from the column until they kink to rupture, and
            // the ring of elements around the column is removed.
            #expect((history.last?.failed ?? 0) > 0, "\(h) m: the slab never came away")
        }
    }

    /// One shell element, 100 mm square and 50 mm thick, cracked through its thickness across x
    /// to an opening of `opening`, then slid through its thickness across the crack: the largest
    /// shear stress it carries. `bars` is the area per metre of the bars along x in each face.
    private func slide(opening: Float, bars: Float) throws -> Float {
        let size: Float = 0.1
        let plate = Box(min: SIMD3(0, 0, 1), max: SIMD3(size, size, 1.05))
        var model = StructureModel(
            solids: [plate], material: .concrete(name: "Test", compressiveStrength: 30e6, steel: .grade500),
            elementSize: size, fixedBase: false)
        model.elementKind = .shell
        model.setReinforcement(.none, of: 0)
        model.autoReinforce()
        if bars > 0 {
            model.addMat(
                to: plate, thicknessAxis: 2, areaPerMetre: bars, transverseAreaPerMetre: 0,
                longitudinalAxis: 0,
                depth: 0.0125)
        }
        let solver = try ShellSolver(device: device, model: model)
        // The layers' dowel action alone: a single element's section would fail first.
        solver.disableSectionShear()
        solver.gravity = 0
        solver.groundContact = false
        let fixed = solver.nodes { $0.x < 1e-4 }
        let moving = solver.nodes { $0.x > size - 1e-4 }
        let steps = 4000
        let duration = Float(steps) * solver.criticalTimeStep
        func drive(_ velocity: SIMD3<Float>) {
            solver.mutateNodes { nodes in
                for n in fixed { nodes[n].isClamped = true }
                for n in moving {
                    nodes[n].isPrescribed = true
                    nodes[n].velocity = velocity
                    nodes[n].spin = .zero
                }
            }
        }
        drive(SIMD3(opening / duration, 0, 0))
        solver.advance(steps: steps)
        drive(SIMD3(0, 0, 0.003 * size / duration))
        var peak: Float = 0
        for _ in 0..<(steps / 50) {
            solver.advance(steps: 50)
            let force = moving.reduce(Float(0)) { $0 + solver.nodalForce($1).z }
            peak = max(peak, -force / (size * 0.05))
        }
        return peak
    }

    @Test("Bars across a crack add Rasmussen's dowel strength to the shear a shell carries")
    func dowelAction() throws {
        // 250 mm2/m in each face of a 50 mm section is 1% of bars across the crack: dowel
        // action of 1.65 rho sqrt(fc fy) = 2.0 MPa on top of the interlock.
        let rho: Float = 2 * 250e-6 / 0.05
        let dowel = 1.65 * rho * (30e6 * SteelProperties.grade500.yieldStress).squareRoot()
        let plain = try slide(opening: 0.0003, bars: 0)
        let reinforced = try slide(opening: 0.0003, bars: 250e-6)
        let gain = reinforced - plain
        #expect(
            abs(gain - dowel) / dowel < 0.1, "gain \(gain) Pa (\(plain) to \(reinforced)) against \(dowel) Pa"
        )
    }
}

/// Members of shells and beams failing in shear across their section.
@Suite("Sectional shear")
struct SectionalShearTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// Vecchio and Shim's beam OA1 meshed with shells and beams of `size`, pushed down at
    /// mid-span: the peak load, scaled to the beam's 305 mm width, and the least load within
    /// 3 mm of deflection after it. `slab` meshes it as a strip 1 m wide with the same bars per
    /// metre, so that it is a plate in one-way shear rather than a beam.
    private func oa1(size: Float, slab: Bool) throws -> (peak: Float, after: Float) {
        var model: StructureModel
        var width: Float = ShearBeamBenchmark.width
        if slab {
            width = 1
            let strip = Box(min: SIMD3(0, 0, 1), max: SIMD3(4.1, 1, 1 + ShearBeamBenchmark.depth))
            model = StructureModel(
                solids: [strip], material: ShearBeamBenchmark.material, elementSize: size, fixedBase: false)
            for row in ShearBeamBenchmark.bars {
                var band = strip
                band.min.z = 1 + row.height - 0.01
                band.max.z = band.min.z + 0.02
                model.reinforcement.append(
                    ReinforcementLayer(
                        region: band, ratio: SIMD3(row.area / ShearBeamBenchmark.width / 0.02, 0, 0)))
            }
        } else {
            model = ShearBeamBenchmark.model(elementsThroughDepth: 12)
            model.elementSize = size
        }
        model.elementKind = .shell
        model.shellSectionShear = true
        let solver = try ShellSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        solver.damping = 100
        let base = solver.referencePositions[0]
        func line(_ x: Float) -> [Int] {
            let n = solver.nearestNode(to: SIMD3(x, base.y, base.z))
            let at = solver.referencePositions[n].x
            return solver.nodes { abs($0.x - at) < 1e-4 }
        }
        let left = line(0.22)
        let right = line(3.88)
        let middle = line(2.05)
        solver.mutateNodes { nodes in
            for n in left { nodes[n].restrain(x: true, y: true, z: true) }
            for n in right { nodes[n].restrain(y: true, z: true) }
            for n in middle {
                nodes[n].isPrescribed = true
                nodes[n].velocity = SIMD3(0, 0, -0.05)
            }
        }
        var history: [SIMD2<Float>] = []
        let steps = max(1, Int(0.0002 / solver.criticalTimeStep))
        while solver.time < 0.3 {
            solver.advance(steps: steps)
            let reaction = -(left + right).reduce(Float(0)) { $0 + solver.nodalForce($1).z }
            history.append(
                SIMD2(-solver.node(middle[0]).displacement.z, reaction * ShearBeamBenchmark.width / width))
        }
        // The reaction rings as a section lets go; average it over 2 ms (10 samples).
        let smooth = history.indices.map { n -> SIMD2<Float> in
            let window = history[max(0, n - 5)..<min(history.count, n + 5)]
            return SIMD2(history[n].x, window.map(\.y).reduce(0, +) / Float(window.count))
        }
        let top = smooth.max { $0.y < $1.y } ?? .zero
        let after = smooth.filter { $0.x > top.x && $0.x < top.x + 0.003 }.map(\.y).min() ?? top.y
        return (top.y, after)
    }

    @Test("A beam without stirrups, as beams or as a strip of shells, fails in shear near the measured load")
    func beamWithoutStirrups() throws {
        // Without the sectional check, beams carried the beam to its bending strength, 470 kN.
        let measured = ShearBeamBenchmark.measuredPeak
        for slab in [false, true] {
            let result = try oa1(size: 0.1, slab: slab)
            #expect(
                abs(result.peak - measured) / measured < 0.15,
                "\(slab ? "shells" : "beams"): \(result.peak) N")
            #expect(result.after < 0.3 * result.peak, "\(slab ? "shells" : "beams"): no sudden drop")
        }
    }
}
