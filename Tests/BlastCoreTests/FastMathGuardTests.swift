import Foundation
import Metal
import Testing

@testable import BlastCore

/// The `isnan` and `isfinite` guards in Structure.metal and Shell.metal hold under fast maths, the
/// shader library's default (emmettl/bombcad-work#76). Metal's `isnan` and `isfinite` are tests of
/// the bits, as Extract.metal's `finiteBits` is, and its fast maths keeps NaNs and infinities
/// ("no-nans-fp-math" and "no-infs-fp-math" stay false), so no guard is folded away; a comparison
/// such as `!(x >= 0)` is another matter. Each guarded path is copied here as its kernel takes it,
/// its value made by fast arithmetic from loaded values, and compiled with the solver's library and
/// its options.
@Suite("Fast-math guards", .gpuThreads)
struct FastMathGuardTests {
    static let probes = """

        // splatStructure's guard on the mean of two nodes' velocities, and the shells' and beams' on
        // a mix of them: the velocity as guarded, and as the fixed-point velocity splatted.
        kernel void guardProbeSplat(const device float *in [[buffer(0)]], device float *out [[buffer(1)]],
                                    constant float &s [[buffer(2)]], uint id [[thread_position_in_grid]]) {
            const device packed_float3 *v = (const device packed_float3 *)(in + 6 * id);
            float3 velocity = 0.5f * (float3(v[0]) + float3(v[1]));
            velocity = select(clamp(velocity, -wallSpeedLimit, wallSpeedLimit), float3(0.0f), isnan(velocity));
            int3 fixed = int3(round(velocity * wallSpeedScale));
            float3 mixed = mix(float3(v[0]), float3(v[1]), s);
            mixed = select(clamp(mixed, -wallSpeedLimit, wallSpeedLimit), float3(0.0f), isnan(mixed));
            out[4 * id] = velocity.x;
            out[4 * id + 1] = float(fixed.x);
            out[4 * id + 2] = mixed.x;
            out[4 * id + 3] = 0.0f;
        }

        // debrisAirForce's pressure of a cell and its caller's test of it.
        kernel void guardProbePressure(const device float *in [[buffer(0)]], device float *out [[buffer(1)]],
                                       uint id [[thread_position_in_grid]]) {
            const device float *s = in + 6 * id;
            float rho = max(s[0], 1e-6f);
            float kinetic = 0.5f * (s[1] * s[1] + s[2] * s[2] + s[3] * s[3]) / rho;
            float pressure = gasPressure(rho, s[4] - kinetic, airIdeal, 1.4f);
            float here = isfinite(pressure) ? pressure : -1.0f;
            out[4 * id] = here;
            out[4 * id + 1] = !isfinite(here) ? 1.0f : 0.0f;
            out[4 * id + 2] = 0.0f;
            out[4 * id + 3] = 0.0f;
        }

        // debrisExchange's test before it writes the cell back: whether it writes, and what.
        kernel void guardProbeExchange(const device float *in [[buffer(0)]], device float *out [[buffer(1)]],
                                       uint id [[thread_position_in_grid]]) {
            const device float *s = in + 6 * id;
            Cell c;
            c.rho = s[0];
            c.mx = s[1];
            c.my = s[2];
            c.mz = s[3];
            c.energy = s[4];
            float3 momentum = float3(s[5], 0.0f, 0.0f);
            float energy = 0.5f * s[5];
            float limit = 1000.0f * max(c.rho, 0.0f);
            float size = length(momentum);
            if (size > limit) {
                float scale = limit / size;
                momentum *= scale;
                energy *= scale;
            }
            c.mx += momentum.x;
            c.my += momentum.y;
            c.mz += momentum.z;
            c.energy += energy;
            float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / max(c.rho, 1e-6f);
            float floorEnergy = kinetic + 0.01f * gasEnergy(max(c.rho, 1e-6f), 101325.0f, airIdeal, 1.4f);
            c.energy = max(c.energy, floorEnergy);
            bool written = all(isfinite(float4(c.mx, c.my, c.mz, c.energy)));
            out[4 * id] = written ? 1.0f : 0.0f;
            out[4 * id + 1] = written ? c.mx : 0.0f;
            out[4 * id + 2] = written ? c.energy : 0.0f;
            out[4 * id + 3] = 0.0f;
        }

        // bodyEnvelopePoint itself, at a position moved by fast arithmetic.
        kernel void guardProbeEnvelope(const device float *in [[buffer(0)]], device atomic_uint *bounds [[buffer(1)]],
                                       uint id [[thread_position_in_grid]]) {
            const device packed_float3 *v = (const device packed_float3 *)(in + 6 * id);
            bodyEnvelopePoint(float3(v[0]) + 0.5f * float3(v[1]), 0.25f, id, bounds);
        }
        """

