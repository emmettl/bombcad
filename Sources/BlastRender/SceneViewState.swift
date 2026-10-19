import BlastCore
import Foundation
import Metal

/// What `SceneRenderer` draws of a run at one moment, as the GPU resources it binds: the blast's
/// field and each structural body's mesh, in the layouts `Render.metal` reads.
///
/// A run on this Mac shares its solver's own buffers (`init(solver:)`), so drawing it copies
/// nothing. A run elsewhere fills buffers of the same layouts from what it sends (`ViewUpload`),
/// so the renderer draws either without holding a solver.
public struct SceneViewState {
    /// The blast's field: a 3D `rgba16Float` texture over the whole domain, as
    /// `BlastSolver.visualizationTexture`. The shaders sample it by position, so it may be coarser
    /// than the solver's grid.
    public var field: MTLTexture
    /// The edge of one of the field's cells, in metres, which the shaders step by half of to
    /// sample the air beside a surface.
    public var fieldCellSize: Float
    public var bodies: [Body]

    public init(field: MTLTexture, fieldCellSize: Float, bodies: [Body]) {
        self.field = field
        self.fieldCellSize = fieldCellSize
        self.bodies = bodies
    }

    /// A structural body's solid elements, shells and beams; a mixed body has both.
    public struct Body {
        public var solids: Solids?
        public var shells: Shells?

        public init(solids: Solids?, shells: Shells?) {
            self.solids = solids
            self.shells = shells
        }
    }

    /// Solid elements on their lattice, in `StructureSolver`'s layouts.
    public struct Solids {
        /// The lattice's low corner, its cell edge and its cells along each axis.
        public var origin: SIMD3<Float>
        public var elementSize: Float
        public var ex: Int
        public var ey: Int
        public var ez: Int
        /// Elements the body started with, each drawn as an instance.
        public var elementCount: Int
        /// The lattice index of each, one `UInt32` each.
        public var instances: MTLBuffer
        /// Compact nodes as `StructureNode`; only the displacement is read.
        public var nodes: MTLBuffer
        /// For every lattice node, its index in `nodes`, or `UInt32.max` where there is none.
        public var nodeMap: MTLBuffer
        /// One byte for every lattice cell: 1 for a sound element, 2 for a failed one, drawn as
        /// rubble, and 0 for none.
        public var flags: MTLBuffer
        /// Each element's state, `stateStride` bytes apart; only its eighth float, the damage, is
        /// read.
        public var states: MTLBuffer
        public var stateStride: Int
        /// Each element's material, one byte each in the instances' order, its low four bits an
        /// index into `palette` (`StructureSolver.materialIndexBuffer`); nil draws every element
        /// in the palette's first colour.
        public var materialIndex: MTLBuffer?
        /// The materials' colours (`MaterialAppearance.palette`).
        public var palette: [SIMD4<Float>]

        public init(
            origin: SIMD3<Float>, elementSize: Float, ex: Int, ey: Int, ez: Int, elementCount: Int,
            instances: MTLBuffer, nodes: MTLBuffer, nodeMap: MTLBuffer, flags: MTLBuffer, states: MTLBuffer,
            stateStride: Int, materialIndex: MTLBuffer? = nil,
            palette: [SIMD4<Float>] = MaterialAppearance.palette([])
        ) {
            self.origin = origin
            self.elementSize = elementSize
            self.ex = ex
            self.ey = ey
            self.ez = ez
            self.elementCount = elementCount
            self.instances = instances
            self.nodes = nodes
            self.nodeMap = nodeMap
            self.flags = flags
            self.states = states
            self.stateStride = stateStride
            self.materialIndex = materialIndex
            self.palette = palette
        }
    }

