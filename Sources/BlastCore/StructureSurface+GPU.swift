import BlastModel
import Foundation
import simd

extension BlastSolver {
    /// The body's visible surface now, or nil without a body.
    public func structureSurface() -> StructureSurface? {
        guard hasBody else { return nil }
        var surface = StructureSurface()
        for body in bodies {
            let first = surface.faceCount
            body.solids?.appendSurface(to: &surface)
            body.shells?.appendSurface(to: &surface)
            surface.object.append(
                contentsOf: repeatElement(Int32(surface.objectIDs.count), count: surface.faceCount - first))
            surface.objectIDs.append(body.id)
            surface.objectNames.append(body.name)
        }
        return surface
    }
}

extension StructureSolver {
    func appendSurface(to surface: inout StructureSurface) {
        let cells = ex * ey * ez
        let flags = flagBuffer.contents().bindMemory(to: UInt8.self, capacity: cells)
        let nodes = nodeBuffer.contents().bindMemory(to: StructureNode.self, capacity: max(nodeCount, 1))
        let nodeMap = nodeMapBuffer.contents().bindMemory(
            to: UInt32.self, capacity: (ex + 1) * (ey + 1) * (ez + 1))
        let instances = instanceBuffer.contents().bindMemory(to: UInt32.self, capacity: max(elementCount, 1))
        let materialIndices = materialIndexBuffer.contents().bindMemory(
            to: UInt8.self, capacity: max(elementCount, 1))
        let states = stateBuffer.contents()
        let h = model.elementSize
        let names = materials.map { surface.index(of: $0) }
        let active = ElementFlag.active.rawValue

        func position(_ point: SIMD3<Int>) -> SIMD3<Float> {
            let node = Int(nodeMap[point.x + (ex + 1) * (point.y + (ey + 1) * point.z)])
            return origin + SIMD3<Float>(point) * h + nodes[node].displacement
        }
        // Intact elements share their nodes, so each node becomes one point.
        var pointOfNode = [Int32](repeating: -1, count: nodeCount)
        func point(_ lattice: SIMD3<Int>) -> Int32 {
            let node = Int(nodeMap[lattice.x + (ex + 1) * (lattice.y + (ey + 1) * lattice.z)])
            if pointOfNode[node] < 0 {
                pointOfNode[node] = Int32(surface.points.count)
                surface.points.append(origin + SIMD3<Float>(lattice) * h + nodes[node].displacement)
            }
            return pointOfNode[node]
        }
        let square = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]

        for compact in 0..<elementCount {
            let element = Int(instances[compact])
            let cell = SIMD3(element % ex, (element / ex) % ey, element / (ex * ey))
            let material = names[Int(materialIndices[compact] & 0x0F)]
            switch flags[element] {
            case active:
                let damage = states.load(fromByteOffset: compact * Self.stateStride + 28, as: Float.self)
                for axis in 0..<3 {
                    for side in 0..<2 {
                        var neighbour = cell
                        neighbour[axis] += side == 0 ? -1 : 1
                        if neighbour.x >= 0, neighbour.y >= 0, neighbour.z >= 0,
                            neighbour.x < ex, neighbour.y < ey, neighbour.z < ez,
                            flags[neighbour.x + ex * (neighbour.y + ey * neighbour.z)] == active
                        {
                            continue
                        }
                        // Counter-clockwise about +axis on the far side, so reversed on the near.
                        let corners = (side == 1 ? square : square.reversed()).map { corner -> Int32 in
                            var offset = SIMD3<Int>.zero
                            offset[axis] = side
                            offset[(axis + 1) % 3] = corner.x
                            offset[(axis + 2) % 3] = corner.y
                            return point(cell &+ offset)
                        }
                        surface.appendFace(corners, damage: damage, material: material)
                    }
                }
            case ElementFlag.eroded.rawValue:
                let bits = (0..<8).map { SIMD3($0 & 1, ($0 >> 1) & 1, ($0 >> 2) & 1) }
                let centre = bits.map { position(cell &+ $0) }.reduce(SIMD3<Float>.zero, +) / 8
                let corners = bits.map { centre + (SIMD3<Float>($0) - 0.5) * (0.6 * h) }
                surface.appendBox(
                    corners, faces: StructureSurface.bitCubeFaces, damage: 1, material: material, rubble: true
                )
            default:
                continue
            }
        }
    }
}