    /// Six values a case: two velocities or positions, or a cell's density, momentum, energy and
    /// the debris's momentum.
    static let cases: [(name: String, values: [Float])] = [
        ("finite", [1.2, 2, 3, 4, 3e5, 6]),
        ("NaN", [Float](repeating: .nan, count: 6)),
        ("+inf", [Float](repeating: .infinity, count: 6)),
        ("-inf", [Float](repeating: -.infinity, count: 6)),
        ("NaN energy", [1.2, 1, 1, 1, .nan, 1]),
        ("infinite energy", [1.2, 1, 1, 1, .infinity, 1]),
        ("NaN momentum", [1.2, .nan, 1, 1, 3e5, 1]),
        ("overflowing", [1e-30, 3e38, 3e38, 3e38, 3e38, 3e38]),
    ]

    let device: MTLDevice
    let library: MTLLibrary
    let queue: MTLCommandQueue

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        // As `ShaderLibrary.make` compiles the solver's library by default: no options, fast maths.
        library = try device.makeLibrary(source: ShaderLibrary.mainSource() + Self.probes, options: nil)
        queue = try #require(device.makeCommandQueue())
    }

    private func run(_ kernel: String, output: MTLBuffer, mix: Float = 0) throws {
        let pipeline = try ShaderLibrary.pipeline(kernel, in: library)
        let values = Self.cases.flatMap(\.values)
        let input = try #require(
            device.makeBuffer(bytes: values, length: 4 * values.count, options: .storageModeShared))
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        var s = mix
        encoder.setBytes(&s, length: 4, index: 2)
        encoder.dispatchThreads(
            MTLSize(width: Self.cases.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: Self.cases.count, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
    }

    private func outputs(_ kernel: String, mix: Float = 0) throws -> [[Float]] {
        let output = try #require(
            device.makeBuffer(length: 16 * Self.cases.count, options: .storageModeShared))
        try run(kernel, output: output, mix: mix)
        let values = output.contents().bindMemory(to: Float.self, capacity: 4 * Self.cases.count)
        return Self.cases.indices.map { n in (0..<4).map { values[4 * n + $0] } }
    }

    @Test("A NaN velocity is splatted as still and an infinite one at the wall speed limit")
    func splat() throws {
        for mix: Float in [0, 0.3] {
            let out = try outputs("guardProbeSplat", mix: mix)
            for (n, c) in Self.cases.enumerated() {
                #expect(out[n][0].isFinite && abs(out[n][0]) <= 1000, "\(c.name): mean \(out[n][0])")
                #expect(out[n][2].isFinite && abs(out[n][2]) <= 1000, "\(c.name): mix \(out[n][2])")
            }
            #expect(
                out[1][0].bitPattern == 0 && out[1][1] == 0 && out[1][2].bitPattern == 0, "NaN not caught")
            #expect(out[2][0] == 1000 && out[2][1] == 1000 * 1024, "+inf not clamped")
            #expect(out[3][0] == -1000 && out[3][1] == -1000 * 1024, "-inf not clamped")
        }
    }

    @Test("A cell whose pressure is not a number reads as no air")
    func pressure() throws {
        let out = try outputs("guardProbePressure")
        for (n, c) in Self.cases.enumerated() {
            #expect(out[n][0].isFinite, "\(c.name): pressure \(out[n][0]) let through")
            #expect(out[n][1] == 0, "\(c.name): the caller's test saw a non-finite pressure")
        }
        for n in 1..<Self.cases.count { #expect(out[n][0] == -1, "\(Self.cases[n].name): \(out[n][0])") }
        #expect(abs(out[0][0] - 0.4 * (3e5 - 0.5 * 29 / 1.2)) < 1, "finite: \(out[0][0])")
    }

    @Test("The debris exchange never writes a NaN or an infinity into the air")
    func exchange() throws {
        let out = try outputs("guardProbeExchange")
        for (n, c) in Self.cases.enumerated() where out[n][0] != 0 {
            #expect(out[n][1].isFinite && out[n][2].isFinite, "\(c.name): wrote \(out[n][1]), \(out[n][2])")
        }
        #expect(out[0][0] == 1, "a finite cell was not written")
        for n in [1, 2, 3, 5, 6, 7] { #expect(out[n][0] == 0, "\(Self.cases[n].name) was written") }
    }

    @Test("A body's envelope leaves out a point that is not finite")
    func envelope() throws {
        let words = 6 * Self.cases.count
        let bounds = try #require(device.makeBuffer(length: 4 * words, options: .storageModeShared))
        let initial = (0..<words).map { $0 % 6 < 3 ? UInt32.max : 0 }
        bounds.contents().copyMemory(from: initial, byteCount: 4 * words)
        try run("guardProbeEnvelope", output: bounds)
        let after = Array(
            UnsafeBufferPointer(
                start: bounds.contents().bindMemory(to: UInt32.self, capacity: words), count: words))
        for (n, c) in Self.cases.enumerated() {
            let mine = Array(after[(6 * n)..<(6 * n + 6)])
            if n == 0 {
                #expect(mine != Array(initial[0..<6]), "the finite point was left out")
            } else {
                #expect(
                    mine == Array(initial[(6 * n)..<(6 * n + 6)]), "\(c.name): the point was taken, \(mine)")
            }
        }
    }
}
