import Foundation
import Testing
import simd

@testable import BlastCore

/// Reinforcement read from IFC (`IFCReinforcement`) onto the shells and beams `IFCStructure`
/// meshes, from elements and bars built here, so that the converter is not needed.
@Suite("IFC reinforcement")
struct IFCReinforcementTests {
    private func element(
        _ n: Int, _ name: String, _ ifcClass: String, _ box: Box, concrete: Bool = true,
        reinforcement: IFCReinforcement.Hosted? = nil
    ) throws -> ImportedMesh.BuildingElement {
        var text = ""
        for k in 0..<8 {
            let p = SIMD3(
                k & 1 == 0 ? box.min.x : box.max.x, k & 2 == 0 ? box.min.y : box.max.y,
                k & 4 == 0 ? box.min.z : box.max.z)
            text += "v \(p.x) \(p.y) \(p.z)\n"
        }
        for face in [
            [0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5],
        ] {
            let v = face.map { $0 + 1 }
            text += "f \(v[0]) \(v[1]) \(v[2])\nf \(v[0]) \(v[2]) \(v[3])\n"
        }
        return ImportedMesh.BuildingElement(
            globalID: String(format: "%022d", n), name: name, ifcClass: ifcClass, storey: "Ground",
            mesh: try ImportedMesh(data: Data(text.utf8), fileExtension: "obj"),
            materials: concrete ? [IFCStructure.Layer(name: "Concrete C30/37")] : nil,
            reinforcement: reinforcement)
    }

