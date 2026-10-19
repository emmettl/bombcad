import BlastCore
import BlastRender
import DocumentKit
import Foundation

/// A watched run's scene view as it travels: `ViewSetup` once and a `ViewFrame` each frame, as
/// little-endian binary (counts as 64-bit integers, then the values packed: three floats for each
/// `SIMD3<Float>`, four for each `SIMD4<Float>`), for `ViewUpload` here to draw with the app's own
/// renderer.
enum SceneViewCodec {
    static func encode(_ setup: ViewSetup) -> Data {
        var out = Writer()
        out.integers([setup.fieldSize.x, setup.fieldSize.y, setup.fieldSize.z])
        out.float(setup.fieldCellSize)
        out.integer(setup.bodies.count)
        for body in setup.bodies {
            out.flag(body.solids != nil)
            if let solids = body.solids {
                out.floats([solids.origin.x, solids.origin.y, solids.origin.z, solids.elementSize])
                out.integers([solids.ex, solids.ey, solids.ez, solids.nodeCount])
                out.array(solids.instances)
                out.array(solids.nodeMap)
            }
            out.flag(body.shells != nil)
            if let shells = body.shells {
                out.integers([shells.elementCount, shells.beamCount])
                out.data(shells.elements)
                out.data(shells.beams)
                out.vectors(shells.reference)
                out.array([shells.transparentMaterials])
            }
        }
        // The materials' colours, after everything a sender before them wrote (`decodeSetup`
        // reads them where there are more bytes).
        for body in setup.bodies {
            if let solids = body.solids {
                out.vectors(solids.palette)
                out.array(solids.materialIndex)
            }
            if let shells = body.shells { out.vectors(shells.palette) }
        }
        return out.data
    }

    static func decodeSetup(_ data: Data) throws -> ViewSetup {
        var input = Reader(data)
        let size = SIMD3(try input.integer(), try input.integer(), try input.integer())
        let cellSize = try input.float()
        var bodies = try (0..<input.count()).map { _ in
            let solids: ViewSetup.Solids? =
                try input.flag()
                ? try {
                    let corner = try input.floats(4)
                    let counts = try (0..<4).map { _ in try input.integer() }
                    return ViewSetup.Solids(
                        origin: SIMD3(corner[0], corner[1], corner[2]), elementSize: corner[3], ex: counts[0],
                        ey: counts[1], ez: counts[2], instances: try input.array(),
                        nodeMap: try input.array(),
                        nodeCount: counts[3])
                }() : nil
            let shells: ViewSetup.Shells? =
                try input.flag()
                ? try {
                    let elementCount = try input.integer()
                    let beamCount = try input.integer()
                    let elements = try input.data()
                    let beams = try input.data()
                    let reference = try input.vectors4()
                    let mask: [UInt32] = try input.array()
                    guard mask.count == 1 else {
                        throw ProjectFileError.invalid("A scene view's setup is malformed.")
                    }
                    return ViewSetup.Shells(
                        elements: elements, elementCount: elementCount, beams: beams, beamCount: beamCount,
                        reference: reference, transparentMaterials: mask[0])
                }() : nil
            return ViewSetup.Body(solids: solids, shells: shells)
        }
        if !input.isAtEnd {
            for n in bodies.indices {
                if bodies[n].solids != nil {
                    bodies[n].solids?.palette = try input.vectors4()
                    bodies[n].solids?.materialIndex = try input.array()
                }
                if bodies[n].shells != nil { bodies[n].shells?.palette = try input.vectors4() }
            }
        }
        try input.finish()
        return ViewSetup(fieldSize: size, fieldCellSize: cellSize, bodies: bodies)
    }

    static func encode(_ frame: ViewFrame) -> Data {
        var out = Writer()
        out.double(frame.time)
        out.data(frame.field)
        out.integer(frame.bodies.count)
        for body in frame.bodies {
            out.flag(body.solids != nil)
            if let solids = body.solids {
                out.vectors(solids.displacements)
                out.array(solids.flags)
                out.array(solids.damage)
            }
            out.flag(body.shells != nil)
            if let shells = body.shells {
                out.vectors(shells.displacements)
                out.vectors(shells.rotations)
                out.array(shells.flags)
                out.array(shells.beamFlags)
                out.array(shells.damage)
                out.array(shells.beamDamage)
            }
        }
        return out.data
    }

    /// The bytes `encode(frame)` writes, worked out without writing them.
    static func size(_ frame: ViewFrame) -> Int {
        var bytes = 8 + 8 + frame.field.count + 8
        for body in frame.bodies {
            bytes += 2
            if let solids = body.solids {
                bytes +=
                    8 + 12 * solids.displacements.count + 8 + solids.flags.count + 8 + 4 * solids.damage.count
            }
            if let shells = body.shells {
                bytes += 8 + 12 * shells.displacements.count + 8 + 16 * shells.rotations.count
                bytes += 8 + shells.flags.count + 8 + shells.beamFlags.count
                bytes += 8 + 4 * shells.damage.count + 8 + 4 * shells.beamDamage.count
            }
        }
        return bytes
    }

