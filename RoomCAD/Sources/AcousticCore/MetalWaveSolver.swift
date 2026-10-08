import Foundation
import Metal
import simd

/// The wave solver's scheme on the GPU: the same staggered grid, walls and sampling as the CPU solver,
/// for boxes and floor plans alike, with each cell's boundary faces precomputed.
final class MetalWaveSolver: @unchecked Sendable {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let velocity: MTLComputePipelineState
    private let pressure: MTLComputePipelineState
    private let inject: MTLComputePipelineState
    private let sample: MTLComputePipelineState

    /// The system's GPU, or nil if there is none or its kernels do not compile.
    static let shared: MetalWaveSolver? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return try? MetalWaveSolver(device: device)
    }()

    /// Steps encoded per command buffer; cancellation is checked between buffers.
    static let stepsPerBuffer = 128

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw AcousticError.invalid("No GPU command queue.")
        }
        self.queue = queue
        let library = try device.makeLibrary(source: Self.source, options: nil)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw AcousticError.invalid("Missing GPU function \(name).")
            }
            return try device.makeComputePipelineState(function: function)
        }
        velocity = try pipeline("waveVelocity")
        pressure = try pipeline("wavePressure")
        inject = try pipeline("waveInject")
        sample = try pipeline("waveSample")
    }

    struct Grid {
        var nx, ny, nz: UInt32
        var kx, ky, kz: Float
        var bx, by, bz: Float
    }

    /// Simulates like `WaveSolver.simulate`, returning each receiver's microphone output after each step,
    /// or nil if `stop` asks it to, `abandon` gives up on it, or the GPU fails. Between command buffers,
    /// `abandon` is passed the steps done and the seconds taken so far.
    func simulate(
        _ solver: WaveSolver, source: SIMD3<Double>,
        receivers: [(position: SIMD3<Double>, microphone: Microphone)],
        steps: Int, stop: @Sendable () -> Bool,
        abandon: (_ done: Int, _ elapsed: TimeInterval) -> Bool = { _, _ in false }
    ) -> [[Double]]? {
        let started = Date()
        let layout = solver.gridLayout(source: source, receivers: receivers)
        let count = layout.count
        let c = solver.atmosphere.soundSpeed
        let dt = solver.timeStep
        let spacing = solver.spacing
        var grid = Grid(
            nx: UInt32(solver.cells.x), ny: UInt32(solver.cells.y), nz: UInt32(solver.cells.z),
            kx: Float(dt / spacing.x), ky: Float(dt / spacing.y), kz: Float(dt / spacing.z),
            bx: Float(c * c * dt / spacing.x), by: Float(c * c * dt / spacing.y),
            bz: Float(c * c * dt / spacing.z))
        func buffer<T>(_ values: [T]) -> MTLBuffer? {
            values.withUnsafeBytes {
                device.makeBuffer(
                    bytes: $0.baseAddress!, length: max($0.count, 4), options: .storageModeShared)
            }
        }
        func zeros(_ floats: Int) -> MTLBuffer? {
            let buffer = device.makeBuffer(length: max(floats, 1) * 4, options: .storageModeShared)
            if let buffer { memset(buffer.contents(), 0, buffer.length) }
            return buffer
        }
        let pulse = (0..<steps).map { Float(solver.pulse((Double($0) + 0.5) * dt)) }
        guard let p = zeros(count), let ux = zeros(count), let uy = zeros(count), let uz = zeros(count),
            let inside = buffer(layout.inside), let faces = buffer(layout.faces), let q = buffer(pulse),
            let sourceCells = buffer(layout.sourceCells.map(UInt32.init)),
            let sourceWeights = buffer(layout.sourceWeights),
            let receiverCells = buffer(layout.receiverCells.map(UInt32.init)),
            let receiverWeights = buffer(layout.receiverWeights),
            let velocityCells = buffer(layout.velocityCells.map(UInt32.init)), let axes = buffer(layout.axes),
            let output = zeros(receivers.count * steps),
            let velocityOutput = zeros(receivers.count * (steps + 1))
        else { return nil }

        let threads = MTLSize(width: Int(grid.nx), height: Int(grid.ny), depth: Int(grid.nz))
        let group = MTLSize(width: 32, height: 4, depth: 2)
        var sourceCount = UInt32(layout.sourceCells.count)
        var receiverCount = UInt32(receivers.count)
        var totalSteps = UInt32(steps)
        var start = 0
        while start < steps {
            if stop() { return nil }
            guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder()
            else {
                return nil
            }
            for n in start..<min(start + Self.stepsPerBuffer, steps) {
                var step = UInt32(n)
                encoder.setComputePipelineState(velocity)
                encoder.setBuffer(p, offset: 0, index: 0)
                encoder.setBuffer(ux, offset: 0, index: 1)
                encoder.setBuffer(uy, offset: 0, index: 2)
                encoder.setBuffer(uz, offset: 0, index: 3)
                encoder.setBuffer(inside, offset: 0, index: 4)
                encoder.setBytes(&grid, length: MemoryLayout<Grid>.stride, index: 5)
                encoder.dispatchThreads(threads, threadsPerThreadgroup: group)

                encoder.setComputePipelineState(pressure)
                encoder.setBuffer(faces, offset: 0, index: 5)
                encoder.setBytes(&grid, length: MemoryLayout<Grid>.stride, index: 6)
                encoder.dispatchThreads(threads, threadsPerThreadgroup: group)

                encoder.setComputePipelineState(inject)
                encoder.setBuffer(p, offset: 0, index: 0)
                encoder.setBuffer(q, offset: 0, index: 1)
                encoder.setBuffer(sourceCells, offset: 0, index: 2)
                encoder.setBuffer(sourceWeights, offset: 0, index: 3)
                encoder.setBytes(&step, length: 4, index: 4)
                encoder.setBytes(&sourceCount, length: 4, index: 5)
                encoder.dispatchThreads(
                    MTLSize(width: layout.sourceCells.count, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 8, height: 1, depth: 1))

                encoder.setComputePipelineState(sample)
                encoder.setBuffer(p, offset: 0, index: 0)
                encoder.setBuffer(ux, offset: 0, index: 1)
                encoder.setBuffer(uy, offset: 0, index: 2)
                encoder.setBuffer(uz, offset: 0, index: 3)
                encoder.setBuffer(receiverCells, offset: 0, index: 4)
                encoder.setBuffer(receiverWeights, offset: 0, index: 5)
                encoder.setBuffer(velocityCells, offset: 0, index: 6)
                encoder.setBuffer(axes, offset: 0, index: 7)
                encoder.setBuffer(output, offset: 0, index: 8)
                encoder.setBuffer(velocityOutput, offset: 0, index: 9)
                encoder.setBytes(&grid, length: MemoryLayout<Grid>.stride, index: 10)
                encoder.setBytes(&step, length: 4, index: 11)
                encoder.setBytes(&totalSteps, length: 4, index: 12)
                encoder.setBytes(&receiverCount, length: 4, index: 13)
                encoder.dispatchThreads(
                    MTLSize(width: receivers.count, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            }
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            guard commands.status == .completed else { return nil }
            if solver.gpuDelay > 0 { Thread.sleep(forTimeInterval: solver.gpuDelay) }
            start += Self.stepsPerBuffer
            if start < steps, abandon(start, Date().timeIntervalSince(started)) { return nil }
        }

        let pressures = output.contents().bindMemory(to: Float.self, capacity: receivers.count * steps)
        let velocities = velocityOutput.contents().bindMemory(
            to: Float.self, capacity: receivers.count * (steps + 1))
        return receivers.indices.map { r in
            let microphone = receivers[r].microphone
            let pressure = (0..<steps).map { Double(pressures[r * steps + $0]) }
            guard !microphone.isOmni else { return pressure }
            let a = microphone.pattern.omniShare
            let v = { (n: Int) in Double(velocities[r * (steps + 1) + n]) }
            return (0..<steps).map { n in
                let average = n + 2 <= steps ? (v(n + 1) + v(n + 2)) / 2 : v(n + 1)
                return a * pressure[n] - (1 - a) * c * average
            }
        }
    }

    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct Grid { uint nx, ny, nz; float kx, ky, kz; float bx, by, bz; };

        // Velocity on faces between two simulated cells; others stay zero and are walls.
        kernel void waveVelocity(device const float* p [[buffer(0)]], device float* ux [[buffer(1)]],
                                 device float* uy [[buffer(2)]], device float* uz [[buffer(3)]],
                                 device const uchar* inside [[buffer(4)]], constant Grid& g [[buffer(5)]],
                                 uint3 id [[thread_position_in_grid]]) {
            if (id.x >= g.nx || id.y >= g.ny || id.z >= g.nz) return;
            uint plane = g.nx * g.ny;
            uint at = id.x + g.nx * id.y + plane * id.z;
            if (!inside[at]) return;
            float here = p[at];
            if (id.x + 1 < g.nx && inside[at + 1]) ux[at] -= g.kx * (p[at + 1] - here);
            if (id.y + 1 < g.ny && inside[at + g.nx]) uy[at] -= g.ky * (p[at + g.nx] - here);
            if (id.z + 1 < g.nz && inside[at + plane]) uz[at] -= g.kz * (p[at + plane] - here);
        }

        // Pressure from the divergence, with each boundary face's semi-implicit wall term; a face value
        // below zero means a neighbour.
        kernel void wavePressure(device float* p [[buffer(0)]], device const float* ux [[buffer(1)]],
                                 device const float* uy [[buffer(2)]], device const float* uz [[buffer(3)]],
                                 device const uchar* inside [[buffer(4)]], device const float* faces [[buffer(5)]],
                                 constant Grid& g [[buffer(6)]], uint3 id [[thread_position_in_grid]]) {
            if (id.x >= g.nx || id.y >= g.ny || id.z >= g.nz) return;
            uint plane = g.nx * g.ny;
            uint count = plane * g.nz;
            uint at = id.x + g.nx * id.y + plane * id.z;
            if (!inside[at]) return;
            float divergence = 0;
            float wall = 0;
            float f;
            f = faces[at];             if (f < 0) divergence -= g.bx * ux[at - 1];     else wall += f;
            f = faces[count + at];     if (f < 0) divergence += g.bx * ux[at];         else wall += f;
            f = faces[2 * count + at]; if (f < 0) divergence -= g.by * uy[at - g.nx];  else wall += f;
            f = faces[3 * count + at]; if (f < 0) divergence += g.by * uy[at];         else wall += f;
            f = faces[4 * count + at]; if (f < 0) divergence -= g.bz * uz[at - plane]; else wall += f;
            f = faces[5 * count + at]; if (f < 0) divergence += g.bz * uz[at];         else wall += f;
            p[at] = ((1 - wall) * p[at] - divergence) / (1 + wall);
        }

        // Volume velocity at the source, weights already scaled by c² dt / V.
        kernel void waveInject(device float* p [[buffer(0)]], device const float* q [[buffer(1)]],
                               device const uint* cells [[buffer(2)]], device const float* weights [[buffer(3)]],
                               constant uint& step [[buffer(4)]], constant uint& count [[buffer(5)]],
                               uint i [[thread_position_in_grid]]) {
            if (i >= count) return;
            p[cells[i]] += q[step] * weights[i];
        }

        // Pressure at each receiver, and velocity along its microphone's axis at its cell.
        kernel void waveSample(device const float* p [[buffer(0)]], device const float* ux [[buffer(1)]],
                               device const float* uy [[buffer(2)]], device const float* uz [[buffer(3)]],
                               device const uint* cells [[buffer(4)]], device const float* weights [[buffer(5)]],
                               device const uint* velocityCells [[buffer(6)]], device const float* axes [[buffer(7)]],
                               device float* output [[buffer(8)]], device float* velocityOutput [[buffer(9)]],
                               constant Grid& g [[buffer(10)]], constant uint& step [[buffer(11)]],
                               constant uint& steps [[buffer(12)]], constant uint& receivers [[buffer(13)]],
                               uint r [[thread_position_in_grid]]) {
            if (r >= receivers) return;
            float value = 0;
            for (uint k = 0; k < 8; k++) value += p[cells[8 * r + k]] * weights[8 * r + k];
            output[r * steps + step] = value;
            uint at = velocityCells[r];
            uint plane = g.nx * g.ny;
            float3 u = float3((ux[at - 1] + ux[at]) / 2, (uy[at - g.nx] + uy[at]) / 2, (uz[at - plane] + uz[at]) / 2);
            velocityOutput[r * (steps + 1) + step + 1] = dot(u, float3(axes[3 * r], axes[3 * r + 1], axes[3 * r + 2]));
        }
        """
}

extension WaveSolver {
    /// Everything the GPU needs about the grid, built from the same rules as the CPU solvers.
    struct GridLayout {
        var count: Int
        /// One flag per cell: whether it is simulated.
        var inside: [UInt8]
        /// Six faces per cell, in the order -x, +x, -y, +y, -z, +z, each laid out over all cells; -1 marks a
        /// face to a neighbour, otherwise the wall term β = c dt / (2 ξ d).
        var faces: [Float]
        var sourceCells: [Int]
        /// Injection weights scaled by c² dt / V.
        var sourceWeights: [Float]
        /// Eight cells and weights per receiver.
        var receiverCells: [Int]
        var receiverWeights: [Float]
        var velocityCells: [Int]
        var axes: [Float]
    }

    func gridLayout(source: SIMD3<Double>, receivers: [(position: SIMD3<Double>, microphone: Microphone)])
        -> GridLayout
    {
        let nx = cells.x
        let ny = cells.y
        let nz = cells.z
        let plane = nx * ny
        let count = plane * nz
        let c = atmosphere.soundSpeed
        let dt = timeStep
        let centre = { (i: Int, j: Int, k: Int) in (SIMD3(Double(i), Double(j), Double(k)) + 0.5) * spacing }
        // Cells whose centres lie in the room: every cell of a box, whole columns of a plan, and for a
        // mesh the stretches of each column between where a vertical line enters and leaves it.
        var inside = [UInt8](repeating: 1, count: count)
        let mesh = room.mesh.map(MeshGeometry.of)
        if let plan = room.plan {
            for j in 0..<ny {
                for i in 0..<nx where !plan.contains([centre(i, j, 0).x, centre(i, j, 0).y]) {
                    for k in 0..<nz { inside[i + nx * (j + ny * k)] = 0 }
                }
            }
        } else if let mesh {
            for j in 0..<ny {
                for i in 0..<nx {
                    let point = centre(i, j, 0)
                    let crossings = mesh.verticalCrossings(x: point.x, y: point.y)
                    for k in 0..<nz {
                        let z = centre(i, j, k).z
                        let below = crossings.filter { $0 < z }.count
                        inside[i + nx * (j + ny * k)] = below % 2 == 1 ? 1 : 0
                    }
                }
            }
        }
        let active = { (i: Int, j: Int, k: Int) in
            i >= 0 && i < nx && j >= 0 && j < ny && k >= 0 && k < nz && inside[i + nx * (j + ny * k)] == 1
        }
        func beta(_ xi: Double, _ depth: Double) -> Float {
            let value = c * dt / (2 * xi * depth)
            return value.isFinite ? Float(value) : 0
        }
        let surfaceImpedance = Dictionary(uniqueKeysWithValues: Surface.allCases.map { ($0, impedance($0)) })
        let wallImpedance = room.plan?.walls.map { impedance(material: $0) } ?? []
        // Air in an open face, otherwise the face's material.
        let faceImpedance = room.mesh.map { mesh in
            mesh.faces.indices.map {
                mesh.faces[$0].open ? 1 : impedance(material: mesh.materials[mesh.faces[$0].material])
            }
        }
        // A box face: the surface's impedance, or air's in an opening.
        func boxFace(_ surface: Surface, _ point: SIMD3<Double>) -> Float {
            let (a, b) = surface.planeAxes
            let open = openings.contains {
                $0.wall == nil && $0.surface == surface && $0.contains([point[a], point[b]])
            }
            return beta(open ? 1 : surfaceImpedance[surface]!, spacing[surface.normalAxis])
        }
        // A plan's wall face: the nearest wall's impedance, or air's in an opening.
        func planFace(_ point: SIMD2<Double>, height: Double, depth: Double) -> Float {
            let plan = room.plan!
            let wall = plan.nearestWall(point)
            let start = plan.start(wall)
            let along = simd_dot(point - start, simd_normalize(plan.end(wall) - start))
            let open = openings.contains { $0.wall == wall && $0.contains([along, height]) }
            return beta(open ? 1 : wallImpedance[wall], depth)
        }
        var faces = [Float](repeating: -1, count: 6 * count)
        let steps: [(SIMD3<Int>, Int)] = [
            ([-1, 0, 0], 0), ([1, 0, 0], 0), ([0, -1, 0], 1), ([0, 1, 0], 1), ([0, 0, -1], 2),
            ([0, 0, 1], 2),
        ]
        for k in 0..<nz {
            for j in 0..<ny {
                for i in 0..<nx where inside[i + nx * (j + ny * k)] == 1 {
                    let at = i + nx * (j + ny * k)
                    let point = centre(i, j, k)
                    for (side, (step, axis)) in steps.enumerated()
                    where !active(i + step.x, j + step.y, k + step.z) {
                        let face = point + SIMD3<Double>(step) * spacing / 2
                        if let mesh, let faceImpedance {
                            faces[side * count + at] = beta(
                                faceImpedance[mesh.nearestFace(face)], spacing[axis])
                        } else if room.plan != nil, axis < 2 {
                            faces[side * count + at] = planFace(
                                [face.x, face.y], height: face.z, depth: spacing[axis])
                        } else {
                            let surface: Surface = [.west, .east, .south, .north, .floor, .ceiling][side]
                            faces[side * count + at] = boxFace(surface, point)
                        }
                    }
                }
            }
        }
        // Trilinear weights over simulated cells, renormalized, padded to eight.
        func weights(_ point: SIMD3<Double>) -> [(Int, Float)] {
            let g = point / spacing - 0.5
            let base = SIMD3<Int>(
                min(max(Int(g.x.rounded(.down)), 0), nx - 2), min(max(Int(g.y.rounded(.down)), 0), ny - 2),
                min(max(Int(g.z.rounded(.down)), 0), nz - 2))
            let f = simd_clamp(g - SIMD3<Double>(base), SIMD3(repeating: 0), SIMD3(repeating: 1))
            var result: [(Int, Double)] = []
            for corner in 0..<8 {
                let o = SIMD3<Int>(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1)
                let cell = (base.x + o.x) + nx * ((base.y + o.y) + ny * (base.z + o.z))
                let w = (o.x == 1 ? f.x : 1 - f.x) * (o.y == 1 ? f.y : 1 - f.y) * (o.z == 1 ? f.z : 1 - f.z)
                result.append((cell, inside[cell] == 1 ? w : 0))
            }
            let total = result.reduce(0) { $0 + $1.1 }
            guard total > 0 else {
                // Outside every simulated cell round it: the nearest simulated cell, padded to eight.
                let nearest =
                    (0..<count).filter { inside[$0] == 1 }.min {
                        simd_distance_squared(centre($0 % nx, ($0 / nx) % ny, $0 / plane), point)
                            < simd_distance_squared(centre($1 % nx, ($1 / nx) % ny, $1 / plane), point)
                    } ?? 0
                return [(nearest, 1)] + Array(repeating: (nearest, 0), count: 7)
            }
            return result.map { ($0.0, Float($0.1 / total)) }
        }
        let injection = Float(c * c * dt / (spacing.x * spacing.y * spacing.z))
        let sourceWeights = weights(source)
        let receiverWeights = receivers.map { weights($0.position) }
        return GridLayout(
            count: count, inside: inside, faces: faces, sourceCells: sourceWeights.map(\.0),
            sourceWeights: sourceWeights.map { $0.1 * injection },
            receiverCells: receiverWeights.flatMap { $0.map(\.0) },
            receiverWeights: receiverWeights.flatMap { $0.map(\.1) },
            velocityCells: receivers.map { receiver in
                let g = receiver.position / spacing
                return min(max(Int(g.x), 1), nx - 2) + nx
                    * (min(max(Int(g.y), 1), ny - 2) + ny * min(max(Int(g.z), 1), nz - 2))
            },
            axes: receivers.flatMap {
                [Float($0.microphone.axis.x), Float($0.microphone.axis.y), Float($0.microphone.axis.z)]
            })
    }
}
