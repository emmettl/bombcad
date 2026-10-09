import Foundation
import simd

/// Writes a run as a USD scene in its text form (`.usda`), for rendering elsewhere (Blender's
/// Cycles, for one): the ground, the rigid blocks, the charges and gauges as they stand, and the
/// body's surface (`StructureSurface`) frame by frame. Units are metres, Z is up, and time codes
/// count frames. Each face of the body carries its element's damage and material as the
/// `damage` and `material` primvars; the material names are in `bombcad:materials`.
///
/// USD's text form keeps all the frames of one attribute together, so the frames are written to
/// a temporary file per attribute as they come and joined by `finish()`.
public final class USDSceneWriter {
    /// A view to render from: a USD camera with a 16:9 frame.
    public struct Camera: Sendable {
        public var eye: SIMD3<Float>
        public var target: SIMD3<Float>
        /// Radians.
        public var verticalFieldOfView: Float

        public init(eye: SIMD3<Float>, target: SIMD3<Float>, verticalFieldOfView: Float) {
            self.eye = eye
            self.target = target
            self.verticalFieldOfView = verticalFieldOfView
        }
    }

    public let url: URL
    private let camera: Camera?
    private let volumeFields: [String]
    private var volumes: [(frame: Int, path: String)] = []
    private var pointSets:
        [(
            name: String, frames: [[SIMD3<Float>]], widths: [Float], colour: SIMD3<Float>,
            values: [(name: String, values: [Float])]
        )] = []
    public let frameInterval: Double
    private let scenario: Scenario
    private let playbackRate: Double
    private let parts: URL
    private var streams: [String: FileHandle] = [:]
    private var frames = 0
    private var lastQuads: [Int32]?
    private var lastMaterial: [Int32]?
    private var lastObject: [Int32]?
    private var objectIDs: [UUID] = []
    private var objectNames: [String] = []
    private var lastRubble: [Bool]?
    private var lastDamage: [Float]?
    private var materials: [StructureSurface.Material] = []
    private var hasBody = false
    private var finished = false

    /// Frames appended so far.
    public var frameCount: Int { frames }

