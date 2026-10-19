import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// The shell solver's pure helpers: the rules of quadrature through a shell's thickness and the
/// factors of the simplified modified compression field theory worked out for each section when
/// the mesh is made. Both are plain functions, checked exactly on the CPU.
@Suite("Shell solver helpers")
struct ShellSolverHelperTests {
    /// The integral of x^k over [-1, 1].
    private static func monomialIntegral(_ k: Int) -> Double {
        k % 2 == 1 ? 0 : 2 / Double(k + 1)
    }

    /// The sum of a rule's weights times x^k at its points.
    private static func integrate(_ rule: [SIMD2<Float>], power k: Int) -> Double {
        rule.reduce(0) { $0 + Double($1.y) * pow(Double($1.x), Double(k)) }
    }

    /// 30 MPa concrete with 500 MPa bars and the default 16 mm aggregate.
    private static let concrete30 = StructureMaterial.concrete(
        name: "Test", compressiveStrength: 30e6, steel: .grade500)

    @Test(
        "Gauss-Legendre rules match the tabulated points and integrate polynomials of degree 2n - 1 exactly")
    func gaussLegendre() {
        // The tabulated one- to three-point rules.
        let one = ShellSolver.gaussLegendre(1)
        #expect(one.count == 1 && abs(one[0].x) < 1e-6 && abs(one[0].y - 2) < 1e-6)
        let two = ShellSolver.gaussLegendre(2)
        let third = Float(1 / 3.0.squareRoot())
        #expect(two.count == 2 && abs(two[0].x + third) < 1e-6 && abs(two[1].x - third) < 1e-6)
        #expect(two.allSatisfy { abs($0.y - 1) < 1e-6 })
        let three = ShellSolver.gaussLegendre(3)
        let outer = Float(0.6.squareRoot())
        #expect(three.count == 3)
        #expect(abs(three[0].x + outer) < 1e-6 && abs(three[1].x) < 1e-6 && abs(three[2].x - outer) < 1e-6)
        #expect(abs(three[0].y - 5.0 / 9) < 1e-6 && abs(three[1].y - 8.0 / 9) < 1e-6)
        // Every rule up to eight points: sorted, symmetric, inside the interval, and exact to
        // degree 2n - 1; 1e-5 allows for the points' Float rounding (it held on the Studio,
        // 19 October 2026).
        for n in 1...8 {
            let rule = ShellSolver.gaussLegendre(n)
            #expect(rule.count == n)
            #expect(zip(rule, rule.dropFirst()).allSatisfy { $0.x < $1.x }, "\(n) points unsorted")
            #expect(rule.allSatisfy { abs($0.x) < 1 && $0.y > 0 }, "\(n) points")
            for (a, b) in zip(rule, rule.reversed()) {
                #expect(abs(a.x + b.x) < 1e-6 && abs(a.y - b.y) < 1e-6, "\(n) points asymmetric")
            }
            for k in 0...(2 * n - 1) {
                let error = abs(Self.integrate(rule, power: k) - Self.monomialIntegral(k))
                #expect(error < 1e-5, "\(n) points, x^\(k): off by \(error)")
            }
        }
    }

    @Test("Gauss-Lobatto rules include both faces and integrate polynomials of degree 2n - 3 exactly")
    func gaussLobatto() {
        for n in 3...5 {
            let rule = ShellSolver.gaussLobatto(n)
            #expect(rule.count == n)
            #expect(rule.first?.x == -1 && rule.last?.x == 1, "\(n) points miss a face")
            #expect(zip(rule, rule.dropFirst()).allSatisfy { $0.x < $1.x })
            for k in 0...(2 * n - 3) {
                let error = abs(Self.integrate(rule, power: k) - Self.monomialIntegral(k))
                #expect(error < 1e-6, "\(n) points, x^\(k): off by \(error)")
            }
            // One degree higher is not exact: the rule is the one asked for, not a finer one.
            let beyond = 2 * n - 2
            #expect(abs(Self.integrate(rule, power: beyond) - Self.monomialIntegral(beyond)) > 1e-3)
        }
    }