    /// Shell and beam elements, in `ShellSolver`'s layouts.
    public struct Shells {
        public var elementCount: Int
        public var beamCount: Int
        /// As `ShellMeshElement` and `BeamMeshElement` in `Render.metal`.
        public var elements: MTLBuffer
        public var beams: MTLBuffer
        /// Nodes as `ShellNode`; only the displacement and the rotation are read.
        public var nodes: MTLBuffer
        /// Every node's reference position, as four floats.
        public var reference: MTLBuffer
        /// One byte for each element and each beam: 1 or 3 drawn whole, 0 not at all, otherwise
        /// as rubble.
        public var flags: MTLBuffer
        public var beamFlags: MTLBuffer
        /// Damage from 0 (sound) to 1 (failing), one float for each element and each beam.
        public var damage: MTLBuffer
        public var beamDamage: MTLBuffer
        /// Bit n set where material n, of the first 32, is transparent, and drawn as glass.
        public var transparentMaterials: UInt32
        /// The materials' colours, by the elements' and beams' material index
        /// (`MaterialAppearance.palette`).
        public var palette: [SIMD4<Float>]

        public init(
            elementCount: Int, beamCount: Int, elements: MTLBuffer, beams: MTLBuffer, nodes: MTLBuffer,
            reference: MTLBuffer, flags: MTLBuffer, beamFlags: MTLBuffer, damage: MTLBuffer,
            beamDamage: MTLBuffer, transparentMaterials: UInt32,
            palette: [SIMD4<Float>] = MaterialAppearance.palette([])
        ) {
            self.elementCount = elementCount
            self.beamCount = beamCount
            self.elements = elements
            self.beams = beams
            self.nodes = nodes
            self.reference = reference
            self.flags = flags
            self.beamFlags = beamFlags
            self.damage = damage
            self.beamDamage = beamDamage
            self.transparentMaterials = transparentMaterials
            self.palette = palette
        }

        /// The materials drawn as glass, as `transparentMaterials`.
        public static func transparentMask(_ materials: [StructureMaterial]) -> UInt32 {
            var mask: UInt32 = 0
            for (n, material) in materials.enumerated() where material.isTransparent && n < 32 {
                mask |= 1 << UInt32(n)
            }
            return mask
        }
    }
}

extension SceneViewState {
    /// A run on this Mac, drawn straight from its solver's buffers.
    public init(solver: BlastSolver) {
        self.init(
            field: solver.visualizationTexture, fieldCellSize: solver.grid.cellSize,
            bodies: solver.bodies.map { body in
                Body(
                    solids: body.solids.map { structure in
                        Solids(
                            origin: structure.origin, elementSize: structure.model.elementSize,
                            ex: structure.ex,
                            ey: structure.ey, ez: structure.ez, elementCount: structure.elementCount,
                            instances: structure.instanceBuffer, nodes: structure.nodeBuffer,
                            nodeMap: structure.nodeMapBuffer, flags: structure.flagBuffer,
                            states: structure.stateBuffer, stateStride: StructureSolver.stateStride,
                            materialIndex: structure.materialIndexBuffer,
                            palette: MaterialAppearance.palette(structure.materials))
                    },
                    shells: body.shells.map { shells in
                        Shells(
                            elementCount: shells.elementCount, beamCount: shells.beamCount,
                            elements: shells.elementBuffer, beams: shells.beamBuffer,
                            nodes: shells.nodeBuffer,
                            reference: shells.referenceBuffer, flags: shells.flagBuffer,
                            beamFlags: shells.beamFlagBuffer, damage: shells.displayBuffer,
                            beamDamage: shells.beamDisplayBuffer,
                            transparentMaterials: Shells.transparentMask(shells.materials),
                            palette: MaterialAppearance.palette(shells.materials))
                    })
            })
    }
}

// MARK: - A run elsewhere

/// What a run elsewhere sends once, when it starts, for its view: what of the field and the
/// bodies does not change from frame to frame. Each frame then sends a `ViewFrame`.
public struct ViewSetup: Sendable, Equatable {
    /// The field's texels along each axis, and the edge of one, in metres.
    public var fieldSize: SIMD3<Int>
    public var fieldCellSize: Float
    public var bodies: [Body]

    public init(fieldSize: SIMD3<Int>, fieldCellSize: Float, bodies: [Body]) {
        self.fieldSize = fieldSize
        self.fieldCellSize = fieldCellSize
        self.bodies = bodies
    }

    public struct Body: Sendable, Equatable {
        public var solids: Solids?
        public var shells: Shells?

        public init(solids: Solids?, shells: Shells?) {
            self.solids = solids
            self.shells = shells
        }
    }

