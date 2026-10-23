import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// The element kernel's shortcuts for speed (emmettl/bombcad-work#95) give the same, to the bit.
@Suite("Element kernel shortcuts", .gpuThreads)
struct ElementKernelSpeedTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// A reinforced column on a fixed base, its top pushed sideways until it cracks, its bars yield
    /// and its foot crushes and fails: its state, nodes and flags after `steps` substeps.
    private func pushedColumn(specialised: Bool, steps: Int) throws -> [Data] {
        let column = Box(min: SIMD3(0, 0, 0), max: SIMD3(0.2, 0.2, 1))
        var model = StructureModel(solids: [column], elementSize: 0.05)
        model.reinforcement = [ReinforcementLayer(region: column, ratio: SIMD3(0.002, 0.002, 0.02))]
        let solver = try StructureSolver(device: device, model: model)
        solver.specialisesUnloadedSubsteps = specialised
        solver.mutateNodes { nodes in
            for j in 0...4 {
                for i in 0...4 {
                    let top = solver.nodeIndex(i, j, 20)
                    nodes[top].isPrescribed = true
                    nodes[top].velocity = SIMD3(6, 0, -1)
                }
            }
        }
        solver.advance(steps: steps)
        return [solver.stateBuffer, solver.nodeBuffer, solver.flagBuffer].map {
            Data(bytes: $0.contents(), count: $0.length)
        }
    }

    @Test("Without loaded faces, the element kernel made for it gives the general one's result to the bit")
    func unloadedKernel() throws {
        let general = try pushedColumn(specialised: false, steps: 3000)
        let specialised = try pushedColumn(specialised: true, steps: 3000)
        #expect(general[0] == specialised[0], "element states differ")
        #expect(general[1] == specialised[1], "nodes differ")
        #expect(general[2] == specialised[2], "flags differ")
        // The push did break it, so that the paths that cracking, yielding and failure take ran.
        let flags = [UInt8](general[2])
        #expect(flags.contains(2) || flags.contains(3) || flags.contains(4), "no element failed")
    }

    /// `symmetricEigen` on symmetric matrices of every size and shape, against `eigenvaluesBelow`
    /// at a limit just past its bound: wherever it says no eigenvalue reaches the limit, none of
    /// the eigenvalues found does.
    @Test("No eigenvalue found passes a limit that the bound says none reaches")
    func eigenvalueBound() throws {
        let source =
            try ShaderLibrary.mainSource() + """

                kernel void eigenvalueBoundProbe(const device float *entries [[buffer(0)]],
                                                 device uint *violations [[buffer(1)]],
                                                 uint id [[thread_position_in_grid]]) {
                    const device float *e = entries + 7 * id;
                    float3x3 a = float3x3(float3(e[0], e[3], e[5]), float3(e[3], e[1], e[4]), float3(e[5], e[4], e[2]));
                    // The bound's limit: as tight as it allows, and a little looser.
                    float xy = fabs(e[3]);
                    float yz = fabs(e[4]);
                    float zx = fabs(e[5]);
                    float3 radius = float3(xy + zx, xy + yz, yz + zx);
                    float3 diagonal = float3(e[0], e[1], e[2]);
                    float3 top = diagonal + radius;
                    float3 size = abs(diagonal) + radius;
                    float tight = max(top.x, max(top.y, top.z)) + 1e-3f * max(size.x, max(size.y, size.z));
                    float limit = tight * (1.0f + e[6]) + fabs(tight) * 1e-6f;
                    if (!eigenvaluesBelow(a, limit)) {
                        return;
                    }
                    float3 values;
                    float3x3 vectors;
                    symmetricEigen(a, values, vectors);
                    if (max(values.x, max(values.y, values.z)) >= limit) {
                        atomic_fetch_add_explicit((device atomic_uint *)violations, 1u, memory_order_relaxed);
                    }
                    atomic_fetch_add_explicit((device atomic_uint *)violations + 1, 1u, memory_order_relaxed);
                }
                """
        let library = try device.makeLibrary(source: source, options: nil)
        let pipeline = try ShaderLibrary.pipeline("eigenvalueBoundProbe", in: library)
        let count = 1 << 20
        var generator = SystemRandomNumberGenerator()
        var entries = [Float](repeating: 0, count: 7 * count)
        for n in 0..<count {
            // Strains and stresses: from 1e-9 to 1e9, mostly one sign or mixed, some nearly diagonal.
            let scale = Float(pow(10, Double.random(in: -9...9, using: &generator)))
            let shear: Float = n % 4 == 0 ? 1e-4 : 1
            for k in 0..<3 { entries[7 * n + k] = scale * Float.random(in: -1...1, using: &generator) }
            for k in 3..<6 {
                entries[7 * n + k] = shear * scale * Float.random(in: -1...1, using: &generator)
            }
            entries[7 * n + 6] = n % 2 == 0 ? 0 : Float.random(in: 0...1e-3, using: &generator)
        }
        let input = try #require(
            device.makeBuffer(bytes: entries, length: 4 * entries.count, options: .storageModeShared))
        let output = try #require(device.makeBuffer(length: 8, options: .storageModeShared))
        memset(output.contents(), 0, 8)
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        let counts = output.contents().bindMemory(to: UInt32.self, capacity: 2)
        #expect(
            counts[0] == 0, "\(counts[0]) of \(counts[1]) bounded matrices had an eigenvalue past the limit")
        #expect(counts[1] > UInt32(count / 4), "only \(counts[1]) matrices were bounded")
    }
}