    @Test(
        "The rule through the thickness: Legendre without timber, Lobatto of three to five points within each lamella"
    )
    func thicknessRule() {
        // Without timber, the plain Gauss-Legendre rule of `layers` points.
        let concrete = ShellSolver.thicknessRule(layers: 5, materials: [Self.concrete30])
        #expect(concrete == ShellSolver.gaussLegendre(5))

        // Solid timber (one lamella): Lobatto over the whole thickness, its point count held to
        // three to five whatever `layers` asks for, and its face points nudged just inside.
        let solid = StructureMaterial.timber(.c24)
        for (layers, expected) in [(1, 3), (2, 3), (4, 4), (5, 5), (9, 5)] {
            let rule = ShellSolver.thicknessRule(layers: layers, materials: [solid])
            #expect(rule.count == expected, "\(layers) layers gave \(rule.count) points")
            #expect(abs(rule.reduce(0) { $0 + $1.y } - 2) < 1e-5)
            #expect(rule.allSatisfy { abs($0.x) < 1 }, "a point on a face")
        }

        // Timber beside concrete still takes timber's rule, for both.
        let mixed = ShellSolver.thicknessRule(layers: 4, materials: [Self.concrete30, solid])
        #expect(mixed.count == 4)

        // Two CLT materials with the same lamellae share their boundaries: three points in each
        // of three lamellae, not six boundaries' worth. No point lies on a lamella's top, so that
        // the kernel can tell which lamella each belongs to.
        let clt = StructureMaterial.timber(.c24, lamellae: 3)
        let other = StructureMaterial.timber(.c16, lamellae: 3)
        let rule = ShellSolver.thicknessRule(layers: 5, materials: [clt, other])
        #expect(rule.count == 9)
        #expect(abs(rule.reduce(0) { $0 + $1.y } - 2) < 1e-5)
        let tops: [Float] = [-1, -1.0 / 3, 1.0 / 3, 1]
        #expect(rule.allSatisfy { point in tops.allSatisfy { abs(point.x - $0) > 1e-7 } })
        // Each lamella's weights sum to its share of the thickness, 2/3.
        for (low, high) in zip(tops, tops.dropFirst()) {
            let share = rule.filter { $0.x > low && $0.x < high }.reduce(0) { $0 + $1.y }
            #expect(abs(share - (high - low)) < 1e-5, "lamella \(low) to \(high): \(share)")
        }
    }

