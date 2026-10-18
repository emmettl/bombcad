import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Steel connections (`SteelConnection`): which beam ends get a hinge, and the column-removal
/// assemblies they were judged on (`ColumnRemovalTest`), so a change that moves those is seen.
@Suite("Steel connections", .gpuThreads)
struct SteelConnectionTests {
    /// A column 4 m high and a steel beam 3 m long stopping at its side at mid-height, its far end
    /// free.
    static func joint(_ connection: SteelConnection?) -> StructureModel {
        let section = SteelSection(
            name: "W18×35", depth: 0.45, width: 0.152, area: 6.65e-3, secondMoment: 2.12e-4,
            plasticModulus: 1.09e-3)
        let width = section.rectangleWidth
        var model = StructureModel(
            solids: [
                Box(min: SIMD3(-0.2, -width / 2, 0), max: SIMD3(0.2, width / 2, 4)),
                Box(min: SIMD3(0, -width / 2, 1.775), max: SIMD3(3, width / 2, 2.225)),
            ],
            material: section.equivalent(of: .structuralSteel, width: width), elementSize: 0.25,
            fixedBase: true)
        model.elementKind = .shell
        model.steelConnection = connection
        return model
    }

    @Test("A beam stopping at a column gets a hinge there, its own end node beside the column's")
    func hingeAtColumn() throws {
        let rigid = try ShellMesh(model: Self.joint(nil))
        #expect(rigid.hinges.isEmpty)
        let mesh = try ShellMesh(model: Self.joint(.weldedFlange))
        // Only the end at the column: the free end keeps its node.
        #expect(mesh.hinges.count == 1)
        #expect(mesh.positions.count == rigid.positions.count + 1)
        let hinge = try #require(mesh.hinges.first)
        #expect(hinge.axis == 0)
        #expect(
            simd_distance(mesh.positions[Int(hinge.beamNode)], mesh.positions[Int(hinge.jointNode)]) < 1e-6)
        // The column keeps the joint's node; the beam has the fresh one.
        #expect(
            mesh.beams.contains {
                $0.axis == 2 && ($0.nodes.x == hinge.jointNode || $0.nodes.y == hinge.jointNode)
            })
        #expect(
            !mesh.beams.contains {
                $0.axis == 0 && ($0.nodes.x == hinge.jointNode || $0.nodes.y == hinge.jointNode)
            })
    }

    @Test("A connection survives coding, and a model without one decodes as rigid")
    func coding() throws {
        let model = Self.joint(.singlePlateShear)
        let decoded = try JSONDecoder().decode(StructureModel.self, from: JSONEncoder().encode(model))
        #expect(decoded.steelConnection == .singlePlateShear)
        let rigid = try JSONDecoder().decode(StructureModel.self, from: JSONEncoder().encode(Self.joint(nil)))
        #expect(rigid.steelConnection == nil)
    }

    @Test(
        "Under a column's removal the hinged assemblies fail near their tests' drops and loads",
        arguments: ColumnRemovalTest.Specimen.allCases)
    func columnRemoval(specimen: ColumnRemovalTest.Specimen) throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        let r = try ColumnRemovalTest.run(
            device: device, specimen: specimen, connection: specimen.connection,
            drop: specimen == .singlePlateShear ? 1.4 : 1.1)
        let measured = ColumnRemovalTest.measured(specimen)
        let failed = try #require(r.failedAt, "\(specimen.rawValue) did not fail")
        print(
            "\(specimen.rawValue): failed at \(failed * 1000) mm, \(failed / measured.drop) of measured; "
                + "peak \(r.peakLoad / measured.load) of measured")
        // The fracture turns come from these tests: a check that the hinge reaches them as the
        // test's chord rotation did, not a validation.
        #expect(failed / measured.drop > 0.9 && failed / measured.drop < 1.4)
        #expect(r.peakLoad / measured.load > 0.7 && r.peakLoad / measured.load < 1.4)
    }

    @Test("Rigid, the welded assembly carries on well past where the test's fractured")
    func rigidRemoval() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        let rigid = try ColumnRemovalTest.run(
            device: device, specimen: .weldedFlange, connection: nil, drop: 0.8)
        #expect(rigid.failedAt == nil)
    }
}