    /// A tube of `diameter` along a polyline, as a converter would mesh a swept disk: a ring of
    /// `sides` points at each vertex, joined, and capped at both ends.
    private func tube(_ path: [SIMD3<Float>], diameter: Float, sides: Int = 48) -> [ImportedMesh.Triangle] {
        var rings: [[SIMD3<Float>]] = []
        for (n, point) in path.enumerated() {
            let direction = simd_normalize(
                n == 0
                    ? path[1] - path[0]
                    : n == path.count - 1 ? path[n] - path[n - 1] : path[n + 1] - path[n - 1])
            let helper: SIMD3<Float> = abs(direction.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
            let u = simd_normalize(simd_cross(direction, helper))
            let v = simd_cross(direction, u)
            rings.append(
                (0..<sides).map {
                    let angle = 2 * Float.pi * Float($0) / Float(sides)
                    return point + 0.5 * diameter * (cos(angle) * u + sin(angle) * v)
                })
        }
        var triangles: [ImportedMesh.Triangle] = []
        for n in 0..<(rings.count - 1) {
            for s in 0..<sides {
                let (a, b) = (rings[n][s], rings[n][(s + 1) % sides])
                let (c, d) = (rings[n + 1][s], rings[n + 1][(s + 1) % sides])
                triangles += [.init(a: a, b: b, c: d), .init(a: a, b: d, c: c)]
            }
        }
        for (ring, flip) in [(rings[0], true), (rings[rings.count - 1], false)] {
            let centre = ring.reduce(.zero, +) / Float(sides)
            for s in 0..<sides {
                let (a, b) = (ring[s], ring[(s + 1) % sides])
                triangles.append(flip ? .init(a: centre, b: b, c: a) : .init(a: centre, b: a, c: b))
            }
        }
        return triangles
    }

    @Test(
        "A bar is measured from its meshed shape: diameter, length and direction; a bent one is not straight")
    func measured() throws {
        let straight = try #require(
            IFCReinforcement.Bar(
                globalID: "a", triangles: tube([SIMD3(0, 0, 0), SIMD3(0, 0, 3)], diameter: 0.016)))
        #expect(abs(straight.diameter / 0.016 - 1) < 0.01)
        #expect(abs(straight.length / 3 - 1) < 0.01)
        #expect(abs(straight.axis.z) > 0.999 && straight.straight)
        let bent = try #require(
            IFCReinforcement.Bar(
                globalID: "b",
                triangles: tube([SIMD3(0, 0, 0), SIMD3(0, 0, 0.5), SIMD3(0, 0.5, 0.5)], diameter: 0.012)))
        #expect(!bent.straight)
        // The IFC's own size, where it gives it, is taken over the measured one.
        var sized = straight
        sized.size(diameter: 0.016, area: 2.01e-4, source: "the IFC's type")
        #expect(
            sized.area == 2.01e-4 && abs(sized.length / 3 - 1) < 0.01 && sized.sizeSource == "the IFC's type")
    }

    @Test("Bars go to the element the IFC nests them in, else to the concrete element they lie in")
    func hosting() throws {
        let wall = try element(1, "Wall", "IfcWall", Box(min: SIMD3(0, 0, 0), max: SIMD3(4, 0.2, 3)))
        let slab = try element(2, "Slab", "IfcSlab", Box(min: SIMD3(0, 0, 3), max: SIMD3(4, 4, 3.2)))
        let inWall = IFCReinforcement.Bar(
            globalID: "w", from: SIMD3(1, 0.05, 0.1), to: SIMD3(1, 0.05, 2.9), diameter: 0.012)
        let nested = IFCReinforcement.Bar(
            globalID: "n", from: SIMD3(1, 0.05, 0.1), to: SIMD3(1, 0.05, 2.9), diameter: 0.012)
        let outside = IFCReinforcement.Bar(
            globalID: "o", from: SIMD3(9, 9, 9), to: SIMD3(9, 9, 10), diameter: 0.012)
        let (hosted, unhosted) = IFCReinforcement.host(
            [inWall, nested, outside], in: [wall, slab], hosts: ["n": slab.globalID])
        #expect(hosted[0].reinforcement?.bars.map(\.globalID) == ["w"])
        #expect(hosted[1].reinforcement?.bars.map(\.globalID) == ["n"])
        #expect(unhosted.map(\.globalID) == ["o"])
    }

    /// 12 mm bars at 200 mm both ways in each face of a 4 × 3 m wall 0.2 m thick: vertical bars
    /// 40 mm from each face, horizontal ones inside them in one face (52 mm).
    private func reinforcedWall() -> IFCReinforcement.Hosted {
        var bars: [IFCReinforcement.Bar] = []
        for i in 0..<20 {
            let x = 0.1 + 0.2 * Float(i)
            for y: Float in [0.04, 0.16] {
                bars.append(
                    .init(globalID: "v\(i)-\(y)", from: SIMD3(x, y, 0), to: SIMD3(x, y, 3), diameter: 0.012))
            }
        }
        for j in 0..<15 {
            let z = 0.1 + 0.2 * Float(j)
            bars.append(
                .init(globalID: "h\(j)", from: SIMD3(0, 0.052, z), to: SIMD3(4, 0.052, z), diameter: 0.012))
        }
        return IFCReinforcement.Hosted(bars: bars)
    }

    @Test("A wall's bars become a mat in each face, its steel each way per metre at the bars' depth")
    func wallMats() throws {
        let elements = [
            try element(
                1, "Wall", "IfcWall", Box(min: SIMD3(0, 0, 0), max: SIMD3(4, 0.2, 3)),
                reinforcement: reinforcedWall()),
            try element(
                2, "Footing slab", "IfcSlab", Box(min: SIMD3(-0.5, -0.5, -0.3), max: SIMD3(4.5, 0.7, 0))),
        ]
        let structure = try IFCStructure(elements: elements, options: .init(elementSize: 0.25))
        let wall = try #require(structure.members.first { $0.name == "Wall" })
        #expect(wall.reinforcementAssumed == false)
        #expect(wall.reinforcementSource?.contains("From the IFC: 55 bars") == true)
        let mesh = try ShellMesh(model: structure.model)
        // Every plate of the wall, its bottom row stretched down to the slab's midsurface too.
        let plates = mesh.elements.filter { $0.solid == wall.solid }
        #expect(plates.allSatisfy { $0.bars.count == 2 })
        let plate = try #require(plates.first)
        // y through the thickness: the plate's first axis is z (vertical bars), the second x.
        let bar: Float = .pi * 0.006 * 0.006
        let perMetre = 5 * bar
        let faces = plate.bars.sorted { $0.x < $1.x }
        #expect(faces.count == 2)
        #expect(abs(faces[0].y / perMetre - 1) < 0.01 && abs(faces[0].z / perMetre - 1) < 0.01)
        #expect(abs(faces[1].y / perMetre - 1) < 0.01 && faces[1].z == 0)
        // The face with both layers at their steel-weighted mean depth, 46 mm; the other at 40 mm.
        let half = 0.5 * plate.thickness
        #expect(abs((1 + faces[0].x) * half - 0.046) < 1e-3)
        #expect(abs((1 - faces[1].x) * half - 0.040) < 1e-3)
    }

    @Test("A wall built of parts takes the bars of every part, not just its first")
    func partsGathered() throws {
        let all = reinforcedWall()
        var parts: [ImportedMesh.BuildingElement] = []
        for (n, range) in [(Float(0), Float(2)), (2, 4)].enumerated() {
            var part = try element(
                3 + n, "Block \(n)", "IfcBuildingElementPart",
                Box(min: SIMD3(range.0, 0, 0), max: SIMD3(range.1, 0.2, 3)),
                // The horizontal bars, which run through both, with the first.
                reinforcement: .init(
                    bars: all.bars.filter { (abs($0.axis.z) < 0.5 || $0.centre.x < 2) == (n == 0) }))
            part.assembly = .init(id: String(format: "%022d", 1), name: "Wall", ifcClass: "IfcWall")
            parts.append(part)
        }
        #expect(parts.map { $0.reinforcement?.bars.count ?? 0 } == [35, 20])
        let structure = try IFCStructure(elements: parts, options: .init(elementSize: 0.25))
        let wall = try #require(structure.members.first { $0.name == "Wall" })
        #expect(wall.reinforcementSource?.contains("From the IFC: 55 bars") == true)
    }

    @Test("A column's bars along it become bars at its corners and sides; its stirrups, ties")
    func columnBars() throws {
        // A 0.3 m square column 3 m high: four 20 mm bars at its corners and four 16 mm at the
        // middles of its sides, 50 mm from its faces to their centres; 8 mm stirrups every 0.2 m.
        var bars: [IFCReinforcement.Bar] = []
        for (n, corner) in [
            SIMD2<Float>(0.05, 0.05), SIMD2(0.25, 0.05), SIMD2(0.05, 0.25), SIMD2(0.25, 0.25),
        ]
        .enumerated() {
            bars.append(
                .init(
                    globalID: "c\(n)", from: SIMD3(corner.x, corner.y, 0), to: SIMD3(corner.x, corner.y, 3),
                    diameter: 0.02))
        }
        for (n, side) in [SIMD2<Float>(0.15, 0.05), SIMD2(0.15, 0.25), SIMD2(0.05, 0.15), SIMD2(0.25, 0.15)]
            .enumerated()
        {
            bars.append(
                .init(
                    globalID: "s\(n)", from: SIMD3(side.x, side.y, 0), to: SIMD3(side.x, side.y, 3),
                    diameter: 0.016))
        }
        // Each stirrup as its four legs, 0.22 m between their centres' corners.
        let legs: [SIMD2<Float>] = [
            SIMD2(0.04, 0.04), SIMD2(0.26, 0.04), SIMD2(0.26, 0.26), SIMD2(0.04, 0.26),
        ]
        for k in 0..<15 {
            let z = 0.1 + 0.2 * Float(k)
            for leg in 0..<4 {
                let (a, b) = (legs[leg], legs[(leg + 1) % 4])
                bars.append(
                    .init(
                        globalID: "t\(k)-\(leg)", from: SIMD3(a.x, a.y, z), to: SIMD3(b.x, b.y, z),
                        diameter: 0.008))
            }
        }
        let elements = [
            try element(
                1, "Column", "IfcColumn", Box(min: SIMD3(0, 0, 0), max: SIMD3(0.3, 0.3, 3)),
                reinforcement: .init(bars: bars)),
            try element(2, "Slab", "IfcSlab", Box(min: SIMD3(-1, -1, 3), max: SIMD3(1.3, 1.3, 3.2))),
        ]
        let structure = try IFCStructure(elements: elements, options: .init(elementSize: 0.25))
        let column = try #require(structure.members.first { $0.name == "Column" })
        #expect(column.role == .beam && column.reinforcementAssumed == false)
        #expect(column.reinforcementSource?.contains("8 bars along it") == true)
        #expect(column.reinforcementSource?.contains("60 ties") == true)
        let mesh = try ShellMesh(model: structure.model)
        let beam = try #require(mesh.beams.first { $0.solid == column.solid })
        #expect(beam.bars.count == 8)
        let steel = beam.bars.reduce(0) { $0 + $1.z }
        let expected = 4 * Float.pi * 0.01 * 0.01 + 4 * Float.pi * 0.008 * 0.008
        #expect(abs(steel / expected - 1) < 0.01)
        // Corner bars at 50 mm from the faces: a third of the half section from its corner.
        let corners = beam.bars.filter { abs($0.x) > 0.5 && abs($0.y) > 0.5 }
        #expect(corners.count == 4 && corners.allSatisfy { abs(abs($0.x) - 2.0 / 3) < 0.02 })
        // Ties: 15 stirrups of 0.88 m and 8 mm, over the column's volume, half each way.
        let tie = 15 * 0.88 * Float.pi * 0.004 * 0.004 / (0.3 * 0.3 * 3) / 2
        #expect(abs(beam.tieRatio / tie - 1) < 0.05)
    }

    @Test(
        "Properties alone give a ratio at their cover; members the IFC leaves out take the default in shells, flagged"
    )
    func propertiesAndDefault() throws {
        let properties = IFCReinforcement.Properties(
            cover: 0.025, areaRatio: 0.01, source: "Pset_ConcreteElementGeneral")
        let elements = [
            try element(
                1, "Slab", "IfcSlab", Box(min: SIMD3(0, 0, 3), max: SIMD3(4, 4, 3.2)),
                reinforcement: .init(properties: properties)),
            try element(2, "Wall", "IfcWall", Box(min: SIMD3(0, 0, 0), max: SIMD3(4, 0.2, 3))),
            try element(3, "Column", "IfcColumn", Box(min: SIMD3(1.85, 1.85, 0), max: SIMD3(2.15, 2.15, 3))),
            try element(
                4, "Brick wall", "IfcWall", Box(min: SIMD3(0, 3.8, 0), max: SIMD3(4, 4, 3)), concrete: false),
        ]
        let structure = try IFCStructure(
            elements: elements, options: .init(elementSize: 0.25, reinforcement: 0.004))
        let slab = try #require(structure.members.first { $0.name == "Slab" })
        let wall = try #require(structure.members.first { $0.name == "Wall" })
        let column = try #require(structure.members.first { $0.name == "Column" })
        #expect(
            slab.reinforcementAssumed == false && slab.reinforcementSource?.contains("properties") == true)
        #expect(wall.reinforcementAssumed == true && wall.reinforcementSource?.hasPrefix("Default") == true)
        #expect(
            column.reinforcementAssumed == true && column.reinforcementSource?.contains("shells only") == true
        )
        #expect(structure.assumptions.contains { $0.contains("read from the IFC in 1 concrete member") })
        // The wall and the brick wall, which has no material in the IFC and takes the default.
        #expect(structure.assumptions.contains { $0.contains("2 concrete shells reinforced") })
        let mesh = try ShellMesh(model: structure.model)
        let plate = try #require(mesh.elements.first { $0.solid == slab.solid })
        // A quarter of 1% of 0.2 m each way in each face, 31 mm to the bars' centres.
        #expect(plate.bars.count == 2)
        #expect(plate.bars.allSatisfy { abs($0.y / 5e-4 - 1) < 0.01 && abs($0.z / 5e-4 - 1) < 0.01 })
        #expect(plate.bars.allSatisfy { abs((1 - abs($0.x)) * 0.1 - 0.031) < 1e-3 })
    }
}