    @Test("Section factors follow the simplified modified compression field theory's d_v and size factor")
    func sectionFactors() {
        let concrete = Self.concrete30
        // 200 mm deep, bars at 0.6 (40 mm in from the face): d = 160 mm, d_v = max(144, 144) mm,
        // so 0.72 of the depth; s_ze = max(35 x 144 / (15 + 16), 0.85 x 144) = 162.6 mm, so the
        // size factor is 1300 / 1162.6 = 1.118.
        let base = MemberShearBuffers.sectionFactors(
            depth: 0.2, bars: 0.6, material: concrete, stirrups: 0)
        #expect(abs(base.x - 0.72) < 1e-5)
        #expect(abs(base.y - 1300 / (1000 + 35 * 144 / 31.0)) < 1e-4, "size factor \(base.y)")
        // No bars: taken at 0.6, the same.
        let none = MemberShearBuffers.sectionFactors(
            depth: 0.2, bars: nil, material: concrete, stirrups: 0)
        #expect(none == base)
        // Bars at the face: d = h, d_v = 0.9 h. Bars at mid-depth: d_v is held to 0.72 h.
        let atFace = MemberShearBuffers.sectionFactors(
            depth: 0.2, bars: 1, material: concrete, stirrups: 0)
        #expect(abs(atFace.x - 0.9) < 1e-5)
        let middle = MemberShearBuffers.sectionFactors(
            depth: 0.2, bars: 0, material: concrete, stirrups: 0)
        #expect(abs(middle.x - 0.72) < 1e-5)
        // d_v over the depth does not depend on the depth; the size factor falls as it grows.
        let deep = MemberShearBuffers.sectionFactors(
            depth: 0.8, bars: 0.6, material: concrete, stirrups: 0)
        #expect(abs(deep.x - base.x) < 1e-5 && deep.y < base.y)

        // The minimum of stirrups is 0.06 sqrt(30) / 500 = 0.066%: above it there is no size
        // effect, below it there is.
        let enough = MemberShearBuffers.sectionFactors(
            depth: 0.2, bars: 0.6, material: concrete, stirrups: 0.001)
        #expect(enough.y == 1)
        let short = MemberShearBuffers.sectionFactors(
            depth: 0.2, bars: 0.6, material: concrete, stirrups: 0.0005)
        #expect(short.y == base.y)
        // Without steel, stirrups count for nothing.
        let plain = StructureMaterial.concrete(name: "Plain", compressiveStrength: 30e6)
        let unreinforced = MemberShearBuffers.sectionFactors(
            depth: 0.2, bars: 0.6, material: plain, stirrups: 0.01)
        #expect(unreinforced.y == base.y)

        // Above 70 MPa the aggregate is taken as none: s_ze = 35 x 144 / 15 = 336 mm.
        let strong = StructureMaterial.concrete(name: "Strong", compressiveStrength: 80e6, steel: .grade500)
        let high = MemberShearBuffers.sectionFactors(
            depth: 0.2, bars: 0.6, material: strong, stirrups: 0)
        #expect(abs(high.y - 1300 / 1336.0) < 1e-4, "size factor \(high.y)")
        // Coarse aggregate brings s_ze down to its floor of 0.85 d_v = 122.4 mm.
        var coarse = concrete
        coarse.aggregateSize = 0.05
        let floored = MemberShearBuffers.sectionFactors(
            depth: 0.2, bars: 0.6, material: coarse, stirrups: 0)
        #expect(abs(floored.y - 1300 / 1122.4) < 1e-4, "size factor \(floored.y)")
    }
}