    static func decodeFrame(_ data: Data) throws -> ViewFrame {
        var input = Reader(data)
        let time = try input.double()
        let field = try input.data()
        let bodies = try (0..<input.count()).map { _ in
            let solids: ViewFrame.Solids? =
                try input.flag()
                ? ViewFrame.Solids(
                    displacements: try input.vectors3(), flags: try input.array(), damage: try input.array())
                : nil
            let shells: ViewFrame.Shells? =
                try input.flag()
                ? ViewFrame.Shells(
                    displacements: try input.vectors3(), rotations: try input.vectors4(),
                    flags: try input.array(),
                    beamFlags: try input.array(), damage: try input.array(), beamDamage: try input.array())
                : nil
            return ViewFrame.Body(solids: solids, shells: shells)
        }
        try input.finish()
        return ViewFrame(time: time, field: field, bodies: bodies)
    }

    private struct Writer {
        var data = Data()

        mutating func raw<T>(_ values: [T]) { values.withUnsafeBytes { data.append(contentsOf: $0) } }
        mutating func integer(_ value: Int) { raw([Int64(value)]) }
        mutating func integers(_ values: [Int]) { raw(values.map(Int64.init)) }
        mutating func float(_ value: Float) { raw([value]) }
        mutating func floats(_ values: [Float]) { raw(values) }
        mutating func double(_ value: Double) { raw([value]) }
        mutating func flag(_ value: Bool) { raw([UInt8(value ? 1 : 0)]) }
        mutating func array<T: BitwiseCopyable>(_ values: [T]) {
            integer(values.count)
            raw(values)
        }
        mutating func data(_ value: Data) {
            integer(value.count)
            data.append(value)
        }
        mutating func vectors(_ values: [SIMD3<Float>]) {
            integer(values.count)
            raw(values.flatMap { [$0.x, $0.y, $0.z] })
        }
        mutating func vectors(_ values: [SIMD4<Float>]) {
            integer(values.count)
            raw(values.flatMap { [$0.x, $0.y, $0.z, $0.w] })
        }
    }

    private struct Reader {
        let bytes: Data
        var offset = 0

        init(_ data: Data) { bytes = Data(data) }

        var isAtEnd: Bool { offset >= bytes.count }

        mutating func raw<T: BitwiseCopyable>(_ count: Int, _: T.Type) throws -> [T] {
            let length = count * MemoryLayout<T>.size
            guard count >= 0, offset + length <= bytes.count else {
                throw ProjectFileError.invalid("A scene view was cut short.")
            }
            defer { offset += length }
            // One copy, the bytes needing no alignment.
            return [T](unsafeUninitializedCapacity: count) { values, initialized in
                bytes.withUnsafeBytes { raw in
                    UnsafeMutableRawBufferPointer(values).copyMemory(
                        from: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + length]))
                }
                initialized = count
            }
        }
        mutating func integer() throws -> Int { Int(try raw(1, Int64.self)[0]) }
        /// A count, refused if more than the bytes left could hold.
        mutating func count() throws -> Int {
            let count = try integer()
            guard count >= 0, count <= bytes.count - offset else {
                throw ProjectFileError.invalid("A scene view is malformed.")
            }
            return count
        }
        mutating func float() throws -> Float { try raw(1, Float.self)[0] }
        mutating func floats(_ count: Int) throws -> [Float] { try raw(count, Float.self) }
        mutating func double() throws -> Double { try raw(1, Double.self)[0] }
        mutating func flag() throws -> Bool { try raw(1, UInt8.self)[0] != 0 }
        mutating func array<T: BitwiseCopyable>() throws -> [T] { try raw(count(), T.self) }
        mutating func data() throws -> Data {
            let count = try count()
            defer { offset += count }
            return bytes.subdata(in: offset..<offset + count)
        }
        mutating func vectors3() throws -> [SIMD3<Float>] {
            let values = try raw(3 * count(), Float.self)
            return Swift.stride(from: 0, to: values.count, by: 3).map {
                SIMD3(values[$0], values[$0 + 1], values[$0 + 2])
            }
        }
        mutating func vectors4() throws -> [SIMD4<Float>] {
            let values = try raw(4 * count(), Float.self)
            return Swift.stride(from: 0, to: values.count, by: 4).map {
                SIMD4(values[$0], values[$0 + 1], values[$0 + 2], values[$0 + 3])
            }
        }
        func finish() throws {
            guard offset == bytes.count else {
                throw ProjectFileError.invalid("A scene view has bytes left over.")
            }
        }
    }
}
