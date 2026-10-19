import Foundation
import Testing
import simd

@testable import BlastModel

/// Steel connections (`SteelConnection`): which beam ends get a hinge, and the column-removal
/// assemblies they were judged on (`ColumnRemovalTest`), so a change that moves those is seen.
@Suite("Steel connections")
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

    @Test("A connection a hinge cannot use is refused, from a document too")
    func invalid() throws {
        let bad = [
            SteelConnection(name: "No turn", momentRatio: 0.5, fractureRotation: 0),
            SteelConnection(name: "NaN turn", momentRatio: 0.5, fractureRotation: .nan),
            SteelConnection(name: "Negative", momentRatio: -0.5, fractureRotation: 0.08),
            SteelConnection(name: "Pushed", momentRatio: 0.5, fractureRotation: 0.08, tensionRatio: -0.1),
        ]
        for connection in bad { #expect(throws: (any Error).self) { try connection.validate() } }
        try SteelConnection.singlePlateShear.validate()
        let model = Self.joint(SteelConnection(name: "Broken", momentRatio: 0.5, fractureRotation: -0.01))
        let data = try JSONEncoder().encode(model)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(StructureModel.self, from: data) }
    }
}