/// Paths of the shell solver no other test reaches: the one-way shear check of shells' sections,
/// how the sections' factors are laid out for the GPU, the check for runaway nodes and the shape
/// settled under self-weight, and removing beams by hand.
@Suite("Shell solver coverage", .gpuThreads)
struct ShellSolverGapTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// A 2.4 m square slab, 200 mm thick, on a 300 mm column stub at its middle, with mats in
    /// both faces: the geometry of `PunchingTests`, which has elements both within and beyond
    /// the column's punching zone and a concrete beam for the column.
    private static func slabOnColumn() -> StructureModel {
        let slab = Box(min: SIMD3(0, 0, 1), max: SIMD3(2.4, 2.4, 1.2))
        let column = Box(min: SIMD3(1.05, 1.05, 0.4), max: SIMD3(1.35, 1.35, 1.2))
        var model = StructureModel(
            solids: [slab, column],
            material: .concrete(name: "Test", compressiveStrength: 30e6, steel: .grade500), elementSize: 0.1,
            fixedBase: false)
        model.elementKind = .shell
        model.setReinforcement(.none, of: 0)
        model.setReinforcement(.none, of: 1)
        model.autoReinforce()
        model.addMat(
            to: slab, thicknessAxis: 2, areaPerMetre: 1.6e-3, depth: 0.04, faces: (low: false, high: true))
        model.addMat(
            to: slab, thicknessAxis: 2, areaPerMetre: 0.5e-3, depth: 0.04, faces: (low: true, high: false))
        return model
    }

    /// A 400 mm square elastic plate, 20 mm thick, and apart from it a 1 m elastic beam of
    /// 100 mm square section along x: 100 mm elements.
    private func plateAndBeam() throws -> ShellSolver {
        var model = StructureModel(
            solids: [
                Box(min: SIMD3(0, 0, 1), max: SIMD3(0.4, 0.4, 1.02)),
                Box(min: SIMD3(0, 1, 1), max: SIMD3(1, 1.1, 1.1)),
            ],
            material: .elastic(density: 2400, youngsModulus: 20e9, poissonRatio: 0.2), elementSize: 0.1,
            fixedBase: false)
        model.elementKind = .shell
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        return solver
    }

    /// A 1.2 m concrete strip, 300 mm wide and 120 mm thick, with bars in its bottom face,
    /// clamped at both ends and loaded on top by a pressure rising to `pressure` over 50 ms; run
    /// for `steps` substeps. `sectionShear` turns on the one-way shear check of shells.
    private func clampedStrip(sectionShear: Bool, pressure: Float, steps: Int) throws -> ShellSolver {
        let strip = Box(min: SIMD3(0, 0, 1), max: SIMD3(1.2, 0.3, 1.12))
        var model = StructureModel(
            solids: [strip], material: .concrete(name: "Test", compressiveStrength: 30e6, steel: .grade500),
            elementSize: 0.1, fixedBase: false)
        model.elementKind = .shell
        model.setReinforcement(.none, of: 0)
        model.autoReinforce()
        model.addMat(
            to: strip, thicknessAxis: 2, areaPerMetre: 0.5e-3, depth: 0.03, faces: (low: true, high: false))
        model.shellSectionShear = sectionShear
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        let ends = solver.nodes { $0.x < 1e-4 || $0.x > 1.2 - 1e-4 }
        solver.mutateNodes { nodes in for n in ends { nodes[n].isClamped = true } }
        solver.appliedLoad = PressureLoad(
            axis: 2, positiveSide: true, history: [SIMD2(0, 0), SIMD2(0.05, pressure)])
        solver.advance(steps: steps)
        return solver
    }

    /// `StructureModel.shellSectionShear` is off by default and no other test turns it on. Below
    /// a section's shear strength the check only watches: it must leave the response exactly as
    /// it is without it, and mark no section failed. 20 kPa on this strip is at most a shear of
    /// 12 kN/m, 0.1 MPa through its 120 mm, at its ends: a small share of a strength near 1.5 MPa.
    @Test("The one-way shear check of shells changes nothing while every section is below its strength")
    func sectionShearBelowStrength() throws {
        // That the averaged ratio stays below 1 everywhere, the clamped ends included, held on the
        // Studio (19 October 2026): bit for bit the same with the check on, and no section failed.
        let steps = 2000
        let off = try clampedStrip(sectionShear: false, pressure: 20e3, steps: steps)
        let on = try clampedStrip(sectionShear: true, pressure: 20e3, steps: steps)
        #expect(off.nodeCount == on.nodeCount && off.elementCount == on.elementCount)
        // The run must have loaded the strip, or the comparison says nothing.
        let middle = off.nearestNode(to: SIMD3(0.6, 0.15, 1.06))
        #expect(off.node(middle).displacement.z < 0, "the strip never bent")
        // Bit for bit: the GPU's results are deterministic run to run (as `LaminatedShellTests`
        // relies on), and the check adds nothing to the forces until a section fails.
        for n in 0..<off.nodeCount {
            #expect(off.node(n).displacement == on.node(n).displacement, "node \(n)")
        }
        #expect((0..<on.elementCount).allSatisfy { !on.hasShearFailed($0) && !on.isPunched($0) })
        #expect(on.summary().erodedElements == off.summary().erodedElements)
    }

    /// The factors `MemberShearBuffers` lays out for the GPU decide which members' sections are
    /// checked at all: none of a slab's within two effective depths of a column, where punching
    /// decides instead; no shells' unless `shellSectionShear` asks; no beams' under the
    /// impulsive regime's defaults (`checksBeams` false). Only the factors' even vectors are
    /// made here; the odd ones, the time-averaged shear, start at zero and are what `reset()`
    /// clears.
    @Test("Sections are checked for one-way shear outside the punching zone, and only as the options ask")
    func sectionLayout() throws {
        let model = Self.slabOnColumn()
        let mesh = try ShellMesh(model: model)
        let materials = model.materials
        let zone = mesh.punchingZone.filter { $0 }.count
        try #require(zone > 0 && zone < mesh.elements.count, "\(zone) of \(mesh.elements.count) in the zone")
        try #require(!mesh.beams.isEmpty, "the column was not meshed as a beam")

        func vectors(_ buffer: MTLBuffer) -> [SIMD4<Float>] {
            let pointer = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: buffer.length / 16)
            return Array(UnsafeBufferPointer(start: pointer, count: buffer.length / 16))
        }

        let checked = try MemberShearBuffers(
            device: device, mesh: mesh, materials: materials, shells: true, checksBeams: true)
        let sections = vectors(checked.section)
        for (e, inZone) in mesh.punchingZone.enumerated() {
            let factors = sections[2 * e]
            if inZone {
                #expect(factors == .zero, "element \(e) in the punching zone is checked")
            } else {
                // d_v over the depth lies between 0.72 and 0.9; the size factor is positive.
                #expect(factors.x >= 0.72 - 1e-5 && factors.x <= 0.9 + 1e-5, "element \(e): \(factors)")
                #expect(factors.z >= 0.72 - 1e-5 && factors.z <= 0.9 + 1e-5, "element \(e): \(factors)")
                #expect(factors.y > 0 && factors.w > 0)
            }
            #expect(sections[2 * e + 1] == .zero)
        }
        let beams = vectors(checked.beamSection)
        for b in mesh.beams.indices {
            #expect(beams[2 * b].x > 0 && beams[2 * b].z > 0, "beam \(b): \(beams[2 * b])")
        }

        // Shells left unchecked, and beams too.
        let unchecked = try MemberShearBuffers(
            device: device, mesh: mesh, materials: materials, shells: false, checksBeams: false)
        #expect(vectors(unchecked.section).allSatisfy { $0 == .zero })
        #expect(vectors(unchecked.beamSection).allSatisfy { $0 == .zero })

        // `reset()` clears the averaged shear and keeps the factors; `disableSectionShear()`
        // clears both.
        let pointer = checked.section.contents().bindMemory(
            to: SIMD4<Float>.self, capacity: checked.section.length / 16)
        let outside = try #require(mesh.punchingZone.firstIndex(of: false))
        pointer[2 * outside + 1] = SIMD4(0.5, 0.5, 0, 0)
        checked.reset()
        #expect(pointer[2 * outside + 1] == .zero)
        #expect(pointer[2 * outside] == sections[2 * outside])
        checked.disableSectionShear()
        #expect(vectors(checked.section).allSatisfy { $0 == .zero })
        #expect(vectors(checked.beamSection).allSatisfy { $0 == .zero })
    }

    /// `runaway(beyond:)` is what `blastbench --runaway` reports, and `recordSettledShape()` is
    /// what `BlastSolver.settleStructures()` calls on shells (`SettleTests` settles solid
    /// elements only). Nodes are moved by hand, with no step taken: what is counted is known
    /// exactly from the mesh.
    @Test("Runaway nodes are counted by element and beam, measured from the settled shape")
    func runawayAndSettledShape() throws {
        let solver = try plateAndBeam()
        let mesh = solver.mesh
        try #require(solver.elementCount > 0 && solver.beamCount > 0)
        let quiet = solver.runaway(beyond: 0.1)
        #expect(quiet.byMaterial.isEmpty && quiet.nonFinite == 0)

        // A plate corner and a beam end moved 0.5 m: the elements and beams on them are counted
        // under their materials' names; nothing is stretched past 2 m.
        let corner = solver.nearestNode(to: SIMD3(0, 0, 1.01))
        let end = solver.nearestNode(to: SIMD3(0, 1.05, 1.05))
        solver.mutateNodes { nodes in
            nodes[corner].displacement = SIMD3(0, 0, 0.5)
            nodes[end].displacement = SIMD3(0, 0, 0.5)
        }
        let elementsOnCorner = mesh.elements.filter { element in
            (0..<4).contains { Int(element.nodes[$0]) == corner }
        }.count
        let beamsOnEnd = mesh.beams.filter { Int($0.nodes.x) == end || Int($0.nodes.y) == end }.count
        let name = solver.materials[0].name
        let moved = solver.runaway(beyond: 0.1)
        #expect(moved.byMaterial[name] == elementsOnCorner && elementsOnCorner > 0, "\(moved.byMaterial)")
        #expect(moved.byMaterial["beam: " + name] == beamsOnEnd && beamsOnEnd > 0, "\(moved.byMaterial)")
        #expect(moved.byMaterial.keys.allSatisfy { !$0.hasPrefix("stretched") })
        #expect(moved.nonFinite == 0)
        // Within a limit beyond 0.5 m, nothing.
        #expect(solver.runaway(beyond: 0.6).byMaterial.isEmpty)

        // Settled there, the same shape is no longer runaway, deflection reads zero and the sag
        // is the 0.5 m moved.
        solver.recordSettledShape()
        #expect(solver.settledDisplacements?.count == solver.nodeCount)
        #expect(solver.runaway(beyond: 0.1).byMaterial.isEmpty)
        let settled = solver.summary()
        #expect(settled.maxDisplacement == 0)
        #expect(abs(settled.selfWeightSag - 0.5) < 1e-6)

        // A node spinning past 10^4 rad/s, or one not finite, is counted as not finite.
        let interior = solver.nearestNode(to: SIMD3(0.2, 0.2, 1.01))
        solver.mutateNodes { nodes in nodes[interior].spin = SIMD3(2e4, 0, 0) }
        #expect(solver.runaway(beyond: 0.1).nonFinite == 1)
        solver.mutateNodes { nodes in
            nodes[interior].spin = .zero
            nodes[interior].displacement = SIMD3(.nan, 0, 0)
        }
        #expect(solver.runaway(beyond: 0.1).nonFinite == 1)
        #expect(solver.summary().hasBlownUp)

        // A restart forgets the settled shape.
        solver.reset()
        #expect(solver.settledDisplacements == nil)
        #expect(solver.summary().selfWeightSag == 0)
        #expect(solver.runaway(beyond: 0.1).nonFinite == 0)
    }

    /// `erode(where:)` is tested on shells (`ShellCouplingTests`) but not on beams, which it
    /// picks by `beamCentre`; `reset()` must put both back, and clear the failure gate that
    /// turns contact on.
    @Test("Beams removed by hand are chosen by their midpoints, counted, and restored on reset")
    func erodeBeams() throws {
        let solver = try plateAndBeam()
        let beams = solver.beamCount
        try #require(beams > 0)
        // Midpoints along the beam's axis, evenly spaced along its 1 m (checked on the Studio,
        // 19 October 2026). The breakpoints along each axis are shared by the whole structure, and
        // a column's centreline within half an element of a plate's midsurface moves onto it
        // (`ShellMesh.init`): the beam's 1.05 m lies 40 mm from the plate's 1.01 m, so its nodes
        // are at z = 1.01 m though it is nowhere near the plate.
        let centres = (0..<beams).map(solver.beamCentre).sorted { $0.x < $1.x }
        for (i, centre) in centres.enumerated() {
            let expected = (Float(i) + 0.5) / Float(beams)
            #expect(abs(centre.x - expected) < 1e-4, "beam \(i) at \(centre)")
            #expect(abs(centre.y - 1.05) < 1e-4 && abs(centre.z - 1.01) < 1e-4, "beam \(i) at \(centre)")
        }
        #expect(!solver.hasFailed)

        // The half of the beam beyond x = 0.5 m.
        solver.erode { $0.y > 0.9 && $0.x > 0.5 }
        let removed = (0..<beams).filter { solver.beamFlag($0) == .eroded }
        #expect(removed.count == centres.filter { $0.x > 0.5 }.count && !removed.isEmpty)
        #expect(removed.allSatisfy { solver.beamCentre($0).x > 0.5 })
        #expect((0..<solver.elementCount).allSatisfy { solver.flag($0) == .active })
        #expect(solver.hasFailed)
        let summary = solver.summary()
        #expect(summary.erodedBeams == removed.count && summary.activeBeams == beams - removed.count)
        #expect(summary.erodedElements == removed.count)

        // Asking again removes nothing more.
        solver.erode { $0.y > 0.9 && $0.x > 0.5 }
        #expect(solver.summary().erodedBeams == removed.count)

        solver.reset()
        #expect((0..<beams).allSatisfy { solver.beamFlag($0) == .active })
        #expect(!solver.hasFailed)
        #expect(solver.summary().erodedBeams == 0 && solver.summary().activeBeams == beams)
    }
}