    public struct Solids: Sendable, Equatable {
        public var origin: SIMD3<Float>
        public var elementSize: Float
        public var ex: Int
        public var ey: Int
        public var ez: Int
        /// The lattice index of each initial element.
        public var instances: [UInt32]
        /// For every lattice node, its index among the frames' displacements, or `UInt32.max`.
        public var nodeMap: [UInt32]
        public var nodeCount: Int
        /// Each initial element's material byte, and the materials' colours
        /// (`SceneViewState.Solids`); empty from a sender before them, drawn in one colour.
        public var materialIndex: [UInt8]
        public var palette: [SIMD4<Float>]

        public init(
            origin: SIMD3<Float>, elementSize: Float, ex: Int, ey: Int, ez: Int, instances: [UInt32],
            nodeMap: [UInt32], nodeCount: Int, materialIndex: [UInt8] = [], palette: [SIMD4<Float>] = []
        ) {
            self.origin = origin
            self.elementSize = elementSize
            self.ex = ex
            self.ey = ey
            self.ez = ez
            self.instances = instances
            self.nodeMap = nodeMap
            self.nodeCount = nodeCount
            self.materialIndex = materialIndex
            self.palette = palette
        }
    }

    public struct Shells: Sendable, Equatable {
        /// The elements' and the beams' bytes as the solver holds them (`ShellMeshElement` and
        /// `BeamMeshElement` in `Render.metal`), and how many of each.
        public var elements: Data
        public var elementCount: Int
        public var beams: Data
        public var beamCount: Int
        /// Every node's reference position; `w` is unread.
        public var reference: [SIMD4<Float>]
        public var transparentMaterials: UInt32
        /// The materials' colours; empty from a sender before them.
        public var palette: [SIMD4<Float>]

        public init(
            elements: Data, elementCount: Int, beams: Data, beamCount: Int, reference: [SIMD4<Float>],
            transparentMaterials: UInt32, palette: [SIMD4<Float>] = []
        ) {
            self.elements = elements
            self.elementCount = elementCount
            self.beams = beams
            self.beamCount = beamCount
            self.reference = reference
            self.transparentMaterials = transparentMaterials
            self.palette = palette
        }
    }
}

/// One frame of a run elsewhere: only what the renderer reads that changes, the field and the
/// bodies' motion and damage, in the order of its `ViewSetup`.
///
/// Frames for display are lossy and may be dropped: none of this feeds back into a run or a
/// result.
public struct ViewFrame: Sendable, Equatable {
    /// The run's simulated time, in seconds.
    public var time: Double
    /// The field's texels as `rgba16Float`, eight bytes each, x fastest, then y, then z.
    public var field: Data
    public var bodies: [Body]

    public init(time: Double, field: Data, bodies: [Body]) {
        self.time = time
        self.field = field
        self.bodies = bodies
    }

    public struct Body: Sendable, Equatable {
        public var solids: Solids?
        public var shells: Shells?

        public init(solids: Solids?, shells: Shells?) {
            self.solids = solids
            self.shells = shells
        }
    }

    public struct Solids: Sendable, Equatable {
        /// Each node's displacement, one per `ViewSetup.Solids.nodeCount`.
        public var displacements: [SIMD3<Float>]
        /// One for every lattice cell, as `SceneViewState.Solids.flags`.
        public var flags: [UInt8]
        /// One for each initial element.
        public var damage: [Float]

        public init(displacements: [SIMD3<Float>], flags: [UInt8], damage: [Float]) {
            self.displacements = displacements
            self.flags = flags
            self.damage = damage
        }
    }

    public struct Shells: Sendable, Equatable {
        /// Each node's displacement and rotation from its reference, one per reference position.
        public var displacements: [SIMD3<Float>]
        public var rotations: [SIMD4<Float>]
        public var flags: [UInt8]
        public var beamFlags: [UInt8]
        public var damage: [Float]
        public var beamDamage: [Float]

        public init(
            displacements: [SIMD3<Float>], rotations: [SIMD4<Float>], flags: [UInt8], beamFlags: [UInt8],
            damage: [Float], beamDamage: [Float]
        ) {
            self.displacements = displacements
            self.rotations = rotations
            self.flags = flags
            self.beamFlags = beamFlags
            self.damage = damage
            self.beamDamage = beamDamage
        }
    }
}

