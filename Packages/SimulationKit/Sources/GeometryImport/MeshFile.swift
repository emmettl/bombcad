import Foundation
import simd

/// The polygons of an OBJ or STL file, as written: geometry only, in the file's own units and axes.
///
/// OBJ faces keep their corners, however many, with the object (`o`), group (`g`) and material
/// (`usemtl`) in force where they appear. STL has no shared corners, so each of its triangles gets
/// three vertices of its own. What makes a usable model is left to each app: BombCAD needs closed
/// solids of triangles, RoomCAD a closed room whose floors may be concave polygons.
public struct MeshFile: Sendable, Equatable {
    public struct Face: Sendable, Equatable {
        /// Indices into `vertices`, in the file's order.
        public var corners: [Int]
        public var object: String?
        public var group: String?
        public var material: String?

        public init(corners: [Int], object: String? = nil, group: String? = nil, material: String? = nil) {
            self.corners = corners
            self.object = object
            self.group = group
            self.material = material
        }
    }

    public init(vertices: [SIMD3<Float>], faces: [Face]) {
        self.vertices = vertices
        self.faces = faces
    }

    public var vertices: [SIMD3<Float>]
    public var faces: [Face]

    public enum ReadError: LocalizedError, Equatable {
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .invalid(let reason): reason
            }
        }
    }

    /// Files larger than this are refused.
    public static let sizeLimit = 20_000_000

    /// Reads an OBJ or STL file, chosen by its extension. Checks for cancellation as it goes.
    public init(data: Data, fileExtension: String) throws {
        try Task.checkCancellation()
        guard data.count <= Self.sizeLimit else { throw ReadError.invalid("Model exceeds the 20 MB limit.") }
        switch fileExtension.lowercased() {
        case "obj": (vertices, faces) = try Self.readOBJ(data)
        case "stl": (vertices, faces) = try Self.readSTL(data)
        default: throw ReadError.invalid("Choose an OBJ or STL file.")
        }
    }

    private static func readOBJ(_ data: Data) throws -> ([SIMD3<Float>], [Face]) {
        guard let source = String(data: data, encoding: .utf8) else {
            throw ReadError.invalid("OBJ must be UTF-8 text.")
        }
        var vertices: [SIMD3<Float>] = []
        var faces: [Face] = []
        var objectName: String?
        var groupName: String?
        var materialName: String?
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
            of: "\r", with: "\n"
        )
        .split(separator: "\n", omittingEmptySubsequences: false)
        for (lineIndex, line) in lines.enumerated() {
            if lineIndex % 256 == 0 { try Task.checkCancellation() }
            let fields = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(whereSeparator: \.isWhitespace)
            guard let first = fields.first else { continue }
            if first == "o" || first == "g" || first == "usemtl" {
                let name = fields.dropFirst().joined(separator: " ")
                guard name.count <= 200 || first == "usemtl" else {
                    throw ReadError.invalid("OBJ part names must be at most 200 characters.")
                }
                if first == "o" {
                    objectName = name.isEmpty ? nil : name
                } else if first == "g" {
                    groupName = name.isEmpty || name == "off" ? nil : name
                } else {
                    materialName = name.isEmpty ? nil : name
                }
            } else if first == "v" {
                guard fields.count >= 4, let x = Float(fields[1]), let y = Float(fields[2]),
                    let z = Float(fields[3])
                else { throw ReadError.invalid("Invalid OBJ vertex at line \(lineIndex + 1).") }
                vertices.append(SIMD3(x, y, z))
            } else if first == "f" {
                guard fields.count >= 4 else {
                    throw ReadError.invalid(
                        "OBJ face at line \(lineIndex + 1) needs at least three vertices.")
                }
                let corners = try fields.dropFirst().map { field -> Int in
                    guard let token = field.split(separator: "/").first, let raw = Int(token), raw != 0 else {
                        throw ReadError.invalid("Invalid OBJ face index at line \(lineIndex + 1).")
                    }
                    let index = raw > 0 ? raw - 1 : vertices.count + raw
                    guard vertices.indices.contains(index) else {
                        throw ReadError.invalid(
                            "OBJ face at line \(lineIndex + 1) references a missing vertex.")
                    }
                    return index
                }
                faces.append(
                    Face(corners: corners, object: objectName, group: groupName, material: materialName))
            }
        }
        return (vertices, faces)
    }

    private static func readSTL(_ data: Data) throws -> ([SIMD3<Float>], [Face]) {
        func uint(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16
                | UInt32(data[offset + 3]) << 24
        }
        var points: [SIMD3<Float>] = []
        if data.count >= 84, 84 + UInt64(uint(80)) * 50 == UInt64(data.count) {
            func point(_ offset: Int) -> SIMD3<Float> {
                SIMD3(
                    Float(bitPattern: uint(offset)), Float(bitPattern: uint(offset + 4)),
                    Float(bitPattern: uint(offset + 8)))
            }
            for n in 0..<Int(uint(80)) {
                if n % 256 == 0 { try Task.checkCancellation() }
                let offset = 84 + n * 50 + 12
                points += [point(offset), point(offset + 12), point(offset + 24)]
            }
        } else {
            guard let source = String(data: data, encoding: .utf8) else {
                throw ReadError.invalid("Invalid STL file.")
            }
            for (lineIndex, line) in source.split(whereSeparator: \.isNewline).enumerated() {
                if lineIndex % 256 == 0 { try Task.checkCancellation() }
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.first == "vertex" {
                    guard fields.count == 4, let x = Float(fields[1]), let y = Float(fields[2]),
                        let z = Float(fields[3])
                    else { throw ReadError.invalid("Invalid STL vertex.") }
                    points.append(SIMD3(x, y, z))
                }
            }
            guard points.count % 3 == 0 else { throw ReadError.invalid("Incomplete STL triangle.") }
        }
        let faces = stride(from: 0, to: points.count, by: 3).map {
            Face(corners: [$0, $0 + 1, $0 + 2], object: nil, group: nil, material: nil)
        }
        return (points, faces)
    }
}
