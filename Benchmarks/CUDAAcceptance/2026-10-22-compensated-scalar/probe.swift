import Foundation
import Metal

struct Fixture: Codable {
    struct Sequence: Codable {
        let name: String
        let initial: UInt32
        let deltas: [UInt32]
        let resets: [String: UInt32]
    }
    let sequences: [Sequence]
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("probe FIXTURE OUTPUT") }
let fixture = try JSONDecoder().decode(
    Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
var headers: [UInt32] = []
var input: [UInt32] = []
for sequence in fixture.sequences {
    headers += [UInt32(input.count / 3), UInt32(sequence.deltas.count), sequence.initial, 0]
    for (step, delta) in sequence.deltas.enumerated() {
        let reset = sequence.resets[String(step)]
        input += [delta, reset == nil ? 0 : 1, reset ?? 0]
    }
}
let count = fixture.sequences.count
let headerBuffer = device.makeBuffer(bytes: headers, length: headers.count * 4)!
let inputBuffer = device.makeBuffer(bytes: input, length: input.count * 4)!
let traceBuffer = device.makeBuffer(length: input.count / 3 * 8)!
let finalBuffer = device.makeBuffer(length: count * 8)!
let source = """
    #include <metal_stdlib>
    using namespace metal;
    constant bool observed [[function_constant(0)]];
    constant uint method [[function_constant(1)]];
    static inline float2 plainKahan(float sum, float error, float delta) {
        float y = delta - error;
        float next = sum + y;
        float e = (next - sum) - y;
        return float2(next, e);
    }
    static inline float2 protectedKahan(float sum, float error, float delta) {
        #pragma METAL fp math_mode(safe)
        #pragma METAL fp contract(off)
        float y = delta - error;
        float next = sum + y;
        float e = (next - sum) - y;
        return float2(next, e);
    }
    kernel void accumulate(const device uint4 *headers [[buffer(0)]],
                           const device uint *input [[buffer(1)]],
                           device uint2 *trace [[buffer(2)]],
                           device uint2 *finals [[buffer(3)]],
                           uint id [[thread_position_in_grid]]) {
        uint4 h = headers[id];
        float2 state = float2(as_type<float>(h.z), 0.0f);
        for (uint step = 0; step < h.y; ++step) {
            uint index = (h.x + step) * 3;
            if (input[index + 1]) state = float2(as_type<float>(input[index + 2]), 0.0f);
            float delta = as_type<float>(input[index]);
            if (method == 0) state = float2(state.x + delta, 0.0f);
            else if (method == 1) state = plainKahan(state.x, state.y, delta);
            else state = protectedKahan(state.x, state.y, delta);
            if (observed) trace[h.x + step] = as_type<uint2>(state);
        }
        finals[id] = as_type<uint2>(state);
    }
    """
var results: [[String: Any]] = []
for policy in ["default", "unfused", "safe-unfused"] {
    let options: MTLCompileOptions? = policy == "safe-unfused" ? MTLCompileOptions() : nil
    options?.mathMode = .safe
    let prefix = policy == "default" ? "" : "#pragma METAL fp contract(off)\n"
    let library = try device.makeLibrary(source: prefix + source, options: options)
    for method in 0..<3 {
        for observed in [false, true] {
            let constants = MTLFunctionConstantValues()
            var flag = observed
            var selection = UInt32(method)
            constants.setConstantValue(&flag, type: .bool, index: 0)
            constants.setConstantValue(&selection, type: .uint, index: 1)
            let function = try library.makeFunction(name: "accumulate", constantValues: constants)
            let pipeline = try device.makeComputePipelineState(function: function)
            memset(traceBuffer.contents(), 0, traceBuffer.length)
            memset(finalBuffer.contents(), 0, finalBuffer.length)
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline)
            for (index, buffer) in [headerBuffer, inputBuffer, traceBuffer, finalBuffer].enumerated() {
                encoder.setBuffer(buffer, offset: 0, index: index)
            }
            encoder.dispatchThreads(
                MTLSize(width: count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: count, height: 1, depth: 1))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            if let error = command.error { throw error }
            func words(_ buffer: MTLBuffer) -> [UInt32] {
                Array(
                    UnsafeBufferPointer(
                        start: buffer.contents().bindMemory(to: UInt32.self, capacity: buffer.length / 4),
                        count: buffer.length / 4))
            }
            var result: [String: Any] = [
                "policy": policy, "method": ["naive", "kahan", "protected-kahan"][method],
                "observed": observed, "finalWords": words(finalBuffer),
            ]
            if observed { result["traceWords"] = words(traceBuffer) }
            results.append(result)
        }
    }
}
let report: [String: Any] = [
    "schema": "bombcad-compensated-scalar-1", "device": device.name, "registryID": device.registryID,
    "unifiedMemory": device.hasUnifiedMemory, "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "results": results,
]
try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(
    to: URL(fileURLWithPath: arguments[2]), options: .atomic)
print("Completed \(results.count) dispatches on \(device.name)")