extension ViewSetup {
    /// What a run's view needs once, read from its solver, the field `fieldStride` times coarser
    /// than the solver's grid along each axis (see `BlastSolver.viewField(stride:)`).
    public init(solver: BlastSolver, fieldStride: Int = 1) {
        let grid = solver.grid
        self.init(
            fieldSize: solver.viewFieldSize(stride: fieldStride),
            fieldCellSize: grid.cellSize * Float(fieldStride),
            bodies: solver.bodies.map { body in
                Body(
                    solids: body.solids.map { structure in
                        let nodes = (structure.ex + 1) * (structure.ey + 1) * (structure.ez + 1)
                        return Solids(
                            origin: structure.origin, elementSize: structure.model.elementSize,
                            ex: structure.ex,
                            ey: structure.ey, ez: structure.ez,
                            instances: ViewFrame.read(structure.instanceBuffer, structure.elementCount),
                            nodeMap: ViewFrame.read(structure.nodeMapBuffer, nodes),
                            nodeCount: structure.nodeCount,
                            materialIndex: ViewFrame.read(
                                structure.materialIndexBuffer, structure.elementCount),
                            palette: MaterialAppearance.palette(structure.materials))
                    },
                    shells: body.shells.map { shells in
                        let nodes =
                            shells.elementCount + shells.beamCount == 0
                            ? 0 : shells.referenceBuffer.length / MemoryLayout<SIMD4<Float>>.stride
                        func bytes(_ buffer: MTLBuffer, _ count: Int) -> Data {
                            count == 0 ? Data() : Data(bytes: buffer.contents(), count: buffer.length)
                        }
                        return Shells(
                            elements: bytes(shells.elementBuffer, shells.elementCount),
                            elementCount: shells.elementCount,
                            beams: bytes(shells.beamBuffer, shells.beamCount),
                            beamCount: shells.beamCount,
                            reference: ViewFrame.read(shells.referenceBuffer, nodes),
                            transparentMaterials: SceneViewState.Shells.transparentMask(shells.materials),
                            palette: MaterialAppearance.palette(shells.materials))
                    })
            })
    }
}

extension ViewFrame {
    /// The run's view now, read from its solver at full resolution; between batches, as
    /// `BlastSolver.refreshVisualization`, which this calls.
    public init(solver: BlastSolver) throws {
        self.init(solver: solver, field: try solver.viewField(stride: 1))
    }

    /// The run's view now with `field` read already, as `BlastSolver.viewField(stride:)` reads it.
    public init(solver: BlastSolver, field: Data) {
        self.init(
            time: solver.time, field: field,
            bodies: solver.bodies.map { body in
                Body(
                    solids: body.solids.map { structure in
                        let nodes: [StructureNode] = Self.read(structure.nodeBuffer, structure.nodeCount)
                        let floats = StructureSolver.stateStride / MemoryLayout<Float>.stride
                        let states: [Float] = Self.read(
                            structure.stateBuffer, structure.elementCount * floats)
                        return Solids(
                            displacements: nodes.map(\.displacement),
                            flags: Self.read(
                                structure.flagBuffer, structure.ex * structure.ey * structure.ez),
                            damage: (0..<structure.elementCount).map { states[$0 * floats + 7] })
                    },
                    shells: body.shells.map { shells in
                        let count =
                            shells.elementCount + shells.beamCount == 0
                            ? 0 : shells.referenceBuffer.length / MemoryLayout<SIMD4<Float>>.stride
                        let nodes: [ShellNode] = Self.read(shells.nodeBuffer, count)
                        return Shells(
                            displacements: nodes.map(\.displacement),
                            rotations: nodes.map { SIMD4($0.qx, $0.qy, $0.qz, $0.qw) },
                            flags: Self.read(shells.flagBuffer, shells.elementCount),
                            beamFlags: Self.read(shells.beamFlagBuffer, shells.beamCount),
                            damage: Self.read(shells.displayBuffer, shells.elementCount),
                            beamDamage: Self.read(shells.beamDisplayBuffer, shells.beamCount))
                    })
            })
    }