extension ShellSolver {
    func appendSurface(to surface: inout StructureSurface) {
        let nodes = nodeBuffer.contents().bindMemory(to: ShellNode.self, capacity: max(nodeCount, 1))
        let reference = referenceBuffer.contents().bindMemory(
            to: SIMD4<Float>.self, capacity: max(nodeCount, 1))
        let names = materials.map { surface.index(of: $0) }
        func position(_ node: UInt32) -> SIMD3<Float> {
            let index = Int(node)
            let r = reference[index]
            return SIMD3(r.x, r.y, r.z) + nodes[index].displacement
        }

        let elements = elementBuffer.contents().bindMemory(
            to: ShellElementData.self, capacity: max(elementCount, 1))
        let flags = flagBuffer.contents().bindMemory(to: UInt8.self, capacity: max(elementCount, 1))
        let damage = displayBuffer.contents().bindMemory(to: Float.self, capacity: max(elementCount, 1))
        for index in 0..<elementCount {
            let flag = flags[index]
            guard flag != 0 else { continue }
            let element = elements[index]
            let ids = [element.n0, element.n1, element.n2, element.n3]
            let material = names[Int(element.material)]
            if flag == 1 || flag == 3 {
                // The slab between its two faces, half its thickness either side of the
                // midsurface along the rotated directors.
                var normal = SIMD3<Float>.zero
                if element.axis == 3 {
                    // At a pitch: square to its first and second edges, from its reference corners.
                    func rest(_ node: UInt32) -> SIMD3<Float> {
                        let r = reference[Int(node)]
                        return SIMD3(r.x, r.y, r.z)
                    }
                    normal = simd_normalize(
                        simd_cross(rest(element.n1) - rest(element.n0), rest(element.n3) - rest(element.n0)))
                } else {
                    normal[Int(element.axis)] = 1
                }
                let corners = (0..<8).map { corner -> SIMD3<Float> in
                    let id = ids[corner & 3]
                    let director = nodes[Int(id)].rotation.act(normal)
                    return position(id) + (corner < 4 ? -0.5 : 0.5) * element.thickness * director
                }
                surface.appendBox(
                    corners, faces: StructureSurface.shellFaces, damage: damage[index], material: material)
            } else {
                let centre = ids.map(position).reduce(SIMD3<Float>.zero, +) / 4
                let size = 0.3 * min(min(element.a, element.b), max(element.thickness, 0.05) * 2)
                let corners = (0..<8).map { corner -> SIMD3<Float> in
                    let c = corner & 3
                    let offset = SIMD3<Float>(
                        c == 1 || c == 2 ? 0.5 : -0.5, c >= 2 ? 0.5 : -0.5, corner < 4 ? -0.5 : 0.5)
                    return centre + offset * size
                }
                surface.appendBox(
                    corners, faces: StructureSurface.shellFaces, damage: 1, material: material, rubble: true)
            }
        }

        let beams = beamBuffer.contents().bindMemory(to: BeamElementData.self, capacity: max(beamCount, 1))
        let beamFlags = beamFlagBuffer.contents().bindMemory(to: UInt8.self, capacity: max(beamCount, 1))
        let beamDamage = beamDisplayBuffer.contents().bindMemory(to: Float.self, capacity: max(beamCount, 1))
        for index in 0..<beamCount where beamFlags[index] == 1 || beamFlags[index] == 3 {
            let beam = beams[index]
            var e2 = SIMD3<Float>.zero
            var e3 = SIMD3<Float>.zero
            e2[(Int(beam.axis) + 1) % 3] = 1
            e3[(Int(beam.axis) + 2) % 3] = 1
            // Bit 0 picks the end, bits 1 and 2 the side of the section.
            let corners = (0..<8).map { corner -> SIMD3<Float> in
                let id = corner & 1 == 0 ? beam.n0 : beam.n1
                let rotation = nodes[Int(id)].rotation
                let s2: Float = corner & 2 != 0 ? 0.5 : -0.5
                let s3: Float = corner & 4 != 0 ? 0.5 : -0.5
                return position(id) + s2 * beam.width * rotation.act(e2) + s3 * beam.depth * rotation.act(e3)
            }
            surface.appendBox(
                corners, faces: StructureSurface.bitCubeFaces, damage: beamDamage[index],
                material: names[Int(beam.material)])
        }
    }
}