    /// - Parameters:
    ///   - frameInterval: simulated seconds between frames.
    ///   - playbackRate: frames per second when the scene is played back.
    public init(
        url: URL, scenario: Scenario, frameInterval: Double, playbackRate: Double = 24, camera: Camera? = nil,
        volumeFields: [String] = []
    ) throws {
        guard frameInterval > 0, frameInterval.isFinite, playbackRate > 0, playbackRate.isFinite else {
            throw CocoaError(
                .featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Invalid frame timing."])
        }
        self.url = url
        self.scenario = scenario
        self.frameInterval = frameInterval
        self.playbackRate = playbackRate
        self.camera = camera
        self.volumeFields = volumeFields
        parts = url.deletingLastPathComponent().appending(
            path: ".\(url.lastPathComponent).parts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: false)
        for name in ["points", "extent", "counts", "indices", "damage", "material", "rubble", "object"] {
            let file = parts.appending(path: name)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            streams[name] = try FileHandle(forWritingTo: file)
        }
    }

    deinit {
        if !finished { discard() }
    }

    /// Removes the partial output.
    public func discard() {
        for stream in streams.values { try? stream.close() }
        streams = [:]
        try? FileManager.default.removeItem(at: parts)
        finished = true
    }

    /// Adds the next frame, `frameInterval` after the last; `surface` is nil without a body, and
    /// `volume` the asset path of the frame's OpenVDB file, holding the grids named in
    /// `volumeFields`, if it has one.
    public func append(_ surface: StructureSurface?, volume: String? = nil) throws {
        defer { frames += 1 }
        if let volume { volumes.append((frames, volume)) }
        guard let surface else { return }
        hasBody = true
        materials = surface.materials
        objectIDs = surface.objectIDs
        objectNames = surface.objectNames
        let frame = "            \(frames): "
        var text = Text()

        text.append(frame + "[")
        for (n, point) in surface.points.enumerated() {
            if n > 0 { text.append(", ") }
            text.append(point)
        }
        text.append("],\n")
        try write(&text, to: "points")

        let low = surface.points.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
        let high = surface.points.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
        text.append(frame + "[")
        if surface.points.isEmpty {
            text.append("(0, 0, 0), (0, 0, 0)")
        } else {
            text.append(low)
            text.append(", ")
            text.append(high)
        }
        text.append("],\n")
        try write(&text, to: "extent")

        // Topology and materials change only as elements fail: write them only then.
        if surface.quads != lastQuads {
            text.append(frame + "[")
            text.appendList(repeatElement(4, count: surface.faceCount).map { $0 })
            text.append("],\n")
            try write(&text, to: "counts")
            text.append(frame + "[")
            text.appendList(surface.quads)
            text.append("],\n")
            try write(&text, to: "indices")
            lastQuads = surface.quads
        }
        if surface.material != lastMaterial {
            text.append(frame + "[")
            text.appendList(surface.material)
            text.append("],\n")
            try write(&text, to: "material")
            lastMaterial = surface.material
        }
        if surface.objectIDs.count > 1, surface.object != lastObject {
            text.append(frame + "[")
            text.appendList(surface.object)
            text.append("],\n")
            try write(&text, to: "object")
            lastObject = surface.object
        }
        if surface.rubble != lastRubble {
            text.append(frame + "[")
            text.append(surface.rubble.map { $0 ? "true" : "false" }.joined(separator: ", "))
            text.append("],\n")
            try write(&text, to: "rubble")
            lastRubble = surface.rubble
        }
        if surface.damage != lastDamage {
            text.append(frame + "[")
            for (n, value) in surface.damage.enumerated() {
                if n > 0 { text.append(", ") }
                text.append(value, decimals: 3)
            }
            text.append("],\n")
            try write(&text, to: "damage")
            lastDamage = surface.damage
        }
    }

    private func write(_ text: inout Text, to stream: String) throws {
        try streams[stream]!.write(contentsOf: text.bytes)
        text.bytes.removeAll(keepingCapacity: true)
    }

    /// Adds a set of points, such as fragments, with their positions at each frame from the first
    /// and their sizes; written with the rest by `finish()`.
    /// `values` are per-point numbers that do not change, as float primvars.
    public func addPoints(
        _ name: String, frames: [[SIMD3<Float>]], widths: [Float], colour: SIMD3<Float>,
        values: [(name: String, values: [Float])] = []
    ) {
        pointSets.append((name, frames, widths, colour, values))
    }

    /// Joins the parts into `url`, which must not exist yet.
    public func finish() throws {
        guard !finished else { return }
        defer { discard() }
        do {
            try assemble()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func assemble() throws {
        for stream in streams.values { try stream.close() }
        streams = [:]
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        var text = Text()
        func flush() throws {
            try output.write(contentsOf: text.bytes)
            text.bytes.removeAll(keepingCapacity: true)
        }
        func copy(_ name: String) throws {
            let input = try FileHandle(forReadingFrom: parts.appending(path: name))
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1 << 22), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
        }
        func timeSamples(_ declaration: String, _ name: String) throws {
            text.append("        \(declaration).timeSamples = {\n")
            try flush()
            try copy(name)
            text.append("        }\n")
        }

        let last = max(frames - 1, 0)
        text.append(
            """
            #usda 1.0
            (
                customLayerData = {
                    string creator = "BombCAD"
                    string scenario = \(quoted(scenario.name))
                    double simulatedSecondsPerFrame = \(frameInterval)
                }
                defaultPrim = "Scene"
                startTimeCode = 0
                endTimeCode = \(last)
                framesPerSecond = \(playbackRate)
                timeCodesPerSecond = \(playbackRate)
                metersPerUnit = 1
                upAxis = "Z"
            )

            def Xform "Scene"
            {

            """)
        let domain = scenario.domainSize
        appendMesh(
            "Ground", boxes: [],
            quad: [
                SIMD3(0, 0, 0), SIMD3(domain.x, 0, 0), SIMD3(domain.x, domain.y, 0), SIMD3(0, domain.y, 0),
            ],
            colour: SIMD3(0.46, 0.47, 0.49), to: &text)
        if !scenario.rigidBoxes.isEmpty {
            appendMesh(
                "Blocks", boxes: scenario.rigidBoxes, quad: [], colour: SIMD3(0.80, 0.79, 0.76), to: &text)
        }
        for (n, charge) in ([scenario.charge] + (scenario.additionalCharges ?? [])).enumerated() {
            appendSphere(
                n == 0 ? "Charge" : "Charge_\(n)", at: charge.position, radius: 0.45,
                colour: SIMD3(0.95, 0.15, 0.10),
                label: "\(charge.mass) kg TNT", to: &text)
        }
        for (n, gauge) in scenario.gauges.enumerated() {
            appendSphere(
                "Gauge_\(n)", at: gauge.position, radius: 0.35, colour: SIMD3(0.10, 0.80, 0.90),
                label: gauge.name,
                to: &text)
        }
        if let camera { appendCamera(camera, to: &text) }
        if !volumes.isEmpty, !volumeFields.isEmpty { appendVolume(to: &text) }
        for set in pointSets {
            appendPoints(set.name, set.frames, set.widths, set.colour, set.values, to: &text)
        }
        try flush()

        if hasBody {
            text.append(
                """
                    def Mesh "Structure"
                    {
                        uniform token subdivisionScheme = "none"
                        uniform token orientation = "rightHanded"
                        custom uniform string[] bombcad:materials = [\(materials.map { quoted($0.name) }.joined(separator: ", "))]
                        custom uniform bool[] bombcad:transparent = [\(materials.map { $0.isTransparent ? "true" : "false" }.joined(separator: ", "))]
                        float[] primvars:damage (
                            interpolation = "uniform"
                        )
                        int[] primvars:material (
                            interpolation = "uniform"
                        )
                        bool[] primvars:rubble (
                            interpolation = "uniform"
                        )

                """)
            if objectIDs.count > 1 {
                text.append(
                    "        custom uniform string[] bombcad:objectIds = ["
                        + objectIDs.map { quoted($0.uuidString) }.joined(separator: ", ") + "]\n")
                text.append(
                    "        custom uniform string[] bombcad:objectNames = ["
                        + objectNames.map(quoted).joined(separator: ", ") + "]\n")
                text.append("        int[] primvars:object (interpolation = \"uniform\")\n")
                try timeSamples("int[] primvars:object", "object")
            }
            try timeSamples("float3[] extent", "extent")
            try timeSamples("int[] faceVertexCounts", "counts")
            try timeSamples("int[] faceVertexIndices", "indices")
            try timeSamples("float[] primvars:damage", "damage")
            try timeSamples("int[] primvars:material", "material")
            try timeSamples("bool[] primvars:rubble", "rubble")
            try timeSamples("point3f[] points", "points")
            text.append("    }\n")
        }
        text.append("}\n")
        try flush()
    }

    private func appendMesh(
        _ name: String, boxes: [Box], quad: [SIMD3<Float>], colour: SIMD3<Float>, to text: inout Text
    ) {
        var surface = StructureSurface()
        if !quad.isEmpty {
            surface.points = quad
            surface.appendFace([0, 1, 2, 3], damage: 0, material: 0)
        }
        for box in boxes {
            let corners = (0..<8).map { bit -> SIMD3<Float> in
                SIMD3(
                    bit & 1 == 0 ? box.min.x : box.max.x, bit & 2 == 0 ? box.min.y : box.max.y,
                    bit & 4 == 0 ? box.min.z : box.max.z)
            }
            surface.appendBox(corners, faces: StructureSurface.bitCubeFaces, damage: 0, material: 0)
        }
        let low = surface.points.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
        let high = surface.points.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
        text.append("    def Mesh \"\(name)\"\n    {\n        uniform token subdivisionScheme = \"none\"\n")
        text.append("        float3[] extent = [")
        text.append(low)
        text.append(", ")
        text.append(high)
        text.append("]\n        int[] faceVertexCounts = [")
        text.appendList(repeatElement(Int32(4), count: surface.faceCount).map { $0 })
        text.append("]\n        int[] faceVertexIndices = [")
        text.appendList(surface.quads)
        text.append("]\n        point3f[] points = [")
        for (n, point) in surface.points.enumerated() {
            if n > 0 { text.append(", ") }
            text.append(point)
        }
        text.append("]\n        color3f[] primvars:displayColor = [")
        text.append(colour)
        text.append("]\n    }\n\n")
    }

    private func appendSphere(
        _ name: String, at position: SIMD3<Float>, radius: Float, colour: SIMD3<Float>, label: String,
        to text: inout Text
    ) {
        text.append("    def Sphere \"\(name)\"\n    {\n        double radius = ")
        text.append(radius, decimals: 3)
        text.append("\n        float3[] extent = [")
        text.append(SIMD3(repeating: -radius))
        text.append(", ")
        text.append(SIMD3(repeating: radius))
        text.append("]\n        double3 xformOp:translate = ")
        text.append(position)
        text.append(
            "\n        uniform token[] xformOpOrder = [\"xformOp:translate\"]\n        color3f[] primvars:displayColor = ["
        )
        text.append(colour)
        text.append("]\n        custom uniform string bombcad:label = \(quoted(label))\n    }\n\n")
    }

    private func appendPoints(
        _ name: String, _ frames: [[SIMD3<Float>]], _ widths: [Float], _ colour: SIMD3<Float>,
        _ values: [(name: String, values: [Float])], to text: inout Text
    ) {
        let all = frames.joined()
        let low = all.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
        let high = all.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
        text.append("    def Points \"\(name)\"\n    {\n        float3[] extent = [")
        text.append(all.isEmpty ? .zero : low)
        text.append(", ")
        text.append(all.isEmpty ? .zero : high)
        text.append("]\n        float[] widths = [")
        for (n, width) in widths.enumerated() {
            if n > 0 { text.append(", ") }
            text.append(width, decimals: 4)
        }
        text.append(
            "] (\n            interpolation = \"vertex\"\n        )\n        color3f[] primvars:displayColor = ["
        )
        text.append(colour)
        text.append("]\n")
        for (primvar, numbers) in values {
            text.append("        float[] primvars:\(primvar) = [")
            for (n, number) in numbers.enumerated() {
                if n > 0 { text.append(", ") }
                text.append(number, decimals: 3)
            }
            text.append("] (\n            interpolation = \"vertex\"\n        )\n")
        }
        text.append("        point3f[] points.timeSamples = {\n")
        for (frame, points) in frames.enumerated() {
            text.append("            \(frame): [")
            for (n, point) in points.enumerated() {
                if n > 0 { text.append(", ") }
                text.append(point)
            }
            text.append("],\n")
        }
        text.append("        }\n    }\n\n")
    }

    /// The air: a Volume whose fields read the frames' OpenVDB files.
    private func appendVolume(to text: inout Text) {
        let domain = scenario.domainSize
        text.append("    def Volume \"Blast\"\n    {\n        float3[] extent = [(0, 0, 0), ")
        text.append(domain)
        text.append("]\n")
        for field in volumeFields {
            text.append("        rel field:\(field) = </Scene/Blast/\(field)>\n")
        }
        for field in volumeFields {
            text.append(
                "\n        def OpenVDBAsset \"\(field)\"\n        {\n            token fieldName = \"\(field)\"\n"
            )
            text.append("            asset filePath.timeSamples = {\n")
            for (frame, path) in volumes {
                text.append("                \(frame): @\(path)@,\n")
            }
            text.append("            }\n        }\n")
        }
        text.append("    }\n\n")
    }

    /// USD cameras look down their local -Z with +Y up; the matrix's rows are the camera's axes
    /// and its position.
    private func appendCamera(_ camera: Camera, to text: inout Text) {
        let back = simd_normalize(camera.eye - camera.target)
        var right = simd_cross(SIMD3<Float>(0, 0, 1), back)
        right = simd_length(right) > 1e-6 ? simd_normalize(right) : SIMD3(1, 0, 0)
        let up = simd_cross(back, right)
        let horizontal: Float = 36
        let vertical = horizontal * 9 / 16
        let focal = vertical / (2 * tan(camera.verticalFieldOfView / 2))
        text.append("    def Camera \"Camera\"\n    {\n        float focalLength = ")
        text.append(focal, decimals: 3)
        text.append("\n        float horizontalAperture = 36\n        float verticalAperture = ")
        text.append(vertical, decimals: 3)
        text.append("\n        float2 clippingRange = (0.1, 5000)\n        matrix4d xformOp:transform = ( ")
        for (n, row) in [right, up, back, camera.eye].enumerated() {
            if n > 0 { text.append(", ") }
            text.append("(")
            text.append(row.x)
            text.append(", ")
            text.append(row.y)
            text.append(", ")
            text.append(row.z)
            text.append(n == 3 ? ", 1)" : ", 0)")
        }
        text.append(" )\n        uniform token[] xformOpOrder = [\"xformOp:transform\"]\n    }\n\n")
    }

    private func quoted(_ string: String) -> String {
        "\""
            + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

/// UTF-8 text with fast fixed-point numbers: a frame of a large body holds millions of them.
struct Text {
    var bytes: [UInt8] = []

    mutating func append(_ string: String) { bytes.append(contentsOf: string.utf8) }

    mutating func append(_ value: Float, decimals: Int = 4) {
        guard value.isFinite else {
            bytes.append(UInt8(ascii: "0"))
            return
        }
        var scale: Int64 = 1
        for _ in 0..<decimals { scale *= 10 }
        var fixed = Int64((Double(value) * Double(scale)).rounded())
        if fixed < 0 {
            bytes.append(UInt8(ascii: "-"))
            fixed = -fixed
        }
        appendDigits(fixed / scale)
        var fraction = fixed % scale
        guard fraction != 0 else { return }
        bytes.append(UInt8(ascii: "."))
        var digits = decimals
        while fraction % 10 == 0 {
            fraction /= 10
            digits -= 1
        }
        let start = bytes.count
        appendDigits(fraction)
        for _ in 0..<(digits - (bytes.count - start)) { bytes.insert(UInt8(ascii: "0"), at: start) }
    }

    mutating func append(_ point: SIMD3<Float>) {
        bytes.append(UInt8(ascii: "("))
        append(point.x)
        bytes.append(contentsOf: [UInt8(ascii: ","), UInt8(ascii: " ")])
        append(point.y)
        bytes.append(contentsOf: [UInt8(ascii: ","), UInt8(ascii: " ")])
        append(point.z)
        bytes.append(UInt8(ascii: ")"))
    }

    mutating func appendList(_ values: [Int32]) {
        for (n, value) in values.enumerated() {
            if n > 0 { bytes.append(contentsOf: [UInt8(ascii: ","), UInt8(ascii: " ")]) }
            if value < 0 { bytes.append(UInt8(ascii: "-")) }
            appendDigits(Int64(value.magnitude))
        }
    }

    private mutating func appendDigits(_ value: Int64) {
        guard value >= 10 else {
            bytes.append(UInt8(ascii: "0") + UInt8(value))
            return
        }
        appendDigits(value / 10)
        bytes.append(UInt8(ascii: "0") + UInt8(value % 10))
    }
}