    /// The first `count` values of a shared buffer.
    static func read<T>(_ buffer: MTLBuffer, _ count: Int) -> [T] {
        guard count > 0 else { return [] }
        precondition(count * MemoryLayout<T>.stride <= buffer.length, "\(buffer.label ?? "buffer") too short")
        return Array(
            UnsafeBufferPointer(
                start: buffer.contents().bindMemory(to: T.self, capacity: count), count: count))
    }
}

public enum ViewUploadError: Error, Equatable {
    /// A frame's or a setup's part is not the size its setup says.
    case mismatched(String)
}

/// A run elsewhere's view on this Mac: buffers of its own, laid out as the solver's, made from a
/// `ViewSetup` and brought up to date by each `ViewFrame`.
///
/// `apply` writes into buffers the GPU reads, so it is called only once the frames drawn from the
/// previous one have finished.
public final class ViewUpload {
    public private(set) var view: SceneViewState
    public private(set) var time: Double = 0
    private let setup: ViewSetup

    /// Each element's state as written here: the damage in the eighth of eight floats.
    private static let solidStateStride = 8 * MemoryLayout<Float>.stride

    public init(device: MTLDevice, setup: ViewSetup) throws {
        self.setup = setup
        // Never empty, since Metal makes no buffer of no length; a body without beams binds one
        // all the same.
        func empty(_ length: Int, _ name: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
                throw BlastError.allocationFailed(name)
            }
            buffer.label = name
            return buffer
        }
        func filled<T>(_ values: [T], _ name: String) throws -> MTLBuffer {
            let buffer = try empty(values.count * MemoryLayout<T>.stride, name)
            Self.copy(values, into: buffer)
            return buffer
        }
        func raw(_ data: Data, _ name: String) throws -> MTLBuffer {
            let buffer = try empty(data.count, name)
            data.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress {
                    buffer.contents().copyMemory(from: base, byteCount: bytes.count)
                }
            }
            return buffer
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = setup.fieldSize.x
        descriptor.height = setup.fieldSize.y
        descriptor.depth = setup.fieldSize.z
        descriptor.usage = .shaderRead
        guard let field = device.makeTexture(descriptor: descriptor) else {
            throw BlastError.allocationFailed("view field")
        }
        field.label = "view field"

        let bodies = try setup.bodies.map { body in
            SceneViewState.Body(
                solids: try body.solids.map { solids in
                    let cells = solids.ex * solids.ey * solids.ez
                    let nodes = (solids.ex + 1) * (solids.ey + 1) * (solids.ez + 1)
                    guard solids.nodeMap.count == nodes else {
                        throw ViewUploadError.mismatched("solid node map")
                    }
                    return SceneViewState.Solids(
                        origin: solids.origin, elementSize: solids.elementSize, ex: solids.ex, ey: solids.ey,
                        ez: solids.ez, elementCount: solids.instances.count,
                        instances: try filled(solids.instances, "view solid instances"),
                        nodes: try empty(
                            solids.nodeCount * MemoryLayout<StructureNode>.stride, "view solid nodes"),
                        nodeMap: try filled(solids.nodeMap, "view solid node map"),
                        flags: try empty(cells, "view solid flags"),
                        states: try empty(
                            solids.instances.count * Self.solidStateStride, "view solid damage"),
                        stateStride: Self.solidStateStride,
                        materialIndex: solids.materialIndex.count == solids.instances.count
                            && !solids.materialIndex.isEmpty
                            ? try filled(solids.materialIndex, "view solid materials") : nil,
                        palette: solids.palette.isEmpty ? MaterialAppearance.palette([]) : solids.palette)
                },
                shells: try body.shells.map { shells in
                    guard shells.elementCount == 0 || shells.elements.count % shells.elementCount == 0,
                        shells.beamCount == 0 || shells.beams.count % shells.beamCount == 0
                    else { throw ViewUploadError.mismatched("shell elements") }
                    return SceneViewState.Shells(
                        elementCount: shells.elementCount, beamCount: shells.beamCount,
                        elements: try raw(shells.elements, "view shell elements"),
                        beams: try raw(shells.beams, "view beams"),
                        nodes: try empty(
                            shells.reference.count * MemoryLayout<ShellNode>.stride, "view shell nodes"),
                        reference: try filled(shells.reference, "view shell reference"),
                        flags: try empty(shells.elementCount, "view shell flags"),
                        beamFlags: try empty(shells.beamCount, "view beam flags"),
                        damage: try empty(shells.elementCount * 4, "view shell damage"),
                        beamDamage: try empty(shells.beamCount * 4, "view beam damage"),
                        transparentMaterials: shells.transparentMaterials,
                        palette: shells.palette.isEmpty ? MaterialAppearance.palette([]) : shells.palette)
                })
        }
        view = SceneViewState(field: field, fieldCellSize: setup.fieldCellSize, bodies: bodies)
    }

    /// Brings the view up to `frame`, after checking every part of it is the size the setup says,
    /// so a bad frame changes nothing.
    public func apply(_ frame: ViewFrame) throws {
        let size = setup.fieldSize
        guard frame.field.count == size.x * size.y * size.z * 8 else {
            throw ViewUploadError.mismatched("field")
        }
        guard frame.bodies.count == setup.bodies.count else { throw ViewUploadError.mismatched("bodies") }
        for (body, sent) in zip(setup.bodies, frame.bodies) {
            switch (body.solids, sent.solids) {
            case (nil, nil): break
            case (let solids?, let sent?):
                guard sent.displacements.count == solids.nodeCount,
                    sent.flags.count == solids.ex * solids.ey * solids.ez,
                    sent.damage.count == solids.instances.count
                else { throw ViewUploadError.mismatched("solids") }
            default: throw ViewUploadError.mismatched("solids")
            }
            switch (body.shells, sent.shells) {
            case (nil, nil): break
            case (let shells?, let sent?):
                guard sent.displacements.count == shells.reference.count,
                    sent.rotations.count == shells.reference.count,
                    sent.flags.count == shells.elementCount, sent.damage.count == shells.elementCount,
                    sent.beamFlags.count == shells.beamCount, sent.beamDamage.count == shells.beamCount
                else { throw ViewUploadError.mismatched("shells") }
            default: throw ViewUploadError.mismatched("shells")
            }
        }

        frame.field.withUnsafeBytes { texels in
            view.field.replace(
                region: MTLRegionMake3D(0, 0, 0, size.x, size.y, size.z), mipmapLevel: 0, slice: 0,
                withBytes: texels.baseAddress!, bytesPerRow: size.x * 8, bytesPerImage: size.x * size.y * 8)
        }
        for (body, sent) in zip(view.bodies, frame.bodies) {
            if let solids = body.solids, let sent = sent.solids {
                let nodes = solids.nodes.contents()
                for (n, displacement) in sent.displacements.enumerated() {
                    var node = StructureNode()
                    node.displacement = displacement
                    nodes.storeBytes(
                        of: node, toByteOffset: n * MemoryLayout<StructureNode>.stride, as: StructureNode.self
                    )
                }
                Self.copy(sent.flags, into: solids.flags)
                let states = solids.states.contents().assumingMemoryBound(to: Float.self)
                let floats = solids.stateStride / MemoryLayout<Float>.stride
                for (n, damage) in sent.damage.enumerated() {
                    states[n * floats + 7] = damage
                }
            }
            if let shells = body.shells, let sent = sent.shells {
                let nodes = shells.nodes.contents()
                for n in sent.displacements.indices {
                    var node = ShellNode()
                    node.displacement = sent.displacements[n]
                    let q = sent.rotations[n]
                    node.qx = q.x
                    node.qy = q.y
                    node.qz = q.z
                    node.qw = q.w
                    nodes.storeBytes(
                        of: node, toByteOffset: n * MemoryLayout<ShellNode>.stride, as: ShellNode.self)
                }
                Self.copy(sent.flags, into: shells.flags)
                Self.copy(sent.beamFlags, into: shells.beamFlags)
                Self.copy(sent.damage, into: shells.damage)
                Self.copy(sent.beamDamage, into: shells.beamDamage)
            }
        }
        time = frame.time
    }

    private static func copy<T>(_ values: [T], into buffer: MTLBuffer) {
        values.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            buffer.contents().copyMemory(from: base, byteCount: bytes.count)
        }
    }
}
